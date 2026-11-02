/++
Fiber-mode tests for `dbwire:io`: they run inside a vibe.d task, against local
test servers running on a plain thread with blocking sockets.

Run with `dub run --root=tests-vibe` (vibe-core 2.x) or
`dub run --root=tests-vibe1` (vibe-core 1.x).
+/
module app;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, SocketShutdown, TcpSocket;
import std.stdio : stderr, writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;
import vibe.core.task : InterruptException, Task;

import dbwire.exception : ClientException, ConnectionException;
import dbwire.io;

version (Have_vibe_core)
{
}
else
    static assert(false, "this runner needs vibe-core");

int main()
{
    int failures;
    // Outside a task, automatic selection uses thread mode even with vibe-core compiled in
    if (inVibeTask() || backendFor(IoMode.auto_).name != "phobos")
    {
        stderr.writeln("FAIL outside a task: expected thread mode");
        failures++;
    }

    void runTests() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
            failures += runAll();
        catch (Exception e)
            failures++;
    }

    runTask(&runTests);
    runEventLoop();
    return failures == 0 ? 0 : 1;
}

private int runAll()
{
    static immutable tests = [
        Test("automatic selection inside a task", &testAutoSelection),
        Test("round trip and dataAvailable", &testRoundTrip),
        Test("end of stream", &testEndOfStream),
        Test("receive timeout", &testReceiveTimeout),
        Test("connection refused", &testRefused),
        Test("waiting does not block the event loop", &testConcurrentReads),
        Test("interrupted task", &testInterrupt),
        Test("use from another thread", &testOtherThread),
        Test("yieldNow", &testYield),
        Test("FiberLock", &testLock),
        Test("FiberPoolSync", &testPoolSync),
    ];
    int failures;
    foreach (test; tests)
    {
        try
        {
            test.run();
            writefln("PASS %s", test.name);
        }
        catch (Exception e)
        {
            writefln("FAIL %s: %s", test.name, e.msg);
            failures++;
        }
    }
    writefln("%s tests, %s failed", tests.length, failures);
    return failures;
}

private struct Test
{
    string name;
    void function() run;
}

private void check(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

/// A server on a plain thread: accepts one connection on 127.0.0.1 and runs `handler` on it.
private final class TestServer
{
    private TcpSocket listener;
    private Thread thread;
    ushort port;

    this(void function(Socket) handler)
    {
        listener = new TcpSocket;
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(1);
        port = (cast(InternetAddress) listener.localAddress).port;
        auto l = listener;
        thread = new Thread({
            auto connection = l.accept();
            scope (exit)
                connection.close();
            handler(connection);
        });
        thread.isDaemon = true;
        thread.start();
    }

    Transport connect()
    {
        return backendFor(IoMode.auto_).connect("127.0.0.1", port, 5.seconds);
    }

    void stop()
    {
        thread.join();
        listener.close();
    }
}

private ubyte[] readSome(Transport transport, size_t count)
{
    auto data = new ubyte[count];
    size_t got;
    while (got < count)
    {
        const n = transport.read(data[got .. $]);
        check(n > 0, "unexpected end of stream");
        got += n;
    }
    return data;
}

private void testAutoSelection()
{
    check(inVibeTask(), "inVibeTask() is false inside a task");
    check(backendFor(IoMode.auto_).name == "vibe", "automatic selection inside a task is not vibe");
    check(backendFor(IoMode.vibe).name == "vibe", "IoMode.vibe is not vibe");
}

private void testRoundTrip()
{
    static void echo(Socket s)
    {
        ubyte[3] data;
        size_t got;
        while (got < 3)
            got += s.receive(data[got .. $]);
        Thread.sleep(50.msecs); // the client checks dataAvailable before the reply
        s.send(data[]);
        ubyte[1] rest;
        s.receive(rest[]); // until the client closes
    }

    auto server = new TestServer(&echo);
    auto transport = server.connect();
    check(transport.connected, "not connected");
    transport.write([1, 2, 3]);
    check(!transport.dataAvailable, "data available before the server replied");
    const deadline = MonoTime.currTime + 5.seconds;
    while (!transport.dataAvailable && MonoTime.currTime < deadline)
        sleep(5.msecs);
    check(readSome(transport, 3) == [1, 2, 3], "echo differs");
    transport.close();
    server.stop();
}

private void testEndOfStream()
{
    static void closeAtOnce(Socket s)
    {
        s.shutdown(SocketShutdown.BOTH);
    }

    auto server = new TestServer(&closeAtOnce);
    auto transport = server.connect();
    auto buffer = new ubyte[8];
    check(transport.read(buffer) == 0, "read after the server closed did not return 0");
    transport.close();
    server.stop();
}

private void testReceiveTimeout()
{
    static void silent(Socket s)
    {
        ubyte[1] b;
        s.receive(b[]); // until the client closes
    }

    auto server = new TestServer(&silent);
    auto transport = server.connect();
    transport.setTimeouts(200.msecs, Duration.zero);
    const start = MonoTime.currTime;
    bool timedOut;
    try
        transport.read(new ubyte[1]);
    catch (ConnectionException)
        timedOut = true;
    const elapsed = MonoTime.currTime - start;
    check(timedOut, "no ConnectionException on timeout");
    check(elapsed >= 150.msecs && elapsed < 3.seconds, "timeout took " ~ elapsed.toString());
    transport.close();
    server.stop();
}

private void testRefused()
{
    // Nothing listens on the port of a socket we bound but never listened on
    auto probe = new TcpSocket;
    probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    const port = (cast(InternetAddress) probe.localAddress).port;
    scope (exit)
        probe.close();
    bool refused;
    try
        backendFor(IoMode.auto_).connect("127.0.0.1", port, 5.seconds);
    catch (ConnectionException)
        refused = true;
    check(refused, "no ConnectionException for a refused connection");
}

private void testConcurrentReads()
{
    static void slowReply(Socket s)
    {
        Thread.sleep(300.msecs);
        s.send([42]);
        ubyte[1] b;
        s.receive(b[]);
    }

    // Two tasks wait for replies that take 300 ms each: together about 300 ms, not 600
    auto first = new TestServer(&slowReply);
    auto second = new TestServer(&slowReply);
    auto a = first.connect();
    auto b = second.connect();
    bool okA, okB;
    const start = MonoTime.currTime;
    void readA() nothrow
    {
        try
            okA = readSome(a, 1) == [42];
        catch (Exception)
        {
        }
    }

    void readB() nothrow
    {
        try
            okB = readSome(b, 1) == [42];
        catch (Exception)
        {
        }
    }

    auto taskA = runTask(&readA);
    auto taskB = runTask(&readB);
    taskA.join();
    taskB.join();
    const elapsed = MonoTime.currTime - start;
    check(okA && okB, "a reply is missing");
    check(elapsed < 550.msecs, "the reads ran one after the other: " ~ elapsed.toString());
    a.close();
    b.close();
    first.stop();
    second.stop();
}

private void testInterrupt()
{
    static void silent(Socket s)
    {
        ubyte[1] b;
        s.receive(b[]);
    }

    // Task.interrupt while waiting for data: InterruptException, not a ConnectionException
    auto server = new TestServer(&silent);
    auto transport = server.connect();
    string outcome;
    void read() nothrow
    {
        try
        {
            transport.read(new ubyte[1]);
            outcome = "returned";
        }
        catch (InterruptException)
            outcome = "interrupted";
        catch (Exception e)
            outcome = "other: " ~ e.msg;
    }

    auto reader = runTask(&read);
    sleep(50.msecs);
    reader.interrupt();
    reader.join();
    check(outcome == "interrupted", "outcome: " ~ outcome);
    transport.close();
    server.stop();
}

private void testOtherThread()
{
    static void silent(Socket s)
    {
        ubyte[1] b;
        s.receive(b[]);
    }

    // A fiber-mode transport belongs to the thread that opened it
    auto server = new TestServer(&silent);
    auto transport = server.connect();
    string outcome;
    auto thread = new Thread({
        try
        {
            transport.dataAvailable();
            outcome = "allowed";
        }
        catch (ClientException)
            outcome = "refused";
        catch (Exception e)
            outcome = "other: " ~ e.msg;
    });
    thread.start();
    thread.join();
    check(outcome == "refused", "outcome: " ~ outcome);
    transport.close();
    server.stop();
}

private void testYield()
{
    // Two tasks that yield between steps take turns
    auto backend = backendFor(IoMode.auto_);
    string events;
    void steps(char name) nothrow
    {
        try
            foreach (i; 0 .. 3)
            {
                events ~= name;
                backend.yieldNow();
            }
        catch (Exception)
        {
        }
    }

    auto a = runTask(&steps, 'a');
    auto b = runTask(&steps, 'b');
    a.join();
    b.join();
    check(events == "ababab", "order: " ~ events);
}

private void testLock()
{
    // A task holding the lock across a blocking call keeps the other task out
    auto lock = backendFor(IoMode.auto_).newLock();
    string[] events;
    void hold() nothrow
    {
        try
        {
            lock.lock();
            events ~= "a locked";
            sleep(50.msecs);
            events ~= "a unlocks";
            lock.unlock();
        }
        catch (Exception)
        {
        }
    }

    void wait() nothrow
    {
        try
        {
            sleep(10.msecs);
            lock.lock();
            events ~= "b locked";
            lock.unlock();
        }
        catch (Exception)
        {
        }
    }

    auto holder = runTask(&hold);
    auto waiter = runTask(&wait);
    holder.join();
    waiter.join();
    check(events == ["a locked", "a unlocks", "b locked"], "order: " ~ joinEvents(events));
}

private void testPoolSync()
{
    auto sync = backendFor(IoMode.auto_).newPoolSync();
    sync.lock();
    const start = MonoTime.currTime;
    check(!sync.wait(50.msecs), "wait without notify returned true");
    check(MonoTime.currTime - start >= 40.msecs, "wait returned early");
    void notify() nothrow
    {
        try
        {
            sleep(20.msecs);
            sync.notifyAll();
        }
        catch (Exception)
        {
        }
    }

    auto notifier = runTask(&notify);
    check(sync.wait(5.seconds), "wait missed notifyAll");
    sync.unlock();
    notifier.join();
}

private string joinEvents(string[] events)
{
    import std.array : join;

    return events.join(", ");
}
