/++
MD4 (RFC 1320), for the NT hash of NTLM authentication (SQL Server integrated
logins). MD4 is broken as a general-purpose hash; it is here only because the
protocol requires it, and OpenSSL 3 offers it only in its legacy provider.

`MD4` follows Phobos' digest interface, so `std.digest.digest!MD4(data)` and
`std.digest.hmac.HMAC!MD4` work.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.crypto.md4;

/// The MD4 message digest, with Phobos' digest interface.
struct MD4
{
    /// The block size in bits (for `std.digest.hmac`).
    enum blockSize = 512;

    private uint[4] state = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476];
    private ubyte[64] buffer;
    private size_t buffered;
    private ulong count; // bytes hashed

    /// Starts a new digest.
    void start() @safe pure nothrow @nogc
    {
        this = MD4.init;
    }

    /// Adds `data` to the digest.
    void put(scope const(ubyte)[] data...) @safe pure nothrow @nogc
    {
        count += data.length;
        if (buffered)
        {
            const n = 64 - buffered < data.length ? 64 - buffered : data.length;
            buffer[buffered .. buffered + n] = data[0 .. n];
            buffered += n;
            data = data[n .. $];
            if (buffered < 64)
                return;
            transform(buffer);
            buffered = 0;
        }
        while (data.length >= 64)
        {
            transform(data[0 .. 64]);
            data = data[64 .. $];
        }
        buffer[0 .. data.length] = data[];
        buffered = data.length;
    }

    /// Returns the digest and starts a new one.
    ubyte[16] finish() @safe pure nothrow @nogc
    {
        const bits = count * 8;
        static immutable ubyte[64] padding = [0x80];
        put(padding[0 .. (buffered < 56 ? 56 - buffered : 120 - buffered)]);
        ubyte[8] length;
        foreach (i; 0 .. 8)
            length[i] = cast(ubyte)(bits >> (8 * i));
        put(length[]);
        ubyte[16] result;
        foreach (i, w; state)
            foreach (k; 0 .. 4)
                result[4 * i + k] = cast(ubyte)(w >> (8 * k));
        start();
        return result;
    }

    private void transform(scope const(ubyte)[] block) @safe pure nothrow @nogc
    {
        uint[16] x;
        foreach (i; 0 .. 16)
            x[i] = block[4 * i] | (block[4 * i + 1] << 8) | (block[4 * i + 2] << 16)
                | (cast(uint) block[4 * i + 3] << 24);
        uint a = state[0], b = state[1], c = state[2], d = state[3];

        static uint rotl(uint v, uint s) @safe pure nothrow @nogc
        {
            return (v << s) | (v >> (32 - s));
        }

        // round 1: F(x, y, z) = xy | ~x z
        static immutable uint[4] s1 = [3, 7, 11, 19];
        foreach (i; 0 .. 16)
        {
            const f = (b & c) | (~b & d);
            const t = rotl(a + f + x[i], s1[i % 4]);
            a = d;
            d = c;
            c = b;
            b = t;
        }
        // round 2: G(x, y, z) = xy | xz | yz, constant 0x5A827999, words by column
        static immutable uint[4] s2 = [3, 5, 9, 13];
        foreach (i; 0 .. 16)
        {
            const g = (b & c) | (b & d) | (c & d);
            const t = rotl(a + g + x[(i % 4) * 4 + i / 4] + 0x5A827999, s2[i % 4]);
            a = d;
            d = c;
            c = b;
            b = t;
        }
        // round 3: H(x, y, z) = x ^ y ^ z, constant 0x6ED9EBA1, words in bit-reversed order
        static immutable uint[16] order3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
        static immutable uint[4] s3 = [3, 9, 11, 15];
        foreach (i; 0 .. 16)
        {
            const h = b ^ c ^ d;
            const t = rotl(a + h + x[order3[i]] + 0x6ED9EBA1, s3[i % 4]);
            a = d;
            d = c;
            c = b;
            b = t;
        }
        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
    }
}

///
@safe unittest
{
    import std.digest : digest, isDigest, toHexString, LetterCase;

    static assert(isDigest!MD4);
    // RFC 1320 §A.5 test suite
    assert(digest!MD4("").toHexString!(LetterCase.lower) == "31d6cfe0d16ae931b73c59d7e0c089c0");
    assert(digest!MD4("a").toHexString!(LetterCase.lower) == "bde52cb31de33e46245e05fbdbd6fb24");
    assert(digest!MD4("abc").toHexString!(LetterCase.lower) == "a448017aaf21d8525fc10ae87aa6729d");
    assert(digest!MD4("message digest").toHexString!(LetterCase.lower) == "d9130a8164549fe818874806e1c7014b");
    assert(digest!MD4("abcdefghijklmnopqrstuvwxyz")
            .toHexString!(LetterCase.lower)
            == "d79e1c308aa5bbcdeea8ed63df412da9");
    assert(digest!MD4("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            .toHexString!(LetterCase.lower) == "043f8582f241db351ce627e153e7f0e4");
    assert(digest!MD4("12345678901234567890123456789012345678901234567890123456789012345678901234567890")
            .toHexString!(LetterCase.lower) == "e33b4ddc9c38f2199c3e7b164fcc0536");
    // fed in pieces
    MD4 m;
    foreach (c; "message digest")
        m.put(cast(ubyte) c);
    assert(m.finish().toHexString!(LetterCase.lower) == "d9130a8164549fe818874806e1c7014b");
}
