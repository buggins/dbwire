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
import dbwire.io.transport : Transport, WaitableTransport;
import dbwire.io.unixsocket : displayPath, PeerCredentials, socketPeerUserId, UnixSocketBackend;

/// `Transport` over a vibe-core `TCPConnection` (TCP or Unix-domain).
final class VibeTransport : Transport, WaitableTransport, PeerCredentials
{
    private TCPConnection connection;
    private Thread owner;
    private Duration receiveTimeout = Duration.max;
    // a Unix-domain socket; not taken from remoteAddress, which vibe-core 1.x can't read for them
    private bool unixSocket;

    /++
    Wraps a connected `TCPConnection`. The transport takes ownership of it.
    `unixSocket` tells that it is a Unix-domain socket, for `peerUserId`.
    +/
    this(TCPConnection connection, bool unixSocket = false) @safe
    {
        this.connection = connection;
        this.unixSocket = unixSocket;
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

    /// vibe-core connections can wait (`waitForDataEx`): the task is suspended meanwhile.
    @property bool canWaitForData() @safe
    {
        return true;
    }

    /// Waits until data can be read or the stream ended, suspending the task.
    bool waitForData(Duration timeout) @safe
    {
        checkThread();
        try
        {
            final switch (connection.waitForDataEx(timeout))
            {
            case WaitForDataStatus.dataAvailable:
            case WaitForDataStatus.noMoreData:
                return true;
            case WaitForDataStatus.timeout:
                return false;
            }
        }
        catch (InterruptException e)
            throw e; // Task.interrupt(): propagate as is
        catch (Exception e)
            throw new ConnectionException("Socket wait failed: " ~ e.msg);
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

    /// The user id of the peer process; only for Unix-domain sockets.
    uint peerUserId() @safe
    {
        checkThread();
        if (!unixSocket)
            throw new ClientException("Peer credentials need a Unix-domain socket");
        return socketPeerUserId(connection.fd);
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
final class VibeBackend : IoBackend, UnixSocketBackend
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
            return new VibeTransport(connectTCP(host, port, null, 0, unlimitedIfZero(timeout)));
        catch (InterruptException e)
            throw e; // the task was interrupted: not a reason to try the next host
        catch (Exception e)
            throw new ConnectionException("Cannot connect to " ~ host ~ ":" ~ port.to!string ~ ": " ~ e.msg);
    }

    /++
    Connects to the Unix-domain socket at `path` with `vibe.core.net.connectTCP`.
    Linux abstract sockets are not supported in fiber mode.

    vibe-core binds the client end of every Unix-domain socket it connects;
    without a name of its own, a second connection would fail ("bindFailure").
    Each connection therefore binds to a unique name: an abstract one on Linux,
    else a file in the temporary directory, removed once connected.

    Throws: `ConnectionException` on failure or timeout, `ClientException` for
    an abstract socket or on platforms without Unix-domain sockets.
    +/
    Transport connectUnix(string path, Duration timeout) @safe
    {
        version (Posix)
        {
            import std.socket : AddressFamily, SocketException, UnixAddress;
            import vibe.core.net : NetworkAddress;

            if (path.length && path[0] == '\0')
                throw new ClientException(
                        "Abstract Unix-domain sockets are not supported in fiber mode: "
                        ~ displayPath(path));
            NetworkAddress address, local;
            string localFile;
            try
            {
                address = unixAddress(new UnixAddress(path));
                localFile = clientSocketName();
                local = unixAddress(new UnixAddress(localFile));
            }
            catch (SocketException e)
                throw new ConnectionException("Invalid Unix-domain socket path " ~ path ~ ": " ~ e.msg);
            version (linux)
            {
            }
            else
                scope (exit)
                    removeFile(localFile);
            try
                return new VibeTransport(connectTCP(address, local, unlimitedIfZero(timeout)), true);
            catch (InterruptException e)
                throw e;
            catch (Exception e)
                throw new ConnectionException("Cannot connect to " ~ path ~ ": " ~ e.msg);
        }
        else
            throw new ClientException("Unix-domain sockets are not supported on this platform");
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

version (Posix)
{
    import vibe.core.net : NetworkAddress;
    import std.socket : UnixAddress;

    /// A vibe-core address for a Phobos Unix-domain address.
    private NetworkAddress unixAddress(UnixAddress source) @trusted
    {
        import core.sys.posix.sys.un : sockaddr_un;
        import std.socket : AddressFamily;

        // UnixAddress keeps a whole sockaddr_un; NetworkAddress(Address) can't be used,
        // it asserts that the address length is the structure's size
        NetworkAddress address;
        address.family = AddressFamily.UNIX;
        *address.sockAddrUnix = *cast(const(sockaddr_un)*) source.name;
        return address;
    }

    private shared ulong clientSocketCounter; // numbers the names of clientSocketName

    /++
    A unique name for the client end of a Unix-domain connection: abstract on
    Linux (`\0dbwire-<pid>-<n>`), else a file in the temporary directory.
    +/
    private string clientSocketName() @safe
    {
        import core.atomic : atomicOp;
        import std.conv : to;
        import std.process : thisProcessID;

        const name = "dbwire-" ~ thisProcessID.to!string ~ "-" ~ atomicOp!"+="(clientSocketCounter, 1).to!string;
        version (linux)
            return "\0" ~ name;
        else
        {
            import std.file : tempDir;
            import std.path : buildPath;

            const file = buildPath(tempDir, name ~ ".sock");
            removeFile(file); // left over by a crashed process with the same id
            return file;
        }
    }

    private void removeFile(string file) @safe nothrow
    {
        import std.file : remove;

        try
            remove(file);
        catch (Exception)
        {
            // missing: nothing to remove
        }
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

// vibe-core's connectTCP takes Duration.max for no limit; our backends also accept zero
private Duration unlimitedIfZero(Duration timeout) @safe pure nothrow @nogc
{
    return timeout == Duration.zero ? Duration.max : timeout;
}
