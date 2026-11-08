/++
Text in Windows code pages: the code pages that SQL Server collations use,
single-byte (437, 850, 874, 1250 to 1258) and double-byte (932 Japanese, 936
Simplified Chinese, 949 Korean, 950 Traditional Chinese), and UTF-8 (65001).

Bytes below 0x80 are ASCII in all of them. Decoding never fails, and follows
Windows' own conversion: every byte of a single-byte page maps to a character
(undefined bytes as Windows maps them, see `dbwire.charset.tables`); in a
double-byte page a lead byte and the next byte make one character, an invalid
pair gives the page's default character (U+30FB in 932, `?` in the others), a
lead byte before 0x00 gives the default character and the 0x00, and a lead byte
at the end is dropped; invalid UTF-8 becomes U+FFFD. Encoding fails on
characters the code page doesn't have, unless a replacement byte is given; it
never substitutes a similar character ("best fit").

The tables of the double-byte pages are produced by SQL Server converting every
byte pair, and every character back (`charset/tables/README.md`); they follow
Windows, e.g. the bytes 0xC6A1 to 0xC7FC of 950 are private-use characters.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.charset.codepage;

import dbwire.exception : ClientException;
import dbwire.charset.tables;
import dbwire.charset.utf16 : appendUtf8, decodeUtf8, putUtf8, utf8Length;

/// The code page number of UTF-8.
enum uint utf8CodePage = 65_001;

private enum uint[] singleBytePages = [
    437, 850, 874, 1250, 1251, 1252, 1253, 1254, 1255, 1256, 1257, 1258
];

private enum uint[] doubleBytePages = [932, 936, 949, 950];

/// The supported code pages, in increasing order.
immutable uint[] supportedCodePages = [
    437, 850, 874, 932, 936, 949, 950, 1250, 1251, 1252, 1253, 1254, 1255, 1256, 1257, 1258,
    utf8CodePage
];

/++
A character set given by its Windows code page number. Get one with `find` or
`get`; the default value is invalid.
+/
struct CodePage
{
    private uint number_;
    private immutable(wchar)[] high; // characters of bytes 0x80..0xFF; null for UTF-8
    private immutable(uint)[] reverse; // (character << 8 | byte) of `high`, sorted
    private immutable(ubyte)[] dbcs; // double-byte pages: the decode table (see Dbcs)
    private immutable(ubyte)[] dbcsLeads; // lead byte -> its table's number + 1; 0 if not a lead byte
    private immutable(ubyte)[] dbcsEncode; // (u16 character, u16 bytes) pairs, sorted by character

    /// The code page number, e.g. 1252.
    @property uint number() const @safe pure nothrow @nogc
    {
        return number_;
    }

    /// Whether this is a double-byte code page (932, 936, 949, 950).
    @property bool isDoubleByte() const @safe pure nothrow @nogc
    {
        return dbcs !is null;
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
            static foreach (n; doubleBytePages)
            {
        case n:
                page = make(n, null, null);
                page.dbcs = Dbcs!n.decode;
                page.dbcsLeads = Dbcs!n.leads[];
                page.dbcsEncode = Dbcs!n.encode;
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
        if (dbcs !is null)
            return decodeDoubleByte(bytes);
        size_t length;
        foreach (b; bytes)
            length += b < 0x80 ? 1 : high is null ? 4 : high[b - 0x80] < 0x800 ? 2 : 3;
        if (length == bytes.length) // ASCII
            return cast(string) bytes.idup;
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

    private string decodeDoubleByte(scope const(ubyte)[] bytes) const @safe pure nothrow
    {
        import std.array : uninitializedArray;

        // Two passes: the exact UTF-8 length, then the characters
        size_t scan(bool write)(scope char[] result) const @safe pure nothrow @nogc
        {
            size_t pos;
            void put(dchar c) @safe pure nothrow @nogc
            {
                static if (write)
                    pos = putUtf8(result, pos, c);
                else
                    pos += utf8Length(c);
            }

            for (size_t i = 0; i < bytes.length;)
            {
                const b = bytes[i];
                if (b < 0x80)
                {
                    static if (write)
                        result[pos] = cast(char) b;
                    pos++;
                    i++;
                    continue;
                }
                const lead = dbcsLeads[b];
                if (lead == 0)
                {
                    put(dbcsChar(0, b)); // a single byte
                    i++;
                    continue;
                }
                if (i + 1 >= bytes.length)
                    break; // a lead byte at the end: dropped, as Windows does
                const trail = bytes[i + 1];
                put(dbcsChar(lead, trail)); // trail 0: the default character
                i += trail == 0 ? 1 : 2; // a 0x00 trail byte stays a character of its own
            }
            return pos;
        }

        auto result = uninitializedArray!(char[])(scan!false(null));
        scan!true(result);
        return (() @trusted => cast(string) result)(); // result is unique: built here
    }

    /// Entry `index` of table `table` (0: the single bytes) of the double-byte decode table.
    private wchar dbcsChar(size_t table, size_t index) const @safe pure nothrow @nogc
    {
        const at = (table * 256 + index) * 2;
        return cast(wchar)(dbcs[at] | (dbcs[at + 1] << 8));
    }

    /++
    The bytes of character `c` in this code page, or -1 if it has none: one
    byte (below 0x100), or a lead and a trail byte (`lead << 8 | trail`) in a
    double-byte page.
    +/
    int bytesOf(dchar c) const @safe pure nothrow @nogc
    {
        if (dbcs is null)
            return byteOf(c);
        if (c < 0x80)
            return c;
        if (c > 0xFFFF)
            return -1;
        size_t lo = 0, hi = dbcsEncode.length / 4;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            const key = dbcsEncode[4 * mid] | (dbcsEncode[4 * mid + 1] << 8);
            if (key < c)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo == dbcsEncode.length / 4 || (dbcsEncode[4 * lo] | (dbcsEncode[4 * lo + 1] << 8)) != c)
            return -1;
        return dbcsEncode[4 * lo + 2] | (dbcsEncode[4 * lo + 3] << 8);
    }

    /// The byte of character `c` in this code page, or -1 if it has none or needs two bytes (see `bytesOf`).
    int byteOf(dchar c) const @safe pure nothrow @nogc
    {
        if (c < 0x80)
            return c;
        if (dbcs !is null)
        {
            const b = bytesOf(c);
            return b < 0x100 ? b : -1;
        }
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
        import std.array : uninitializedArray;
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
        // Never longer than the text: each character (or invalid sequence) gives at most
        // as many bytes as its UTF-8 form has
        auto result = uninitializedArray!(ubyte[])(text.length);
        size_t pos;
        for (size_t i = 0; i < text.length;)
        {
            const start = i;
            const c = decodeUtf8(text, i);
            if (c >= 0 && isUtf8) // UTF-8: copy valid sequences
            {
                result[pos .. pos + i - start] = cast(const(ubyte)[]) text[start .. i];
                pos += i - start;
                continue;
            }
            int b = c < 0 ? -1 : bytesOf(c);
            if (b < 0)
            {
                if (replacement < 0)
                    throw new ClientException(c < 0 ? "Invalid UTF-8 in text to encode" : format(
                            "Character U+%04X has no equivalent in code page %s", c, number_.to!string));
                b = replacement;
            }
            if (b >= 0x100)
                result[pos++] = cast(ubyte)(b >> 8); // the lead byte
            result[pos++] = cast(ubyte) b;
        }
        return result[0 .. pos];
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

    const japanese = CodePage.get(932); // Shift-JIS, as Windows has it
    assert(japanese.decode([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x20, 0xB1]) == "日本語 ｱ");
    assert(japanese.encode("日本語 ｱ") == [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x20, 0xB1]);

    CodePage page;
    assert(!CodePage.find(20_127, page));
    assertThrown!ClientException(CodePage.get(20_127));
}

private string decodeUtf8Text(scope const(ubyte)[] bytes) @safe pure nothrow
{
    import std.array : uninitializedArray;

    const text = cast(const(char)[]) bytes;
    // Two passes: the length with each invalid sequence replaced by U+FFFD (3 bytes), then the text
    bool replaced;
    size_t scan(bool write)(scope char[] result) @safe pure nothrow @nogc
    {
        size_t pos;
        for (size_t i = 0; i < text.length;)
        {
            const start = i;
            if (text[i] < 0x80)
                i++;
            else if (decodeUtf8(text, i) < 0)
            {
                replaced = true;
                static if (write)
                    putUtf8(result, pos, 0xFFFD);
                pos += 3;
                continue;
            }
            static if (write)
                result[pos .. pos + i - start] = text[start .. i];
            pos += i - start;
        }
        return pos;
    }

    const length = scan!false(null);
    if (!replaced)
        return text.idup; // valid UTF-8 as it is
    auto result = uninitializedArray!(char[])(length);
    scan!true(result);
    return (() @trusted => cast(string) result)(); // result is unique: built here
}

/++
The tables of double-byte code page `n` (files in `charset/tables`, see its README):
`decode`: 256 little-endian `u16` for the single bytes (0xFFFF for lead bytes),
then 256 for each lead byte in increasing order (entry 0: the default
character); `encode`: (`u16` character, `u16` bytes) pairs sorted by character.
+/
private template Dbcs(uint n)
{
    static immutable ubyte[] decode = cast(immutable(ubyte)[]) import("cp" ~ toChars(n) ~ ".bin");
    static immutable ubyte[] encode = cast(immutable(ubyte)[]) import("cp" ~ toChars(n) ~ "-encode.bin");
    static immutable ubyte[256] leads = leadNumbers(decode);
}

/// For each byte, the number + 1 of its table in `decode` if it is a lead byte, else 0.
private ubyte[256] leadNumbers(scope const(ubyte)[] decode) @safe pure nothrow
{
    ubyte[256] leads;
    size_t count;
    foreach (b; 0 .. 256)
        if (decode[2 * b] == 0xFF && decode[2 * b + 1] == 0xFF)
        {
            count++;
            leads[b] = cast(ubyte) count;
        }
    return leads;
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
        if (cp.isUtf8 || cp.isDoubleByte)
            continue; // double-byte pages: tested below
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

@safe unittest
{
    // the double-byte pages: every encodable character goes back and forth, and Windows' decoding rules
    foreach (n; doubleBytePages)
    {
        const cp = CodePage.get(n);
        assert(cp.isDoubleByte && !cp.isUtf8);
        const pairs = cp.dbcsEncode;
        for (size_t i = 0; i < pairs.length; i += 4)
        {
            const c = cast(dchar)(pairs[i] | (pairs[i + 1] << 8));
            const b = pairs[i + 2] | (pairs[i + 3] << 8);
            ubyte[] bytes = b < 0x100 ? [cast(ubyte) b] : [cast(ubyte)(b >> 8), cast(ubyte) b];
            char[] utf8;
            appendUtf8(utf8, c);
            assert(cp.decode(bytes) == utf8, "decode");
            assert(cp.encode(utf8) == bytes, "encode");
        }
    }
    const korean = CodePage.get(949);
    assert(korean.decode([0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE]) == "한국어");
    assert(CodePage.get(936).decode([0xD6, 0xD0, 0xCE, 0xC4]) == "中文");
    assert(CodePage.get(950).decode([0xA4, 0xA4, 0xA4, 0xE5]) == "中文");
    const japanese = CodePage.get(932);
    assert(japanese.decode([0x41, 0x81]) == "A"); // a lead byte at the end is dropped
    assert(japanese.decode([0x81, 0x00, 0x42]) == "\u30FB\0B"); // before 0x00: the default character, then 0x00
    assert(japanese.decode([0x81, 0x20]) == "\u30FB"); // an invalid pair
    assert(korean.decode([0x81, 0x20]) == "?");
    assert(japanese.encode("A😀", '?') == "A?");
}
