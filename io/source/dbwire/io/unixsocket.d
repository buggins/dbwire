/++
Unix-domain sockets: connecting through an I/O backend, and who runs the
process at the other end.

Both built-in backends connect to Unix-domain stream sockets on POSIX systems
(`UnixSocketBackend`, see `connectUnixSocket`), and their transports tell the
user id of the peer process (`PeerCredentials`, see `peerUserId`), e.g. to
check that a database server runs as the expected user.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.unixsocket;

import core.time : Duration;

import dbwire.exception : ClientException;
import dbwire.io.backend : IoBackend;
import dbwire.io.transport : Transport;

version (OSX)
    version = HaveGetpeereid;
else version (FreeBSD)
    version = HaveGetpeereid;
else version (OpenBSD)
    version = HaveGetpeereid;
else version (NetBSD)
    version = HaveGetpeereid;
else version (DragonFlyBSD)
    version = HaveGetpeereid;

version (HaveGetpeereid) private extern (C) int getpeereid(int socket, uint* euid, uint* egid) nothrow @nogc;

/++
An I/O backend that can connect to Unix-domain stream sockets. `PhobosBackend`
and `VibeBackend` implement it; call it through `connectUnixSocket`.
+/
interface UnixSocketBackend
{
    /++
    Connects to the Unix-domain socket at `path`, giving up after `timeout`.
    A path that starts with a zero byte names a Linux abstract socket.

    Throws: `ConnectionException` if the connection fails or times out,
    `ClientException` if the platform or I/O mode doesn't support it.
    +/
    Transport connectUnix(string path, Duration timeout) @safe;
}

/++
A transport over a Unix-domain socket that can tell who runs the process at
the other end. The Phobos and vibe.d transports implement it; call it through
`peerUserId`.
+/
interface PeerCredentials
{
    /++
    The effective user id of the peer process (`SO_PEERCRED` on Linux,
    `getpeereid` on macOS and the BSDs), as it was when the connection was
    made.

    Throws: `ClientException` if the transport is not a Unix-domain socket or
    the platform can't tell.
    +/
    uint peerUserId() @safe;
}

/++
Connects `backend` to the Unix-domain socket at `path` (see
`UnixSocketBackend.connectUnix`).

Throws: `ClientException` if the backend can't connect to Unix-domain
sockets, `ConnectionException` if the connection fails.
+/
Transport connectUnixSocket(IoBackend backend, string path, Duration timeout) @safe
{
    if (auto unix = cast(UnixSocketBackend) backend)
        return unix.connectUnix(path, timeout);
    throw new ClientException("The " ~ backend.name ~ " I/O backend can't connect to Unix-domain sockets");
}

/++
The effective user id of the process at the other end of `transport`, a
Unix-domain socket (see `PeerCredentials`).

Throws: `ClientException` if the transport can't tell.
+/
uint peerUserId(Transport transport) @safe
{
    if (auto credentials = cast(PeerCredentials) transport)
        return credentials.peerUserId();
    throw new ClientException("The connection can't tell the user of the peer process");
}

/++
The name of the user with id `uid`, from the system's user database
(`getpwuid_r`).

Throws: `ClientException` if no user has that id, or on Windows.
+/
string userName(uint uid) @safe
{
    version (Posix)
    {
        import core.stdc.errno : ERANGE;
        import std.conv : to;

        auto buffer = new char[1024];
        for (;;)
        {
            const user = lookUpUser(uid, buffer);
            if (user.error == ERANGE && buffer.length < 1 << 20)
            {
                buffer.length *= 2;
                continue;
            }
            if (user.error != 0 || !user.found)
                throw new ClientException("No user with id " ~ uid.to!string);
            return user.name;
        }
    }
    else
        throw new ClientException("User ids of local processes are not supported on this platform");
}

private struct UserLookup
{
    int error; // getpwuid_r's result
    bool found;
    string name;
}

/// `getpwuid_r` for `uid`, with `buffer` as its storage.
version (Posix) private UserLookup lookUpUser(uint uid, scope char[] buffer) @trusted
{
    import core.sys.posix.pwd : getpwuid_r, passwd;
    import std.string : fromStringz;

    // getpwuid_r writes at most buffer.length bytes into buffer and points `entry` into it;
    // the name is copied before the buffer can go away
    passwd entry;
    passwd* result;
    UserLookup user;
    user.error = getpwuid_r(uid, &entry, buffer.ptr, buffer.length, &result);
    user.found = user.error == 0 && result !is null;
    if (user.found)
        user.name = entry.pw_name.fromStringz.idup;
    return user;
}

/// `path` for messages: an abstract socket's leading zero byte shown as `@`, as Linux tools show it.
package string displayPath(string path) @safe pure
{
    return path.length && path[0] == '\0' ? "@" ~ path[1 .. $] : path;
}

/++
The effective user id of the peer of a connected Unix-domain socket `fd`.

Throws: `ClientException` if `fd` is not a Unix-domain socket or the platform can't tell.
+/
package uint socketPeerUserId(long fd) @trusted
{
    version (linux)
    {
        import core.stdc.errno : errno;
        import core.sys.posix.sys.socket : getsockopt, SOL_SOCKET, socklen_t;

        // struct ucred of <sys/socket.h>
        static struct Ucred
        {
            int pid;
            uint uid;
            uint gid;
        }

        // SO_PEERCRED differs between architectures
        version (PPC)
            enum soPeerCred = 21;
        else version (PPC64)
            enum soPeerCred = 21;
        else version (MIPS_Any)
            enum soPeerCred = 18;
        else version (SPARC_Any)
            enum soPeerCred = 0x40;
        else
            enum soPeerCred = 17;

        // getsockopt writes at most `length` bytes into `credentials`
        Ucred credentials;
        socklen_t length = Ucred.sizeof;
        if (getsockopt(cast(int) fd, SOL_SOCKET, soPeerCred, &credentials, &length) != 0)
            throw new ClientException("Cannot get the peer's credentials: " ~ errorText(errno));
        return credentials.uid;
    }
    else version (HaveGetpeereid)
    {
        import core.stdc.errno : errno;

        // getpeereid writes the two ids
        uint uid, gid;
        if (getpeereid(cast(int) fd, &uid, &gid) != 0)
            throw new ClientException("Cannot get the peer's credentials: " ~ errorText(errno));
        return uid;
    }
    else
        throw new ClientException("Peer credentials of Unix-domain sockets are not supported on this platform");
}

version (Posix) private string errorText(int code) @trusted
{
    import core.stdc.string : strerror_r;
    import std.string : fromStringz;

    // strerror_r writes at most buffer.length bytes, zero-terminated (strerror isn't thread-safe)
    char[256] buffer;
    version (CRuntime_Glibc)
        enum gnuVersion = true;
    else version (CRuntime_UClibc)
        enum gnuVersion = true;
    else
        enum gnuVersion = false;
    static if (gnuVersion)
        return strerror_r(code, buffer.ptr, buffer.length).fromStringz.idup; // the message: in buffer or static
    else
    {
        import std.conv : to;

        return strerror_r(code, buffer.ptr, buffer.length) == 0 ? buffer.ptr.fromStringz.idup
            : "error " ~ code.to!string;
    }
}

@safe unittest
{
    assert(displayPath("/run/postgresql/.s.PGSQL.5432") == "/run/postgresql/.s.PGSQL.5432");
    assert(displayPath("\0pg") == "@pg");
    assert(displayPath("") == "");
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // a transport that is not a socket can't tell
    assertThrown!ClientException(peerUserId(new MockTransport));
    version (Posix)
    {
        import core.sys.posix.unistd : getuid;

        assert(userName((() @trusted => getuid())()).length > 0);
    }
}
