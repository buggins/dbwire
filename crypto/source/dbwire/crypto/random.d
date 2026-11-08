/++
Cryptographically secure random bytes from the operating system (Phobos has
no secure generator): `getrandom(2)` on Linux, with `/dev/urandom` as a
fallback; `arc4random_buf` on macOS and the BSDs; `BCryptGenRandom` on Windows.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.crypto.random;

import dbwire.exception : ClientException;

/++
Fills `buffer` with secure random bytes.

Throws: `ClientException` if the operating system can't provide them.
+/
void randomBytes(scope ubyte[] buffer) @safe
{
    if (buffer.length == 0)
        return;
    version (Windows)
    {
        while (buffer.length)
        {
            const n = buffer.length > uint.max ? uint.max : cast(size_t) buffer.length;
            if (systemRandom(buffer[0 .. n]) != 0)
                throw new ClientException("BCryptGenRandom failed");
            buffer = buffer[n .. $];
        }
    }
    else version (linux)
    {
        import core.stdc.errno : EINTR, ENOSYS;

        while (buffer.length)
        {
            const n = getRandom(buffer);
            if (n > 0)
            {
                buffer = buffer[n .. $];
                continue;
            }
            if (n < 0 && lastError() == EINTR)
                continue;
            if (n < 0 && lastError() == ENOSYS)
                return readUrandom(buffer); // kernels before 3.17
            throw new ClientException("getrandom failed");
        }
    }
    else static if (haveArc4random)
        arc4random(buffer);
    else
        readUrandom(buffer);
}

/// `n` secure random bytes.
ubyte[] randomBytes(size_t n) @safe
{
    auto b = new ubyte[n];
    randomBytes(b);
    return b;
}

version (Posix) private void readUrandom(scope ubyte[] buffer) @safe
{
    import core.stdc.errno : EINTR;

    const fd = openUrandom();
    if (fd < 0)
        throw new ClientException("Cannot open /dev/urandom");
    scope (exit)
        closeFile(fd);
    while (buffer.length)
    {
        const n = readFile(fd, buffer);
        if (n > 0)
            buffer = buffer[n .. $];
        else if (!(n < 0 && lastError() == EINTR))
            throw new ClientException("Cannot read /dev/urandom");
    }
}

// The system calls, each behind a safe interface: they write at most `buffer.length`
// bytes into `buffer`, and take no other pointers.
version (Windows)
{
    pragma(lib, "bcrypt");
    private enum uint bcryptUseSystemPreferredRng = 0x00000002;
    private extern (Windows) int BCryptGenRandom(void* algorithm, ubyte* buffer, uint length, uint flags) nothrow @nogc;

    private int systemRandom(scope ubyte[] buffer) @trusted nothrow @nogc
    {
        assert(buffer.length <= uint.max);
        return BCryptGenRandom(null, buffer.ptr, cast(uint) buffer.length, bcryptUseSystemPreferredRng);
    }
}

version (linux)
{
    // glibc 2.25+, musl 1.1.20+
    private extern (C) ptrdiff_t getrandom(void* buffer, size_t length, uint flags) nothrow @nogc;

    private ptrdiff_t getRandom(scope ubyte[] buffer) @trusted nothrow @nogc
    {
        return getrandom(buffer.ptr, buffer.length, 0);
    }
}

version (OSX)
    private enum bool haveArc4random = true;
else version (FreeBSD)
    private enum bool haveArc4random = true;
else version (OpenBSD)
    private enum bool haveArc4random = true;
else version (NetBSD)
    private enum bool haveArc4random = true;
else version (DragonFlyBSD)
    private enum bool haveArc4random = true;
else
    private enum bool haveArc4random = false;

static if (haveArc4random)
{
    private extern (C) void arc4random_buf(void* buffer, size_t length) nothrow @nogc;

    private void arc4random(scope ubyte[] buffer) @trusted nothrow @nogc
    {
        arc4random_buf(buffer.ptr, buffer.length);
    }
}

version (Posix)
{
    private int lastError() @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;

        return errno; // reads this thread's errno
    }

    private int openUrandom() @trusted nothrow @nogc
    {
        import core.sys.posix.fcntl : O_RDONLY, open;

        return open("/dev/urandom", O_RDONLY); // a zero-terminated literal
    }

    private ptrdiff_t readFile(int fd, scope ubyte[] buffer) @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : read;

        return read(fd, buffer.ptr, buffer.length);
    }

    private void closeFile(int fd) @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : close;

        close(fd); // only the descriptor openUrandom returned
    }
}

///
@safe unittest
{
    const a = randomBytes(32);
    const b = randomBytes(32);
    assert(a.length == 32 && a != b); // equal with probability 2^-256
    ubyte[1000] large;
    randomBytes(large[]);
    size_t zeros;
    foreach (x; large)
        zeros += x == 0;
    assert(zeros < 30); // about 4 expected
}
