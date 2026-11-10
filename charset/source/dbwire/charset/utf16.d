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

/++
Encodes as much of `text[pos .. $]` (UTF-8) as fits into `buffer` as UTF-16LE
(whole characters: one needs 2 bytes, or 4 for a surrogate pair), advances
`pos` past them and returns the number of bytes written. Calling it again
with the next buffer until `pos == text.length` gives exactly what
`encodeUtf16le` returns, without allocating; `utf16Length` tells the total
beforehand. A buffer of at least 4 bytes always makes progress.
+/
size_t encodeUtf16leInto(scope const(char)[] text, ref size_t pos, scope ubyte[] buffer) @safe pure nothrow @nogc
{
    return encodeInto!false(text, pos, buffer);
}

/// ditto, as UTF-16BE (`encodeUtf16be`).
size_t encodeUtf16beInto(scope const(char)[] text, ref size_t pos, scope ubyte[] buffer) @safe pure nothrow @nogc
{
    return encodeInto!true(text, pos, buffer);
}

/// The length in bytes of `text` (UTF-8) in UTF-16, as `encodeUtf16le` and `encodeUtf16be` encode it.
size_t utf16Length(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t length;
    for (size_t i = 0; i < text.length;)
    {
        if (text[i] < 0x80)
        {
            i++;
            length += 2;
            continue;
        }
        length += decodeUtf8Char(text, i) < 0x10000 ? 2 : 4; // invalid UTF-8: U+FFFD, 2 bytes
    }
    return length;
}

/// Whether `text` is all ASCII: its UTF-16 form then has one unit per `char`.
bool isAscii(scope const(char)[] text) @safe pure nothrow @nogc
{
    foreach (c; text)
        if (c >= 0x80)
            return false;
    return true;
}

///
@safe pure nothrow @nogc unittest
{
    // Into a small buffer, piece by piece: the same bytes as encodeUtf16le, one character never split
    static immutable text = "Grüße 😀!";
    ubyte[5] buffer;
    ubyte[32] all;
    size_t pos, length;
    while (pos < text.length)
    {
        const n = encodeUtf16leInto(text, pos, buffer[]);
        all[length .. length + n] = buffer[0 .. n];
        length += n;
    }
    assert(length == utf16Length(text) && length == 18);
    assert(all[0 .. 4] == [0x47, 0, 0x72, 0] && all[12 .. 16] == [0x3D, 0xD8, 0x00, 0xDE]); // G r, then 😀
    assert(isAscii("SELECT 1") && !isAscii(text));
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
    const length = encodeInto!bigEndian(text, pos, result);
    return result[0 .. length];
}

private size_t encodeInto(bool bigEndian)(scope const(char)[] text, ref size_t pos, scope ubyte[] buffer)
{
    size_t n;
    void put(uint unit) @safe pure nothrow @nogc
    {
        static if (bigEndian)
        {
            buffer[n] = cast(ubyte)(unit >> 8);
            buffer[n + 1] = cast(ubyte) unit;
        }
        else
        {
            buffer[n] = cast(ubyte) unit;
            buffer[n + 1] = cast(ubyte)(unit >> 8);
        }
        n += 2;
    }

    size_t i = pos;
    while (i < text.length)
    {
        if (text[i] < 0x80)
        {
            if (n + 2 > buffer.length)
                break;
            put(text[i++]);
            continue;
        }
        size_t next = i;
        const c = decodeUtf8Char(text, next); // invalid UTF-8 becomes U+FFFD
        if (n + (c < 0x10000 ? 2 : 4) > buffer.length)
            break;
        i = next;
        if (c < 0x10000)
            put(c);
        else
        {
            put(0xD800 + ((c - 0x10000) >> 10));
            put(0xDC00 + ((c - 0x10000) & 0x3FF));
        }
    }
    pos = i;
    return n;
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
    // The units from `i` on, as UTF-8 at `result[pos]`: their exact UTF-8 length (`write` false), then the characters
    size_t scan(bool write)(scope char[] result, size_t i, size_t pos) @safe pure nothrow @nogc
    {
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

    // Two passes into an array of the exact size, from `i` on (after `i` ASCII characters already in `prefix`)
    char[] exact(scope const(char)[] prefix, size_t i) @safe pure nothrow
    {
        auto full = uninitializedArray!(char[])(scan!false(null, i, i));
        full[0 .. i] = prefix[0 .. i];
        scan!true(full, i, i);
        return full;
    }

    // ASCII (most text) in one pass, one char per unit; text with other characters goes to `exact`
    if (!units || unit(bytes, 0) >= 0x80)
        return (() @trusted => cast(string) exact(null, 0))(); // unique: built here
    auto result = uninitializedArray!(char[])(units);
    foreach (i; 0 .. units)
    {
        const c = unit(bytes, i);
        if (c >= 0x80)
        {
            result = exact(result, i);
            break;
        }
        result[i] = cast(char) c;
    }
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

// Piecewise encoding gives the one-shot bytes for any input (invalid UTF-8 too) and buffer size from 4 bytes;
// utf16Length agrees; decoding an ASCII prefix then other units gives the same text as without the prefix
@safe unittest
{
    import std.random : Mt19937, uniform;

    auto rng = Mt19937(11);
    foreach (_; 0 .. 2000)
    {
        static immutable string[] pieces = [
            "a", "Z", " ", "é", "мир", "😀", "\xFF", "\xE2\x82", "\xED\xA0\x80", "\xF0"
        ];
        string text;
        foreach (i; 0 .. uniform(0, 30, rng))
            text ~= pieces[uniform(0, pieces.length, rng)];
        const oneShotLe = encodeUtf16le(text), oneShotBe = encodeUtf16be(text);
        bool ascii = true;
        foreach (c; text)
            ascii = ascii && c < 0x80;
        assert(utf16Length(text) == oneShotLe.length && isAscii(text) == ascii);
        auto buffer = new ubyte[uniform(4, 12, rng)];
        ubyte[] le, be;
        for (size_t pos; pos < text.length;)
            le ~= buffer[0 .. encodeUtf16leInto(text, pos, buffer)];
        for (size_t pos; pos < text.length;)
            be ~= buffer[0 .. encodeUtf16beInto(text, pos, buffer)];
        assert(le == oneShotLe && be == oneShotBe);
        // the fast ASCII path and the general path agree
        const prefix = "plain ascii prefix ";
        assert(decodeUtf16le(encodeUtf16le(prefix ~ text)) == prefix ~ decodeUtf16le(oneShotLe));
        assert(decodeUtf16be(encodeUtf16be(prefix ~ text)) == prefix ~ decodeUtf16be(oneShotBe));
    }
    size_t pos;
    ubyte[3] tooSmall;
    assert(encodeUtf16leInto("😀", pos, tooSmall[]) == 0 && pos == 0); // a pair needs 4 bytes
    assert(encodeUtf16leInto("ab", pos, tooSmall[]) == 2 && pos == 1);
}
