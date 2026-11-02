/++
AES (FIPS-197) with 128-, 192- and 256-bit keys, the CBC mode (NIST SP
800-38A) and PKCS#7 padding: for the password exchange of database logins
(Oracle O5LOGON encrypts session keys and the password with AES-CBC).

The implementation works byte by byte with table lookups: it is not
constant-time, which is acceptable for the few blocks of a login handshake on
the client side, but not for bulk encryption of attacker-chosen data.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.crypto.aes;

import dbwire.exception : ClientException;

/// The AES block size in bytes.
enum size_t aesBlockSize = 16;

/// An AES key schedule for encryption and decryption of single blocks.
struct Aes
{
    private uint[60] roundKeys; // 4 × (rounds + 1) words
    private uint rounds;

    /++
    Expands `key` (16, 24 or 32 bytes: AES-128, AES-192, AES-256).

    Throws: `ClientException` for other key lengths.
    +/
    this(scope const(ubyte)[] key) @safe pure
    {
        if (key.length != 16 && key.length != 24 && key.length != 32)
            throw new ClientException("AES keys are 16, 24 or 32 bytes long");
        const nk = cast(uint)(key.length / 4);
        rounds = nk + 6;
        foreach (i; 0 .. nk)
            roundKeys[i] = (key[4 * i] << 24) | (key[4 * i + 1] << 16) | (key[4 * i + 2] << 8) | key[4 * i + 3];
        ubyte rcon = 1;
        foreach (i; nk .. 4 * (rounds + 1))
        {
            uint t = roundKeys[i - 1];
            if (i % nk == 0)
            {
                t = subWord((t << 8) | (t >> 24)) ^ (cast(uint) rcon << 24);
                rcon = xtime(rcon);
            }
            else if (nk > 6 && i % nk == 4)
                t = subWord(t);
            roundKeys[i] = roundKeys[i - nk] ^ t;
        }
    }

    /// The key length in bytes (16, 24 or 32); 0 for an empty schedule.
    @property size_t keyLength() const @safe pure nothrow @nogc
    {
        return rounds == 0 ? 0 : (rounds - 6) * 4;
    }

    /// Encrypts one block in place.
    void encryptBlock(ref ubyte[aesBlockSize] block) const @safe pure nothrow @nogc
    {
        assert(rounds != 0, "AES key not set");
        addRoundKey(block, 0);
        foreach (round; 1 .. rounds)
        {
            subBytes(block);
            shiftRows(block);
            mixColumns(block);
            addRoundKey(block, round);
        }
        subBytes(block);
        shiftRows(block);
        addRoundKey(block, rounds);
    }

    /// Decrypts one block in place.
    void decryptBlock(ref ubyte[aesBlockSize] block) const @safe pure nothrow @nogc
    {
        assert(rounds != 0, "AES key not set");
        addRoundKey(block, rounds);
        foreach_reverse (round; 1 .. rounds)
        {
            invShiftRows(block);
            invSubBytes(block);
            addRoundKey(block, round);
            invMixColumns(block);
        }
        invShiftRows(block);
        invSubBytes(block);
        addRoundKey(block, 0);
    }

    private void addRoundKey(ref ubyte[aesBlockSize] s, uint round) const @safe pure nothrow @nogc
    {
        foreach (c; 0 .. 4)
        {
            const w = roundKeys[4 * round + c];
            s[4 * c] ^= cast(ubyte)(w >> 24);
            s[4 * c + 1] ^= cast(ubyte)(w >> 16);
            s[4 * c + 2] ^= cast(ubyte)(w >> 8);
            s[4 * c + 3] ^= cast(ubyte) w;
        }
    }
}

/++
Encrypts `data` (a multiple of 16 bytes; pad it first, see `pkcs7Pad`) in CBC
mode with the initialization vector `iv`.

Throws: `ClientException` if the length is not a multiple of the block size.
+/
ubyte[] cbcEncrypt(const ref Aes aes, const ubyte[aesBlockSize] iv, scope const(ubyte)[] data) @safe pure
{
    checkBlocks(data.length);
    auto result = new ubyte[data.length];
    ubyte[aesBlockSize] chain = iv;
    for (size_t i = 0; i < data.length; i += aesBlockSize)
    {
        foreach (k; 0 .. aesBlockSize)
            chain[k] ^= data[i + k];
        aes.encryptBlock(chain);
        result[i .. i + aesBlockSize] = chain[];
    }
    return result;
}

/++
Decrypts `data` (a multiple of 16 bytes) in CBC mode with the initialization
vector `iv`. Padding is left in place (see `pkcs7Unpad`).

Throws: `ClientException` if the length is not a multiple of the block size.
+/
ubyte[] cbcDecrypt(const ref Aes aes, const ubyte[aesBlockSize] iv, scope const(ubyte)[] data) @safe pure
{
    checkBlocks(data.length);
    auto result = new ubyte[data.length];
    ubyte[aesBlockSize] previous = iv;
    for (size_t i = 0; i < data.length; i += aesBlockSize)
    {
        ubyte[aesBlockSize] block = data[i .. i + aesBlockSize];
        aes.decryptBlock(block);
        foreach (k; 0 .. aesBlockSize)
            result[i + k] = block[k] ^ previous[k];
        previous = data[i .. i + aesBlockSize];
    }
    return result;
}

/++
`data` followed by PKCS#7 padding to a multiple of `blockSize` (1 to 255):
always 1 to `blockSize` bytes, each holding the padding length, so a whole
block is added when the length is already a multiple.
+/
ubyte[] pkcs7Pad(scope const(ubyte)[] data, size_t blockSize = aesBlockSize) @safe pure nothrow
{
    assert(blockSize >= 1 && blockSize <= 255, "PKCS#7 block sizes are 1 to 255");
    const n = blockSize - data.length % blockSize;
    auto result = new ubyte[data.length + n];
    result[0 .. data.length] = data[];
    result[data.length .. $] = cast(ubyte) n;
    return result;
}

/++
`data` without its PKCS#7 padding.

Throws: `ClientException` if the padding is invalid.
+/
const(ubyte)[] pkcs7Unpad(return scope const(ubyte)[] data, size_t blockSize = aesBlockSize) @safe pure
{
    if (data.length == 0 || data.length % blockSize != 0)
        throw new ClientException("Invalid PKCS#7 padding");
    const n = data[$ - 1];
    if (n == 0 || n > blockSize)
        throw new ClientException("Invalid PKCS#7 padding");
    foreach (b; data[$ - n .. $])
        if (b != n)
            throw new ClientException("Invalid PKCS#7 padding");
    return data[0 .. $ - n];
}

private void checkBlocks(size_t length) @safe pure
{
    if (length % aesBlockSize != 0)
        throw new ClientException("AES-CBC data must be a multiple of 16 bytes");
}

// --- the cipher's building blocks (FIPS-197 §5) ---

/// Multiplication by x in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1.
private ubyte xtime(ubyte b) @safe pure nothrow @nogc
{
    return cast(ubyte)((b << 1) ^ ((b & 0x80) ? 0x1B : 0));
}

/// Multiplication in GF(2^8).
private ubyte gmul(ubyte a, ubyte b) @safe pure nothrow @nogc
{
    ubyte p;
    foreach (_; 0 .. 8)
    {
        if (b & 1)
            p ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return p;
}

/// The S-box (FIPS-197 §5.1.1): the multiplicative inverse in GF(2^8), then the affine transformation.
private immutable ubyte[256] sbox = () {
    ubyte[256] s;
    foreach (x; 0 .. 256)
    {
        ubyte inv;
        if (x != 0)
            foreach (y; 1 .. 256)
                if (gmul(cast(ubyte) x, cast(ubyte) y) == 1)
                {
                    inv = cast(ubyte) y;
                    break;
                }
        ubyte r = inv;
        foreach (shift; 1 .. 5)
            r ^= cast(ubyte)((inv << shift) | (inv >> (8 - shift)));
        s[x] = r ^ 0x63;
    }
    return s;
}();

private immutable ubyte[256] invSbox = () {
    ubyte[256] s;
    foreach (x; 0 .. 256)
        s[sbox[x]] = cast(ubyte) x;
    return s;
}();

private uint subWord(uint w) @safe pure nothrow @nogc
{
    return (sbox[w >> 24] << 24) | (sbox[(w >> 16) & 0xFF] << 16) | (sbox[(w >> 8) & 0xFF] << 8) | sbox[w & 0xFF];
}

private void subBytes(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    foreach (ref b; s)
        b = sbox[b];
}

private void invSubBytes(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    foreach (ref b; s)
        b = invSbox[b];
}

// The state is column-major: byte r + 4c is row r, column c.
private void shiftRows(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    const ubyte[aesBlockSize] t = s;
    foreach (c; 0 .. 4)
        foreach (r; 1 .. 4)
            s[r + 4 * c] = t[r + 4 * ((c + r) % 4)];
}

private void invShiftRows(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    const ubyte[aesBlockSize] t = s;
    foreach (c; 0 .. 4)
        foreach (r; 1 .. 4)
            s[r + 4 * ((c + r) % 4)] = t[r + 4 * c];
}

private void mixColumns(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    foreach (c; 0 .. 4)
    {
        const a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
        s[4 * c] = cast(ubyte)(xtime(a0) ^ xtime(a1) ^ a1 ^ a2 ^ a3);
        s[4 * c + 1] = cast(ubyte)(a0 ^ xtime(a1) ^ xtime(a2) ^ a2 ^ a3);
        s[4 * c + 2] = cast(ubyte)(a0 ^ a1 ^ xtime(a2) ^ xtime(a3) ^ a3);
        s[4 * c + 3] = cast(ubyte)(xtime(a0) ^ a0 ^ a1 ^ a2 ^ xtime(a3));
    }
}

private void invMixColumns(ref ubyte[aesBlockSize] s) @safe pure nothrow @nogc
{
    foreach (c; 0 .. 4)
    {
        const a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
        s[4 * c] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
        s[4 * c + 1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
        s[4 * c + 2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
        s[4 * c + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
    }
}

version (unittest) private ubyte[] unhex(string s) @safe pure
{
    import std.conv : to;

    ubyte[] r;
    for (size_t i = 0; i < s.length; i += 2)
        r ~= s[i .. i + 2].to!ubyte(16);
    return r;
}

///
@safe unittest
{
    // FIPS-197 Appendix C: one block with AES-128, AES-192 and AES-256
    const ubyte[16] plain = unhex("00112233445566778899aabbccddeeff")[0 .. 16];
    foreach (k; [
            ["000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"],
            ["000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"],
            [
                "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                "8ea2b7ca516745bfeafc49904b496089"
            ]
        ])
    {
        const aes = Aes(unhex(k[0]));
        ubyte[16] block = plain;
        aes.encryptBlock(block);
        assert(block[] == unhex(k[1]));
        aes.decryptBlock(block);
        assert(block == plain);
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    // NIST SP 800-38A F.2.1 / F.2.5: CBC-AES128 and CBC-AES256, four blocks
    const ubyte[16] iv = unhex("000102030405060708090a0b0c0d0e0f")[0 .. 16];
    const plain = unhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
            ~ "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
    const aes128 = Aes(unhex("2b7e151628aed2a6abf7158809cf4f3c"));
    const c128 = cbcEncrypt(aes128, iv, plain);
    assert(c128 == unhex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"
            ~ "73bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7"));
    assert(cbcDecrypt(aes128, iv, c128) == plain);
    const aes256 = Aes(unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"));
    const c256 = cbcEncrypt(aes256, iv, plain);
    assert(c256 == unhex("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
            ~ "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b"));
    assert(cbcDecrypt(aes256, iv, c256) == plain);

    assert(pkcs7Pad([1, 2, 3]).length == 16 && pkcs7Pad([1, 2, 3])[$ - 1] == 13);
    assert(pkcs7Pad(new ubyte[16]).length == 32); // a whole block when aligned
    assert(pkcs7Unpad(pkcs7Pad([1, 2, 3])) == [1, 2, 3]);
    ubyte[16] bad = 0;
    assertThrown!ClientException(pkcs7Unpad(bad[]));
    assertThrown!ClientException(Aes(new ubyte[15]));
    assertThrown!ClientException(cbcEncrypt(aes128, iv, new ubyte[17]));
    assert(aes256.keyLength == 32 && Aes.init.keyLength == 0);
}
