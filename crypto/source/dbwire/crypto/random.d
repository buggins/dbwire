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
void randomBytes(scope ubyte[] buffer) @trusted
{
    if (buffer.length == 0)
        return;
    version (Windows)
    {
        while (buffer.length)
        {
            const n = buffer.length > uint.max ? uint.max : cast(uint) buffer.length;
            if (BCryptGenRandom(null, buffer.ptr, n, bcryptUseSystemPreferredRng) != 0)
                throw new ClientException("BCryptGenRandom failed");
            buffer = buffer[n .. $];
        }
    }
    else version (OSX)
        arc4random_buf(buffer.ptr, buffer.length);
    else version (FreeBSD)
        arc4random_buf(buffer.ptr, buffer.length);
    else version (OpenBSD)
        arc4random_buf(buffer.ptr, buffer.length);
    else version (NetBSD)
        arc4random_buf(buffer.ptr, buffer.length);
    else version (DragonFlyBSD)
        arc4random_buf(buffer.ptr, buffer.length);
    else version (linux)
    {
        import core.stdc.errno : EINTR, ENOSYS, errno;

        while (buffer.length)
        {
            const n = getrandom(buffer.ptr, buffer.length, 0);
            if (n > 0)
            {
                buffer = buffer[n .. $];
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == ENOSYS)
                return readUrandom(buffer); // kernels before 3.17
            throw new ClientException("getrandom failed");
        }
    }
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

version (Posix) private void readUrandom(scope ubyte[] buffer) @trusted
{
    import core.stdc.errno : EINTR, errno;
    import core.sys.posix.fcntl : O_RDONLY, open;
    import core.sys.posix.unistd : close, read;

    const fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0)
        throw new ClientException("Cannot open /dev/urandom");
    scope (exit)
        close(fd);
    while (buffer.length)
    {
        const n = read(fd, buffer.ptr, buffer.length);
        if (n > 0)
            buffer = buffer[n .. $];
        else if (!(n < 0 && errno == EINTR))
            throw new ClientException("Cannot read /dev/urandom");
    }
}

version (Windows)
{
    pragma(lib, "bcrypt");
    private enum uint bcryptUseSystemPreferredRng = 0x00000002;
    private extern (Windows) int BCryptGenRandom(void* algorithm, ubyte* buffer, uint length, uint flags) nothrow @nogc;
}
else version (linux)
{
    // glibc 2.25+, musl 1.1.20+
    private extern (C) ptrdiff_t getrandom(void* buffer, size_t length, uint flags) nothrow @nogc;
}
else version (Posix)
{
    private extern (C) void arc4random_buf(void* buffer, size_t length) nothrow @nogc;
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
