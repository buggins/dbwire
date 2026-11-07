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
import std.stdio : stderr, stdout, writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;
import vibe.core.task : InterruptException, Task;

import dbwire.exception : ClientException, ConnectionException;
import dbwire.io;
import dbwire.client : PoolCore, PoolOptions, Poolable;
import dbwire.tls : TlsContext, TlsOptions, TlsTransport;

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
        Test("waitForData: timeout, data, other tasks run", &testWaitForData),
        Test("connection refused", &testRefused),
        Test("Unix-domain sockets: two at once, peer user, abstract refused", &testUnixSockets),
        Test("waiting does not block the event loop", &testConcurrentReads),
        Test("interrupted task", &testInterrupt),
        Test("use from another thread", &testOtherThread),
        Test("yieldNow", &testYield),
        Test("FiberLock", &testLock),
        Test("FiberPoolSync", &testPoolSync),
        Test("connection pool shared by tasks", &testPoolTasks),
        Test("TLS to a public server (DBWIRE_TLS_PUBLIC_HOST)", &testTlsPublicHost),
    ];
    startWatchdog();
    int failures;
    foreach (test; tests)
    {
        report("RUN  %s", test.name);
        watchdogStart(test.name);
        try
        {
            test.run();
            report("PASS %s", test.name);
        }
        catch (Exception e)
        {
            report("FAIL %s: %s", test.name, e.msg);
            failures++;
        }
    }
    watchdogStart(null);
    report("%s tests, %s failed", tests.length, failures);
    return failures;
}

/// Prints a line at once (stdout is block-buffered when CI pipes it).
private void report(Args...)(string format, Args args)
{
    writefln(format, args);
    stdout.flush();
}

/// Longest time a test may take before the watchdog ends the process.
private enum Duration testTimeLimit = 30.seconds;

private __gshared string watchedTest; // the running test, or null
private __gshared MonoTime watchedSince;

private void watchdogStart(string name)
{
    import core.atomic : atomicFence;

    watchedSince = MonoTime.currTime;
    watchedTest = name;
    atomicFence();
}

/// A thread that ends the process when a test hangs, naming the test.
private void startWatchdog()
{
    static void watch()
    {
        import core.stdc.stdlib : exit;

        for (;;)
        {
            Thread.sleep(1.seconds);
            const name = watchedTest;
            if (name !is null && MonoTime.currTime - watchedSince > testTimeLimit)
            {
                stderr.writefln("TIMEOUT %s: still running after %s", name, testTimeLimit);
                stderr.flush();
                exit(2);
            }
        }
    }

    auto watchdog = new Thread(&watch);
    watchdog.isDaemon = true;
    watchdog.start();
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
            // A server waiting for the client to close gives up eventually
            connection.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);
            handler(connection);
        });
        thread.isDaemon = true;
        thread.start();
    }

    Transport connect()
    {
        return backendFor(IoMode.auto_).connect("127.0.0.1", port, 5.seconds);
    }

    /// Waits for the server thread without blocking the event loop: closing a
    /// vibe-core connection may need the event loop (e.g. on Windows).
    void stop()
    {
        const deadline = MonoTime.currTime + 10.seconds;
        while (thread.isRunning && MonoTime.currTime < deadline)
            sleep(5.msecs);
        check(!thread.isRunning, "the test server did not finish");
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
    // Checking again must not consume the data (eventcore's WinAPI driver lost it)
    foreach (i; 0 .. 3)
        check(transport.dataAvailable, "data no longer available");
    check(readSome(transport, 3) == [1, 2, 3], "echo differs");
    transport.close();
    server.stop();
}

private void testUnixSockets()
{
    version (Posix)
    {
        import core.sys.posix.unistd : getuid;
        import std.conv : to;
        import std.file : exists, remove, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;
        import std.socket : AddressFamily, SocketType, UnixAddress;

        const path = buildPath(tempDir, "dbwire-vibe-test-" ~ thisProcessID.to!string ~ ".sock");
        if (exists(path))
            remove(path);
        auto listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        scope (exit)
        {
            listener.close();
            if (exists(path))
                remove(path);
        }
        listener.bind(new UnixAddress(path));
        listener.listen(2);
        // two connections at once: each gets its byte back plus one
        auto thread = new Thread({
            Socket[2] connections;
            foreach (ref c; connections)
            {
                c = listener.accept();
                c.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);
            }
            foreach (c; connections)
            {
                ubyte[1] b;
                if (c.receive(b[]) == 1)
                {
                    b[0]++;
                    c.send(b[]);
                }
            }
            foreach (c; connections)
            {
                ubyte[1] rest;
                c.receive(rest[]); // until the client closes
                c.close();
            }
        });
        thread.isDaemon = true;
        thread.start();

        auto backend = backendFor(IoMode.auto_);
        auto first = connectUnixSocket(backend, path, 5.seconds);
        auto second = connectUnixSocket(backend, path, 5.seconds);
        first.write([1]);
        second.write([5]);
        check(readSome(first, 1) == [2], "first reply differs");
        check(readSome(second, 1) == [6], "second reply differs");
        check(peerUserId(first) == getuid(), "peer user id differs");
        first.close();
        second.close();
        const deadline = MonoTime.currTime + 10.seconds;
        while (thread.isRunning && MonoTime.currTime < deadline)
            sleep(5.msecs);
        check(!thread.isRunning, "the test server did not finish");

        bool refused;
        try
            connectUnixSocket(backend, "\0dbwire-abstract", 5.seconds);
        catch (ClientException)
            refused = true;
        check(refused, "an abstract socket was not refused in fiber mode");
    }
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

private void testWaitForData()
{
    import dbwire.io.backend : waitForData;
    import dbwire.io.transport : WaitableTransport;

    static void lateReply(Socket s)
    {
        Thread.sleep(300.msecs);
        ubyte[1] reply = [7];
        s.send(reply[]);
        ubyte[1] b;
        s.receive(b[]); // until the client closes
    }

    auto server = new TestServer(&lateReply);
    auto transport = server.connect();
    auto waitable = cast(WaitableTransport) transport;
    check(waitable !is null && waitable.canWaitForData, "the vibe transport can't wait");
    // another task runs while this one waits
    int ticks;
    void tick() nothrow
    {
        try
            foreach (i; 0 .. 5)
            {
                sleep(20.msecs);
                ticks++;
            }
        catch (Exception)
        {
        }
    }

    auto ticker = runTask(&tick);
    auto start = MonoTime.currTime;
    check(!waitable.waitForData(100.msecs), "data before the reply");
    check(MonoTime.currTime - start >= 90.msecs, "returned before the timeout");
    check(waitForData(transport, 5.seconds, backendFor(IoMode.auto_)), "no data within 5 s");
    ticker.join();
    check(ticks == 5, "the other task did not run while waiting");
    check(readSome(transport, 1) == [7], "reply differs");
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

/// A connection for the pool test.
private final class PoolConn : Poolable
{
    int id;
    bool open = true;

    this(int id) @safe
    {
        this.id = id;
    }

    @property bool isOpen() const @safe nothrow
    {
        return open;
    }

    @property bool isBusy() const @safe nothrow
    {
        return false;
    }

    void ping() @safe
    {
    }

    void close() @safe nothrow
    {
        open = false;
    }
}

private void testPoolTasks()
{
    // Tasks on one thread share a fiber-mode pool: a waiting task gets the
    // connection another task returns, without blocking the event loop
    PoolOptions options;
    options.maxConnections = 1;
    options.waitTimeout = 5.seconds;
    int opened;
    Poolable open() @safe
    {
        return new PoolConn(++opened);
    }

    auto pool = new PoolCore(options, IoMode.auto_, &open);
    string events;
    void holder() nothrow
    {
        try
        {
            auto lease = pool.acquire();
            events ~= lease.connection() !is null ? "a" : "?";
            sleep(50.msecs);
            events ~= "r";
        }
        catch (Exception)
            events ~= "!";
    }

    void waiter() nothrow
    {
        try
        {
            sleep(10.msecs);
            auto lease = pool.acquire();
            events ~= (cast(PoolConn) lease.connection).id == 1 ? "b" : "?";
        }
        catch (Exception)
            events ~= "!";
    }

    auto a = runTask(&holder);
    auto b = runTask(&waiter);
    a.join();
    b.join();
    check(events == "arb", "order: " ~ events);
    check(opened == 1 && pool.idleConnections == 1 && pool.activeConnections == 0, "unexpected pool state");

    // The wait timeout works in fiber mode too
    options.waitTimeout = 50.msecs;
    auto small = new PoolCore(options, IoMode.auto_, &open);
    auto held = small.acquire();
    check(held.connection() !is null, "no connection");
    bool timedOut;
    try
        small.acquire();
    catch (ClientException)
        timedOut = true;
    check(timedOut, "no timeout waiting for a connection");
}

/// TLS over a fiber-mode transport, verified with the system's trusted
/// certificates. Opt-in, as it needs the internet: CI sets
/// DBWIRE_TLS_PUBLIC_HOST, e.g. to github.com:443.
private void testTlsPublicHost()
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.conv : to;
    import std.process : environment;

    const target = environment.get("DBWIRE_TLS_PUBLIC_HOST", "");
    if (target.length == 0)
    {
        report("     (skipped: DBWIRE_TLS_PUBLIC_HOST is not set)");
        return;
    }
    auto parts = target.findSplit(":");
    const host = parts[0];
    const port = parts[2].length ? parts[2].to!ushort : cast(ushort) 443;
    auto backend = backendFor(IoMode.auto_);
    check(backend.name == "vibe", "not in fiber mode");
    TlsOptions options;
    auto tls = new TlsTransport(backend.connect(host, port, 10.seconds), backend, TlsContext.client(options), host,
            options, 10.seconds);
    scope (exit)
        tls.close();
    tls.setTimeouts(10.seconds, 10.seconds);
    tls.write(cast(const(ubyte)[])("HEAD / HTTP/1.1\r\nHost: " ~ host ~ "\r\nConnection: close\r\n\r\n"));
    auto reply = new ubyte[64];
    size_t got;
    while (got < 12)
    {
        const n = tls.read(reply[got .. $]);
        check(n > 0, "the server closed the connection");
        got += n;
    }
    check((cast(const(char)[]) reply[0 .. got]).startsWith("HTTP/1."), "not an HTTP reply");
}

private string joinEvents(string[] events)
{
    import std.array : join;

    return events.join(", ");
}
