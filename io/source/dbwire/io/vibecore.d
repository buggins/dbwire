/++
Fiber-mode I/O backend: vibe-core sockets, for code running in vibe.d tasks.

If a task is interrupted (`Task.interrupt`) while waiting for the server, the
`InterruptException` propagates unchanged and the connection is closed, because
the response was cut off.

Compiled only when vibe-core is in the application's dependency graph
(`version (Have_vibe_core)`, defined by dub). Blocking calls suspend the
calling task instead of the thread, so other tasks keep running.

A connection opened in fiber mode belongs to the thread (event loop) that
opened it. Any task on that thread may use it, one at a time; using it from
another thread throws `ClientException`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.vibecore;

version (Have_vibe_core)  : import core.thread : Thread;
import core.time : Duration;

import vibe.core.net : TCPConnection, WaitForDataStatus, connectTCP;
import vibe.core.stream : IOMode;
import vibe.core.task : InterruptException;

import dbwire.exception : ClientException, ConnectionException;
import dbwire.io.backend : IoBackend, IoLock, PoolSync;
import dbwire.io.transport : Transport;

/// `Transport` over a vibe-core `TCPConnection`.
final class VibeTransport : Transport
{
    private TCPConnection connection;
    private Thread owner;
    private Duration receiveTimeout = Duration.max;

    /// Wraps a connected `TCPConnection`. The transport takes ownership of it.
    this(TCPConnection connection) @safe
    {
        this.connection = connection;
        owner = currentThread();
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        checkThread();
        try
        {
            final switch (connection.waitForDataEx(receiveTimeout))
            {
            case WaitForDataStatus.dataAvailable:
                return connection.read(buffer, IOMode.immediate);
            case WaitForDataStatus.noMoreData:
                return 0;
            case WaitForDataStatus.timeout:
                throw new ConnectionException("Socket receive timed out");
            }
        }
        catch (ConnectionException e)
            throw e;
        catch (ClientException e)
            throw e;
        catch (InterruptException e)
            throw e; // Task.interrupt(): propagate as is; the connection gets closed
        catch (Exception e)
            throw new ConnectionException("Socket receive failed: " ~ e.msg);
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        checkThread();
        try
            connection.write(data);
        catch (InterruptException e)
            throw e;
        catch (Exception e)
            throw new ConnectionException("Socket send failed: " ~ e.msg);
    }

    override bool dataAvailable() @safe
    {
        checkThread();
        try
        {
            version (Windows)
                return connection.peek().length > 0 || socketReadable(connection.fd);
            else
                return connection.dataAvailableForRead;
        }
        catch (Exception e)
            throw new ConnectionException("Socket check failed: " ~ e.msg);
    }

    override void close() @safe nothrow
    {
        connection.close();
    }

    override bool connected() const @safe nothrow
    {
        return connection.connected;
    }

    /// vibe-core has no send timeout; `send` is ignored.
    override void setTimeouts(Duration receive, Duration send) @safe
    {
        receiveTimeout = receive == Duration.zero ? Duration.max : receive;
        connection.readTimeout = receiveTimeout;
    }

    private void checkThread() const @safe
    {
        if (currentThread() !is owner)
            throw new ClientException(
                    "A fiber-mode connection was used from a thread other than the one that "
                    ~ "opened it");
    }
}

/// Fiber-mode backend: connects with vibe-core.
final class VibeBackend : IoBackend
{
    override @property string name() const @safe pure nothrow
    {
        return "vibe";
    }

    /++
    Connects to `host`:`port` with `vibe.core.net.connectTCP`.

    Throws: `ConnectionException` on failure or timeout.
    +/
    override Transport connect(string host, ushort port, Duration timeout) @safe
    {
        import std.conv : to;

        try
            return new VibeTransport(connectTCP(host, port, null, 0, timeout));
        catch (Exception e)
            throw new ConnectionException("Cannot connect to " ~ host ~ ":" ~ port.to!string ~ ": " ~ e.msg);
    }

    /// Lets other tasks run.
    override void yieldNow() @safe
    {
        import vibe.core.core : yield;

        yield();
    }

    /// A task-level event; usable only by tasks of the creating thread.
    override PoolSync newPoolSync() @safe
    {
        return new FiberPoolSync;
    }

    /// A vibe-core task mutex: holding it across blocking I/O suspends other tasks that want it.
    override IoLock newLock() @safe
    {
        return new FiberLock;
    }
}

/++
`PoolSync` for the tasks of one thread. Tasks on one thread never run at the
same time and switch only at blocking calls, so the lock does nothing; waiting
uses a vibe-core manual event.
+/
final class FiberPoolSync : PoolSync
{
    import vibe.core.sync : LocalManualEvent, createManualEvent;

    private LocalManualEvent event;

    /// Creates the event.
    this() @safe
    {
        event = createManualEvent();
    }

    override void lock() @safe
    {
    }

    override void unlock() @safe
    {
    }

    override bool wait(Duration timeout) @safe
    {
        const before = event.emitCount;
        return event.wait(timeout, before) != before;
    }

    override void notifyAll() @safe
    {
        event.emit();
    }
}

/// `IoLock` for tasks: a vibe-core `TaskMutex`.
final class FiberLock : IoLock
{
    import vibe.core.sync : TaskMutex;

    private TaskMutex mutex;

    /// Creates an unlocked lock.
    this() @trusted
    {
        // TaskMutex derives from core.sync's Mutex, whose constructor is not @safe; creating it is memory-safe
        mutex = new TaskMutex;
    }

    override void lock() @trusted
    {
        mutex.lock();
    }

    override void unlock() @trusted
    {
        mutex.unlock();
    }
}

/// Whether the caller runs inside a vibe.d task.
bool inVibeTask() @safe nothrow
{
    import vibe.core.task : Task;

    return Task.getThis() != Task.init;
}

version (Windows)
{
    /++
    Whether the socket has data to read (or the peer closed it, or it failed),
    checked without reading. `TCPConnection.dataAvailableForRead` can't be used
    on Windows: it does an immediate read, and eventcore's WinAPI driver
    (0.9.x) loses the data of an immediate read that completes at once.
    +/
    private bool socketReadable(int fd) @trusted nothrow @nogc
    {
        import core.sys.windows.winsock2 : fd_set, select, SOCKET, timeval;

        // select() only reads the set and the zero timeout; the handle is the connection's socket
        fd_set set;
        set.fd_count = 1;
        set.fd_array[0] = cast(SOCKET) cast(uint) fd;
        timeval zero;
        return select(0, &set, null, null, &zero) != 0;
    }
}

private Thread currentThread() @trusted nothrow
{
    return Thread.getThis(); // returns the current thread object; no unsafe memory access
}
