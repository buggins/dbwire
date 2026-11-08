/++
Thread-mode I/O backend: blocking Phobos (`std.socket`) sockets.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.phobos;

import core.time : Duration;
import std.socket;

import dbwire.exception : ClientException, ConnectionException;
import dbwire.io.backend : clampWait, IoBackend, IoLock, longestWait, PoolSync;
import dbwire.io.transport : Transport, WaitableTransport;
import dbwire.io.unixsocket : displayPath, PeerCredentials, socketPeerUserId, UnixSocketBackend;

/// `Transport` over a connected, blocking `std.socket.Socket` (TCP or Unix-domain).
final class PhobosTransport : Transport, WaitableTransport, PeerCredentials
{
    private Socket socket;

    /// Wraps an already connected socket. The transport takes ownership of it.
    this(Socket socket) @safe
    {
        assert(socket !is null);
        this.socket = socket;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        for (;;)
        {
            const n = socket.receive(buffer);
            if (n != Socket.ERROR)
                return n;
            checkError("receive");
        }
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        while (data.length)
        {
            const n = socket.send(data);
            if (n == Socket.ERROR)
            {
                checkError("send");
                continue;
            }
            data = data[n .. $];
        }
    }

    override bool dataAvailable() @safe
    {
        auto readable = new SocketSet;
        readable.add(socket);
        try
            return Socket.select(readable, null, null, Duration.zero) > 0;
        catch (SocketException e)
            throw new ConnectionException("Socket select failed: " ~ e.msg);
    }

    /// Phobos sockets can wait (`select`).
    @property bool canWaitForData() @safe
    {
        return true;
    }

    /// Waits with `select` until the socket is readable (data or the end of the stream).
    bool waitForData(Duration timeout) @safe
    {
        auto readable = new SocketSet;
        for (;;)
        {
            readable.reset();
            readable.add(socket);
            try
            {
                int n;
                if (timeout == Duration.max)
                    n = Socket.select(readable, null, null);
                else
                    n = Socket.select(readable, null, null, clampWait(timeout));
                if (n >= 0)
                    return n > 0;
                // -1: interrupted by a signal; wait again (with the whole timeout: rare)
            }
            catch (SocketException e)
                throw new ConnectionException("Socket select failed: " ~ e.msg);
        }
    }

    override void close() @safe nothrow
    {
        try
        {
            if (socket.isAlive)
            {
                socket.shutdown(SocketShutdown.BOTH);
                socket.close();
            }
        }
        catch (Exception)
        {
            // closing is best effort
        }
    }

    override bool connected() const @safe nothrow
    {
        try
            return (() @trusted => (cast() socket).isAlive)(); // isAlive is not const in Phobos
        catch (Exception)
            return false;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, receive);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, send);
    }

    /// The user id of the peer process; only for Unix-domain sockets.
    uint peerUserId() @safe
    {
        if (socket.addressFamily != AddressFamily.UNIX)
            throw new ClientException("Peer credentials need a Unix-domain socket");
        return socketPeerUserId(socket.handle);
    }

    /// Returns normally if the failed call should be retried (interrupted by a signal).
    private void checkError(string operation) @safe
    {
        version (Posix)
        {
            import core.stdc.errno : EINTR, errno;

            if ((()@trusted => errno)() == EINTR)
                return;
        }
        if (wouldHaveBlocked())
            throw new ConnectionException("Socket " ~ operation ~ " timed out");
        throw new ConnectionException("Socket " ~ operation ~ " failed: " ~ lastSocketError());
    }
}

/// Thread-mode backend: connects with Phobos sockets.
final class PhobosBackend : IoBackend, UnixSocketBackend
{
    override @property string name() const @safe pure nothrow
    {
        return "phobos";
    }

    /// Does nothing: threads are scheduled by the operating system.
    override void yieldNow() @safe
    {
    }

    /// A mutex with a condition variable.
    override PoolSync newPoolSync() @safe
    {
        return new ThreadPoolSync;
    }

    /// A `core.sync` mutex.
    override IoLock newLock() @safe
    {
        return new ThreadLock;
    }

    /++
    Resolves `host` and connects to the first address that accepts the connection.

    Throws: `ConnectionException` if name resolution fails, every address
    refuses the connection, or `timeout` expires.
    +/
    override Transport connect(string host, ushort port, Duration timeout) @safe
    {
        Address[] addresses;
        try
            addresses = getAddress(host, port);
        catch (SocketException e)
            throw new ConnectionException("Cannot resolve host '" ~ host ~ "': " ~ e.msg);

        string lastError = "no addresses";
        foreach (address; addresses)
        {
            try
                return new PhobosTransport(connectSocket(address, timeout));
            catch (ConnectionException e)
                lastError = e.msg;
        }
        throw new ConnectionException("Cannot connect to " ~ host ~ ":" ~ portString(port) ~ ": " ~ lastError);
    }

    /++
    Connects to the Unix-domain socket at `path` (a Linux abstract socket when
    it starts with a zero byte).

    Throws: `ConnectionException` if the connection fails or times out,
    `ClientException` on platforms without Unix-domain sockets.
    +/
    Transport connectUnix(string path, Duration timeout) @safe
    {
        static if (is(UnixAddress))
        {
            Address address;
            try
                address = new UnixAddress(path);
            catch (SocketException e)
                throw new ConnectionException("Invalid Unix-domain socket path " ~ displayPath(path) ~ ": " ~ e.msg);
            try
                return new PhobosTransport(connectSocket(address, timeout, false));
            catch (ConnectionException e)
                throw new ConnectionException("Cannot connect to " ~ displayPath(path) ~ ": " ~ e.msg);
        }
        else
            throw new ClientException("Unix-domain sockets are not supported on this platform");
    }
}

/// `PoolSync` for threads: `core.sync` mutex and condition variable.
final class ThreadPoolSync : PoolSync
{
    import core.sync.condition : Condition;
    import core.sync.mutex : Mutex;

    private Mutex mutex;
    private Condition condition;

    /// Creates an unlocked lock.
    this() @trusted
    {
        // core.sync constructors are not annotated @safe; creating them is memory-safe
        mutex = new Mutex;
        condition = new Condition(mutex);
    }

    override void lock() @trusted
    {
        mutex.lock();
    }

    override void unlock() @trusted
    {
        mutex.unlock();
    }

    override bool wait(Duration timeout) @trusted
    {
        return condition.wait(timeout);
    }

    override void notifyAll() @trusted
    {
        condition.notifyAll();
    }
}

/// `IoLock` for threads: a `core.sync` mutex.
final class ThreadLock : IoLock
{
    import core.sync.mutex : Mutex;

    private Mutex mutex;

    /// Creates an unlocked lock.
    this() @trusted
    {
        // the core.sync constructor is not annotated @safe; creating a mutex is memory-safe
        mutex = new Mutex;
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

private Socket connectSocket(Address address, Duration timeout, bool tcp = true) @safe
{
    try
    {
        // Inside the try: a socket that can't be created (an address family the host
        // doesn't support, no file descriptors left) must let the caller try the next address
        auto socket = tcp ? new Socket(address.addressFamily, SocketType.STREAM, ProtocolType.TCP) : new Socket(
                address.addressFamily, SocketType.STREAM);
        scope (failure)
            socket.close();
        // Non-blocking connect, then wait for the result with select() to enforce the timeout.
        socket.blocking = false;
        socket.connect(address);
        auto writable = new SocketSet;
        auto failed = new SocketSet; // Windows reports a failed connect here
        writable.add(socket);
        failed.add(socket);
        const ready = Socket.select(null, writable, failed,
                timeout == Duration.zero ? longestWait : clampWait(timeout));
        const where = tcp ? address.toString() ~ ": " : "";
        if (ready == 0)
            throw new ConnectionException(where ~ "connect timed out");
        int[1] error;
        socket.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, error[]);
        if (error[0] != 0 || failed.isSet(socket))
            throw new ConnectionException(where ~ formatSocketError(error[0]));
        socket.blocking = true;
        if (tcp)
            socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
        return socket;
    }
    catch (SocketException e)
        throw new ConnectionException(tcp ? address.toString() ~ ": " ~ e.msg : e.msg);
}

private string portString(ushort port) @safe pure
{
    import std.conv : to;

    return port.to!string;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Connection refused: nothing listens on the port of a socket we bound but never listened on
    auto probe = new TcpSocket;
    probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    const port = (cast(InternetAddress) probe.localAddress).port;
    scope (exit)
        probe.close();
    assertThrown!ConnectionException(new PhobosBackend().connect("127.0.0.1", port, Duration.max));
}

@safe unittest
{
    import core.time : seconds;

    // Round trip through a local listening socket
    auto listener = new TcpSocket;
    listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    scope (exit)
        listener.close();
    listener.listen(1);
    const port = (cast(InternetAddress) listener.localAddress).port;

    auto client = new PhobosBackend().connect("127.0.0.1", port, 5.seconds);
    scope (exit)
        client.close();
    auto server = listener.accept();
    scope (exit)
        server.close();

    client.write([1, 2, 3]);
    ubyte[3] received;
    size_t got;
    while (got < 3)
        got += server.receive(received[got .. $]);
    assert(received == [1, 2, 3]);

    assert(!client.dataAvailable);
    // waiting: a timeout without data, then data sent from another thread
    {
        import core.thread : Thread;
        import core.time : MonoTime, msecs;

        auto waitable = cast(WaitableTransport) client;
        const start = MonoTime.currTime;
        assert(!waitable.waitForData(50.msecs) && MonoTime.currTime - start >= 40.msecs);
        static immutable ubyte[1] nineByte = [9];
        auto sender = new Thread(() @trusted { Thread.sleep(50.msecs); server.send(nineByte[]); }); // a helper thread
        (() @trusted => sender.start())();
        assert(waitable.waitForData(Duration.max));
        (() @trusted => sender.join())();
        auto nine = new ubyte[1];
        assert(client.read(nine) == 1 && nine[0] == 9);
    }
    server.send([7]);
    auto reply = new ubyte[1];
    while (!client.dataAvailable)
    {
    }
    assert(client.read(reply) == 1 && reply[0] == 7);
    assert(client.connected);
}

// Unix-domain sockets: round trip, the peer's user id, a missing socket, an abstract socket (Linux)
static if (is(UnixAddress))
    @safe unittest
    {
        import core.time : seconds;
        import std.algorithm.searching : canFind;
        import std.conv : to;
        import std.exception : assertThrown, collectException;
        import std.file : exists, remove, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;
        import dbwire.io.unixsocket : connectUnixSocket, peerUserId;

        void roundTrip(string path)
        {
            auto listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
            scope (exit)
                listener.close();
            listener.bind(new UnixAddress(path));
            listener.listen(1);

            auto client = connectUnixSocket(new PhobosBackend, path, 5.seconds);
            scope (exit)
                client.close();
            auto server = listener.accept();
            scope (exit)
                server.close();
            client.write([1, 2, 3]);
            ubyte[3] received;
            size_t got;
            while (got < 3)
                got += server.receive(received[got .. $]);
            assert(received == [1, 2, 3]);
            server.send([7]);
            auto reply = new ubyte[1];
            assert(client.read(reply) == 1 && reply[0] == 7);

            version (Posix)
                {
                import core.sys.posix.unistd : getuid;

                assert(peerUserId(client) == (() @trusted => getuid())());
            }
        }

        const path = buildPath(tempDir, "dbwire-test-" ~ thisProcessID.to!string ~ ".sock");
        if (exists(path))
            remove(path);
        roundTrip(path);
        remove(path);

        // nothing listens there now
        auto e = collectException!ConnectionException(new PhobosBackend().connectUnix(path, 5.seconds));
        assert(e !is null && e.msg.canFind(path), e is null ? "no exception" : e.msg);

        version (linux)
            roundTrip("\0dbwire-test-" ~ thisProcessID.to!string);

        // a TCP connection has no peer credentials
        auto tcpListener = new TcpSocket;
        scope (exit)
            tcpListener.close();
        tcpListener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        tcpListener.listen(1);
        auto tcp = new PhobosBackend().connect("127.0.0.1", (cast(InternetAddress) tcpListener.localAddress).port, 5
                .seconds);
        scope (exit)
            tcp.close();
        assertThrown!ClientException(peerUserId(tcp));
    }
