/++
Text in Windows code pages: the single-byte pages that SQL Server collations
use (437, 850, 874, 1250 to 1258) and UTF-8 (65001).

Bytes below 0x80 are ASCII in all of them. Decoding never fails: every byte of
a single-byte page maps to a character (undefined bytes as Windows maps them,
see `dbwire.charset.tables`), and invalid UTF-8 becomes U+FFFD. Encoding fails
on characters the code page doesn't have, unless a replacement byte is given.

The double-byte pages (932, 936, 949, 950) are not supported yet.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.charset.codepage;

import dbwire.exception : ClientException;
import dbwire.charset.tables;
import dbwire.charset.utf16 : appendUtf8, decodeUtf8;

/// The code page number of UTF-8.
enum uint utf8CodePage = 65_001;

private enum uint[] singleBytePages = [
    437, 850, 874, 1250, 1251, 1252, 1253, 1254, 1255, 1256, 1257, 1258
];

/// The supported code pages, in increasing order.
immutable uint[] supportedCodePages = singleBytePages ~ utf8CodePage;

/++
A character set given by its Windows code page number. Get one with `find` or
`get`; the default value is invalid.
+/
struct CodePage
{
    private uint number_;
    private immutable(wchar)[] high; // characters of bytes 0x80..0xFF; null for UTF-8
    private immutable(uint)[] reverse; // (character << 8 | byte) of `high`, sorted

    /// The code page number, e.g. 1252.
    @property uint number() const @safe pure nothrow @nogc
    {
        return number_;
    }

    /// Whether this is UTF-8.
    @property bool isUtf8() const @safe pure nothrow @nogc
    {
        return number_ == utf8CodePage;
    }

    /// Finds code page `number`; returns false if it is not supported.
    static bool find(uint number, out CodePage page) @safe pure nothrow @nogc
    {
        static CodePage make(uint n, immutable(wchar)[] high, immutable(uint)[] reverse) @safe pure nothrow @nogc
        {
            CodePage p;
            p.number_ = n;
            p.high = high;
            p.reverse = reverse;
            return p;
        }

        switch (number)
        {
            static foreach (n; singleBytePages)
            {
        case n:
                page = make(n, mixin("cp" ~ toChars(n))[], Reverse!n.table[]);
                return true;
            }
        case utf8CodePage:
            page = make(utf8CodePage, null, null);
            return true;
        default:
            return false;
        }
    }

    /++
    Code page `number`.

    Throws: `ClientException` if it is not supported.
    +/
    static CodePage get(uint number) @safe pure
    {
        import std.conv : to;

        CodePage page;
        if (!find(number, page))
            throw new ClientException("Code page " ~ number.to!string ~ " is not supported");
        return page;
    }

    /// Decodes `bytes` in this code page as UTF-8.
    string decode(scope const(ubyte)[] bytes) const @safe pure nothrow
    {
        size_t length;
        foreach (b; bytes)
            length += b < 0x80 ? 1 : high is null ? 4 : high[b - 0x80] < 0x800 ? 2 : 3;
        if (length == bytes.length) // ASCII
            return (() @trusted => cast(string) bytes.idup)();
        if (high is null)
            return decodeUtf8Text(bytes);
        auto result = new char[length];
        size_t pos;
        foreach (b; bytes)
        {
            if (b < 0x80)
            {
                result[pos++] = cast(char) b;
                continue;
            }
            const c = high[b - 0x80];
            if (c < 0x800)
            {
                result[pos++] = cast(char)(0xC0 | (c >> 6));
                result[pos++] = cast(char)(0x80 | (c & 0x3F));
            }
            else
            {
                result[pos++] = cast(char)(0xE0 | (c >> 12));
                result[pos++] = cast(char)(0x80 | ((c >> 6) & 0x3F));
                result[pos++] = cast(char)(0x80 | (c & 0x3F));
            }
        }
        return (() @trusted => cast(string) result)(); // result is unique: built here
    }

    /// The byte of character `c` in this single-byte code page, or -1 if it has none.
    int byteOf(dchar c) const @safe pure nothrow @nogc
    {
        if (c < 0x80)
            return c;
        if (c > 0xFFFF || high is null)
            return -1;
        size_t lo = 0, hi = reverse.length;
        const key = cast(uint) c << 8;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if ((reverse[mid] & ~0xFFu) < key)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < reverse.length && (reverse[lo] & ~0xFFu) == key ? reverse[lo] & 0xFF : -1;
    }

    /++
    Encodes `text` (UTF-8) in this code page.

    Throws: `ClientException` if `text` is not valid UTF-8 or has a character
    the code page doesn't have.
    +/
    ubyte[] encode(scope const(char)[] text) const @safe pure
    {
        return encodeImpl(text, -1);
    }

    /++
    Encodes `text` (UTF-8) in this code page; characters it doesn't have, and
    invalid UTF-8, become `replacement` (SQL Server converts them to `'?'`).
    +/
    ubyte[] encode(scope const(char)[] text, ubyte replacement) const @safe pure
    {
        return encodeImpl(text, replacement);
    }

    private ubyte[] encodeImpl(scope const(char)[] text, int replacement) const @safe pure
    {
        import std.conv : to;
        import std.format : format;

        bool ascii = true;
        foreach (char c; text)
            if (c >= 0x80)
            {
                ascii = false;
                break;
            }
        if (ascii)
            return cast(ubyte[]) text.dup;
        ubyte[] result;
        result.reserve(text.length);
        for (size_t i = 0; i < text.length;)
        {
            const start = i;
            const c = decodeUtf8(text, i);
            if (c >= 0 && high is null) // UTF-8: copy valid sequences
            {
                result ~= cast(const(ubyte)[]) text[start .. i];
                continue;
            }
            int b = c < 0 ? -1 : byteOf(c);
            if (b < 0)
            {
                if (replacement < 0)
                    throw new ClientException(c < 0 ? "Invalid UTF-8 in text to encode" : format(
                            "Character U+%04X has no equivalent in code page %s", c, number_.to!string));
                b = replacement;
            }
            result ~= cast(ubyte) b;
        }
        return result;
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;

    const cp = CodePage.get(1252);
    assert(cp.decode([0x63, 0x61, 0x66, 0xE9, 0x20, 0x80]) == "café €");
    assert(cp.encode("café €") == [0x63, 0x61, 0x66, 0xE9, 0x20, 0x80]);
    assertThrown!ClientException(cp.encode("мир")); // not in code page 1252
    assert(cp.encode("мир", '?') == "???");

    assert(CodePage.get(1251).decode([0xEC, 0xE8, 0xF0]) == "мир");
    assert(CodePage.get(utf8CodePage).decode([0xC3, 0xA9, 0xFF]) == "é\uFFFD"); // invalid UTF-8 becomes U+FFFD

    CodePage page;
    assert(!CodePage.find(932, page)); // double-byte pages: not yet
    assertThrown!ClientException(CodePage.get(932));
}

private string decodeUtf8Text(scope const(ubyte)[] bytes) @safe pure nothrow
{
    auto text = (() @trusted => cast(const(char)[]) bytes)();
    char[] result;
    result.reserve(bytes.length);
    for (size_t i = 0; i < text.length;)
    {
        const start = i;
        if (decodeUtf8(text, i) < 0)
            appendUtf8(result, 0xFFFD);
        else
            result ~= text[start .. i];
    }
    return (() @trusted => cast(string) result)(); // result is unique: built here
}

/// Sorted (character << 8 | byte) pairs of the upper half of code page `n`, built at compile time.
private template Reverse(uint n)
{
    static immutable uint[128] table = build(mixin("cp" ~ toChars(n)));
}

private uint[128] build(const wchar[128] high) @safe pure nothrow
{
    uint[128] r;
    foreach (i, c; high)
        r[i] = (cast(uint) c << 8) | cast(uint)(0x80 + i);
    // insertion sort (compile time, 128 entries)
    foreach (i; 1 .. r.length)
    {
        const v = r[i];
        size_t j = i;
        for (; j > 0 && r[j - 1] > v; j--)
            r[j] = r[j - 1];
        r[j] = v;
    }
    return r;
}

@safe unittest
{
    import std.exception : assertThrown;

    // every byte of every single-byte page decodes and encodes back
    foreach (n; supportedCodePages)
    {
        const cp = CodePage.get(n);
        assert(cp.number == n);
        if (cp.isUtf8)
            continue;
        foreach (b; 0 .. 256)
        {
            const ubyte[1] one = [cast(ubyte) b];
            assert(cp.encode(cp.decode(one[])) == one[]);
        }
    }
    // undefined bytes of 1252 decode as the C1 control of the same number, as on Windows
    assert(CodePage.get(1252).decode([0x81]) == "\u0081");

    const utf8 = CodePage.get(utf8CodePage);
    assert(utf8.encode("é😀") == cast(const(ubyte)[]) "é😀");
    assertThrown!ClientException(utf8.encode("a\xFF"));
    assert(utf8.encode("a\xFF", '?') == "a?");
    assert(utf8.decode(cast(const(ubyte)[]) "\uFFFD") == "\uFFFD"); // a real U+FFFD stays
    assertThrown!ClientException(CodePage.get(1252).encode("a\xFF"));
    assert(CodePage.get(1252).encode("😀", '?') == "?");
    assert(CodePage.get(437).decode([0xB0, 0xE1]) == "░ß");
    assert(CodePage.init.number == 0);
}

/// `n` in decimal, at compile time (`stringof` would append a `u`).
private string toChars(uint n) @safe pure nothrow
{
    string s;
    do
    {
        s = cast(char)('0' + n % 10) ~ s;
        n /= 10;
    }
    while (n != 0);
    return s;
}
