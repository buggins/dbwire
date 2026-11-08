/++
UTF-16 in either byte order: SQL Server's `nchar`/`nvarchar` and login strings
(little-endian), Oracle's national character set AL16UTF16 (big-endian).

Decoding never fails: unpaired surrogates, which UCS-2 data stored by older
software may contain, become U+FFFD. Encoding replaces invalid UTF-8 with
U+FFFD the same way.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.charset.utf16;

/// Encodes `text` (UTF-8) as UTF-16LE bytes.
ubyte[] encodeUtf16le(scope const(char)[] text) @safe pure nothrow
{
    return encodeUtf16!false(text);
}

/// Encodes `text` (UTF-8) as UTF-16BE bytes.
ubyte[] encodeUtf16be(scope const(char)[] text) @safe pure nothrow
{
    return encodeUtf16!true(text);
}

/// Decodes UTF-16LE bytes as UTF-8; an odd trailing byte is ignored.
string decodeUtf16le(scope const(ubyte)[] bytes) @safe pure nothrow
{
    return decodeUtf16!false(bytes);
}

/// Decodes UTF-16BE bytes as UTF-8; an odd trailing byte is ignored.
string decodeUtf16be(scope const(ubyte)[] bytes) @safe pure nothrow
{
    return decodeUtf16!true(bytes);
}

///
@safe unittest
{
    assert(encodeUtf16le("Ab") == [0x41, 0, 0x62, 0]);
    assert(encodeUtf16be("Ab") == [0, 0x41, 0, 0x62]);
    assert(decodeUtf16le(encodeUtf16le("Grüße, мир 😀")) == "Grüße, мир 😀"); // a surrogate pair too
    assert(decodeUtf16be(encodeUtf16be("Grüße, мир 😀")) == "Grüße, мир 😀");
    assert(decodeUtf16le([0x00, 0xD8, 0x41, 0x00]) == "\uFFFDA"); // an unpaired surrogate
    assert(decodeUtf16le([0x41, 0x00, 0x42]) == "A"); // an odd byte is ignored
}

private ubyte[] encodeUtf16(bool bigEndian)(scope const(char)[] text) @safe pure nothrow
{
    import std.array : uninitializedArray;

    // Each UTF-8 byte gives at most one UTF-16 unit: invalid bytes one U+FFFD, a
    // 4-byte sequence two units
    auto result = uninitializedArray!(ubyte[])(text.length * 2);
    size_t pos;
    void put(uint unit) @safe pure nothrow @nogc
    {
        static if (bigEndian)
        {
            result[pos] = cast(ubyte)(unit >> 8);
            result[pos + 1] = cast(ubyte) unit;
        }
        else
        {
            result[pos] = cast(ubyte) unit;
            result[pos + 1] = cast(ubyte)(unit >> 8);
        }
        pos += 2;
    }

    for (size_t i = 0; i < text.length;)
    {
        if (text[i] < 0x80)
        {
            put(text[i++]);
            continue;
        }
        const c = decodeUtf8Char(text, i); // invalid UTF-8 becomes U+FFFD
        if (c < 0x10000)
            put(c);
        else
        {
            put(0xD800 + ((c - 0x10000) >> 10));
            put(0xDC00 + ((c - 0x10000) & 0x3FF));
        }
    }
    return result[0 .. pos];
}

private string decodeUtf16(bool bigEndian)(scope const(ubyte)[] bytes) @safe pure nothrow
{
    import std.array : uninitializedArray;

    static uint unit(scope const(ubyte)[] b, size_t i) @safe pure nothrow @nogc
    {
        static if (bigEndian)
            return (b[2 * i] << 8) | b[2 * i + 1];
        else
            return b[2 * i] | (b[2 * i + 1] << 8);
    }

    const units = bytes.length / 2;
    // Two passes: the exact UTF-8 length, then the characters
    size_t scan(bool write)(scope char[] result) @safe pure nothrow @nogc
    {
        size_t pos;
        size_t i;
        while (i < units)
        {
            dchar c = unit(bytes, i++);
            if (c < 0x80)
            {
                static if (write)
                    result[pos] = cast(char) c;
                pos++;
                continue;
            }
            if (c >= 0xD800 && c <= 0xDBFF && i < units)
            {
                const low = unit(bytes, i);
                if (low >= 0xDC00 && low <= 0xDFFF)
                {
                    c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
                    i++;
                }
            }
            if (c >= 0xD800 && c <= 0xDFFF)
                c = 0xFFFD;
            static if (write)
                pos = putUtf8(result, pos, c);
            else
                pos += utf8Length(c);
        }
        return pos;
    }

    auto result = uninitializedArray!(char[])(scan!false(null));
    scan!true(result);
    return (() @trusted => cast(string) result)(); // result is unique: built here
}

/// Number of bytes of `c` (a valid code point) in UTF-8.
package size_t utf8Length(dchar c) @safe pure nothrow @nogc
{
    return c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
}

/// Writes `c` (a valid code point, not a surrogate) as UTF-8 at `buffer[pos]`,
/// which must have room for it, and returns the position after it.
package size_t putUtf8(scope char[] buffer, size_t pos, dchar c) @safe pure nothrow @nogc
{
    if (c < 0x80)
    {
        buffer[pos] = cast(char) c;
        return pos + 1;
    }
    if (c < 0x800)
    {
        buffer[pos] = cast(char)(0xC0 | (c >> 6));
        buffer[pos + 1] = cast(char)(0x80 | (c & 0x3F));
        return pos + 2;
    }
    if (c < 0x10000)
    {
        buffer[pos] = cast(char)(0xE0 | (c >> 12));
        buffer[pos + 1] = cast(char)(0x80 | ((c >> 6) & 0x3F));
        buffer[pos + 2] = cast(char)(0x80 | (c & 0x3F));
        return pos + 3;
    }
    buffer[pos] = cast(char)(0xF0 | (c >> 18));
    buffer[pos + 1] = cast(char)(0x80 | ((c >> 12) & 0x3F));
    buffer[pos + 2] = cast(char)(0x80 | ((c >> 6) & 0x3F));
    buffer[pos + 3] = cast(char)(0x80 | (c & 0x3F));
    return pos + 4;
}

/// Appends `c` (a valid code point, not a surrogate) to `buffer` as UTF-8.
package void appendUtf8(ref char[] buffer, dchar c) @safe pure nothrow
{
    char[4] bytes;
    buffer ~= bytes[0 .. putUtf8(bytes[], 0, c)];
}

/// Decodes the UTF-8 character at `text[i]` and moves `i` past it; invalid UTF-8 gives U+FFFD.
package dchar decodeUtf8Char(scope const(char)[] text, ref size_t i) @safe pure nothrow @nogc
{
    const c = decodeUtf8(text, i);
    return c < 0 ? 0xFFFD : c;
}

/++
Decodes the UTF-8 character at `text[i]` and moves `i` past it. An invalid
sequence gives -1 and `i` moves past its longest valid beginning (at least
one byte), as the Unicode standard recommends for replacing it with U+FFFD.
+/
package int decodeUtf8(scope const(char)[] text, ref size_t i) @safe pure nothrow @nogc
{
    const b0 = text[i++];
    if (b0 < 0x80)
        return b0;
    uint need, c, lo = 0x80, hi = 0xBF;
    if (b0 >= 0xC2 && b0 <= 0xDF)
    {
        need = 1;
        c = b0 & 0x1F;
    }
    else if (b0 >= 0xE0 && b0 <= 0xEF)
    {
        need = 2;
        c = b0 & 0x0F;
        if (b0 == 0xE0)
            lo = 0xA0; // no overlong forms
        else if (b0 == 0xED)
            hi = 0x9F; // no surrogates
    }
    else if (b0 >= 0xF0 && b0 <= 0xF4)
    {
        need = 3;
        c = b0 & 0x07;
        if (b0 == 0xF0)
            lo = 0x90; // no overlong forms
        else if (b0 == 0xF4)
            hi = 0x8F; // not above U+10FFFF
    }
    else
        return -1;
    foreach (k; 0 .. need)
    {
        if (i >= text.length || text[i] < lo || text[i] > hi)
            return -1;
        c = (c << 6) | (text[i++] & 0x3F);
        lo = 0x80;
        hi = 0xBF;
    }
    return c;
}

@safe unittest
{
    // invalid UTF-8 input is encoded as U+FFFD
    assert(encodeUtf16le("a\xFFb") == [0x61, 0, 0xFD, 0xFF, 0x62, 0]);
    // a high surrogate at the end, a low surrogate alone
    assert(decodeUtf16be([0xD8, 0x3D]) == "\uFFFD");
    assert(decodeUtf16be([0xDC, 0x00, 0x00, 0x41]) == "\uFFFDA");
    assert(decodeUtf16le([]) == "");
    // maximal subparts: E2 82 then 'a' is one U+FFFD; C0 and F8 are never valid
    assert(decodeUtf16le(encodeUtf16le("\xE2\x82a\xC0\xAF\xF8")) == "\uFFFDa\uFFFD\uFFFD\uFFFD");
    assert(encodeUtf16le("\xED\xA0\x80") == [0xFD, 0xFF, 0xFD, 0xFF, 0xFD, 0xFF]); // an encoded surrogate
}

// Valid text of every length class round-trips and matches Phobos' conversion
@safe unittest
{
    import std.conv : to;
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(7);
    foreach (_; 0 .. 200)
    {
        dchar[] chars;
        foreach (i; 0 .. uniform(0, 50, rng))
        {
            const kind = uniform(0, 4, rng);
            dchar c = kind == 0 ? uniform(0, 0x80, rng) : kind == 1 ? uniform(0x80, 0x800, rng) : kind == 2 ? uniform(
                    0x800, 0x10000, rng) : uniform(0x10000, 0x110000, rng);
            if (c >= 0xD800 && c <= 0xDFFF)
                c = 'x';
            chars ~= c;
        }
        const text = chars.to!string;
        const units = text.to!wstring;
        ubyte[] le, be;
        foreach (u; units)
        {
            le ~= [cast(ubyte) u, cast(ubyte)(u >> 8)];
            be ~= [cast(ubyte)(u >> 8), cast(ubyte) u];
        }
        assert(encodeUtf16le(text) == le && encodeUtf16be(text) == be);
        assert(decodeUtf16le(le) == text && decodeUtf16be(be) == text);
    }
}
