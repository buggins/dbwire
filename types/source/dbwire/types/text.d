/++
`TextBuffer`: short text built on the stack (dates, numbers, identifiers),
then copied once.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.text;

/++
Text of up to `capacity` characters, written in place: `put` the pieces,
then take the result with `text` (one allocation) or as
`buffer[0 .. length]` (valid while the buffer lives). Writing past the
capacity is a range error, so size it for the longest text.
+/
struct TextBuffer(size_t capacity)
{
    /// The characters; the text is `buffer[0 .. length]`.
    char[capacity] buffer = void;
    /// The number of characters written.
    size_t length;

    /// Appends a character.
    void put(char c) @safe pure nothrow @nogc
    {
        buffer[length++] = c;
    }

    /// Appends text.
    void put(scope const(char)[] s) @safe pure nothrow @nogc
    {
        // a loop: a slice assignment calls the runtime's overlap-checking copy, slow for short pieces
        auto to = buffer[length .. length + s.length];
        foreach (i, c; s)
            to[i] = c;
        length += s.length;
    }

    /// Appends `count` times `c`.
    void fill(char c, size_t count) @safe pure nothrow @nogc
    {
        buffer[length .. length + count] = c;
        length += count;
    }

    /// Appends `value` in decimal, padded with zeros to at least `width` digits.
    void number(ulong value, size_t width = 0) @safe pure nothrow @nogc
    {
        size_t n = 1;
        for (ulong rest = value / 10; rest; rest /= 10)
            n++;
        if (n < width)
            n = width;
        auto digits = buffer[length .. length + n]; // written from the end, zeros in front
        foreach_reverse (ref c; digits)
        {
            c = cast(char)('0' + value % 10);
            value /= 10;
        }
        length += n;
    }

    /// A copy of the text.
    @property string text() const @safe pure nothrow
    {
        return buffer[0 .. length].idup;
    }
}

///
@safe pure nothrow unittest
{
    TextBuffer!32 t;
    t.number(2024, 4);
    t.put('-');
    t.number(1, 2);
    t.put("-");
    t.number(31, 2);
    t.put(' ');
    t.fill('*', 3);
    assert(t.text == "2024-01-31 ***" && t.buffer[0 .. 4] == "2024" && t.length == 14);
}

@safe pure nothrow @nogc unittest
{
    TextBuffer!48 t;
    t.number(0);
    t.number(7, 3);
    t.number(ulong.max);
    t.number(12_345, 2); // wider than the padding
    assert(t.buffer[0 .. t.length] == "0007" ~ "18446744073709551615" ~ "12345");
}
