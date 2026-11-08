/++
Buffered reader and writer over a `Transport`.

They provide what every wire protocol needs: raw bytes, fixed-size
little-endian and big-endian integers and floats, and strings of a known
length, optionally carved out of a shared `StringArena`. Protocol-specific
encodings (variable-length integers, length-prefixed strings) belong to the
connectors, written as free functions callable with UFCS
(`reader.readVarInt()`); `BufferedReader.ensure`/`window`/`consume` and
`BufferedWriter.reserve`/`commit` let them work on the buffer directly (see the
example below).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.buffer;

import std.traits : isFloatingPoint, isIntegral, isSomeChar;

import dbwire.exception : ConnectionException, ProtocolException;
import dbwire.io.transport : Transport;

/// Default size of the read and write buffers.
enum size_t defaultBufferSize = 64 * 1024;

/// Default limit for a single string or byte array received from the server (1 GiB).
enum size_t defaultMaxStringLength = 1024 * 1024 * 1024;

/++
Storage for decoded strings: values are carved out of shared buffers, so
decoding many values takes one allocation per buffer instead of one per value.
The buffers start at `firstChunkSize` bytes and double up to `chunkSize`, so
little text wastes little memory; values longer than `chunkSize / 4` get their
own allocation.

A slice handed out keeps its whole buffer alive. The arena never writes to a
region again once handed out, which is what makes the slices immutable.
+/
struct StringArena
{
    /// Size of the largest shared buffers.
    enum size_t chunkSize = 64 * 1024;
    /// Size of the first buffer.
    enum size_t firstChunkSize = 4 * 1024;

    private ubyte[] chunk;
    private size_t used;

    // A copy would hand out the same regions again and overwrite strings already
    // returned, which readExactString casts to immutable: pass the arena by ref.
    @disable this(this);

    /// A fresh region of `length` bytes, to be filled by the caller.
    ubyte[] take()(size_t length) @safe pure nothrow
    {
        import std.array : uninitializedArray;

        if (length > chunkSize / 4)
            return uninitializedArray!(ubyte[])(length);
        if (chunk.length - used < length)
        {
            size_t size = chunk.length ? chunk.length * 2 : firstChunkSize;
            if (size > chunkSize)
                size = chunkSize;
            while (size < length)
                size *= 2;
            chunk = uninitializedArray!(ubyte[])(size);
            used = 0;
        }
        auto region = chunk[used .. used + length];
        used += length;
        return region;
    }
}

/// True for the types that `readFixed`/`writeFixed` and their big-endian variants accept.
enum isFixedWireType(T) = isIntegral!T || isFloatingPoint!T || is(T == bool) || isSomeChar!T;

/// Reads from a `Transport` through an internal buffer.
final class BufferedReader
{
    private Transport transport;
    private ubyte[] buffer;
    private size_t pos;
    private size_t end;

    /// Strings and byte arrays longer than this are rejected with a `ProtocolException`.
    size_t maxStringLength = defaultMaxStringLength;

    /++
    Creates a reader.

    Params:
        transport = stream to read from.
        bufferSize = size of the internal buffer.
    +/
    this(Transport transport, size_t bufferSize = defaultBufferSize) @safe
    {
        assert(bufferSize > 0);
        this.transport = transport;
        buffer = new ubyte[bufferSize];
    }

    /// Number of bytes already received and buffered but not consumed yet.
    @property size_t buffered() const @safe pure nothrow @nogc
    {
        return end - pos;
    }

    /// Size of the internal buffer: the most `ensure` can provide.
    @property size_t capacity() const @safe pure nothrow @nogc
    {
        return buffer.length;
    }

    /++
    Fills `dst` completely.

    Throws: `ConnectionException` if the stream ends first or on network errors.
    +/
    void readExact(scope ubyte[] dst) @safe
    {
        while (dst.length)
        {
            if (pos == end)
            {
                // Large reads go straight to the destination, bypassing the buffer.
                if (dst.length >= buffer.length)
                {
                    const n = fillFrom(dst);
                    dst = dst[n .. $];
                    continue;
                }
                end = fillFrom(buffer);
                pos = 0;
            }
            const n = dst.length < end - pos ? dst.length : end - pos;
            dst[0 .. n] = buffer[pos .. pos + n];
            pos += n;
            dst = dst[n .. $];
        }
    }

    /++
    Reads one byte. (A template, so that it is inlined into protocol code in
    other packages.)

    Throws: `ConnectionException` if the stream ends or on network errors.
    +/
    ubyte readByte()() @safe
    {
        if (pos == end)
        {
            end = fillFrom(buffer);
            pos = 0;
        }
        return buffer[pos++];
    }

    /// Reads a fixed-size little-endian value.
    T readFixed(T)() @safe if (isFixedWireType!T)
    {
        if (end - pos >= T.sizeof)
        {
            const ubyte[T.sizeof] bytes = buffer[pos .. pos + T.sizeof];
            pos += T.sizeof;
            return fromLittleEndian!T(bytes);
        }
        ubyte[T.sizeof] bytes;
        readExact(bytes[]);
        return fromLittleEndian!T(bytes);
    }

    /// Reads a fixed-size big-endian (network order) value.
    T readFixedBE(T)() @safe if (isFixedWireType!T)
    {
        if (end - pos >= T.sizeof)
        {
            const ubyte[T.sizeof] bytes = buffer[pos .. pos + T.sizeof];
            pos += T.sizeof;
            return fromBigEndian!T(bytes);
        }
        ubyte[T.sizeof] bytes;
        readExact(bytes[]);
        return fromBigEndian!T(bytes);
    }

    /++
    Reads `length` bytes into a new array.

    Throws: `ProtocolException` if `length` exceeds `maxStringLength`;
    `ConnectionException` if the stream ends first.
    +/
    immutable(ubyte)[] readExactBytes()(size_t length) @safe
    {
        import std.array : uninitializedArray;

        checkLength(length);
        auto data = uninitializedArray!(ubyte[])(length); // filled right away
        readExact(data);
        return (() @trusted => cast(immutable(ubyte)[]) data)(); // data is unique: just allocated
    }

    /++
    Reads `length` bytes as a string. The content is not validated as UTF-8.

    Throws: `ProtocolException` if `length` exceeds `maxStringLength`;
    `ConnectionException` if the stream ends first.
    +/
    string readExactString()(size_t length) @safe
    {
        return cast(string) readExactBytes(length);
    }

    /++
    Reads `length` bytes as a string stored in `arena`: short strings share its
    buffers, so many values need few allocations. The content is not validated
    as UTF-8.

    Throws: `ProtocolException` if `length` exceeds `maxStringLength`;
    `ConnectionException` if the stream ends first.
    +/
    string readExactString()(size_t length, ref StringArena arena) @safe
    {
        checkLength(length);
        auto bytes = arena.take(length);
        readExact(bytes);
        return (() @trusted => cast(string) bytes)(); // the arena never hands out or writes these bytes again
    }

    /++
    Makes at least `n` bytes available in the buffer and returns all buffered
    bytes (at least `n`), without consuming them; call `consume` afterwards.
    `n` must not exceed `capacity`.

    Throws: `ConnectionException` if the stream ends first or on network errors.
    +/
    const(ubyte)[] ensure(size_t n) @safe
    {
        assert(n <= buffer.length, "BufferedReader.ensure: more than the buffer holds");
        if (end - pos < n)
        {
            // Move the unread bytes to the front (forward copy: the regions may overlap)
            const remaining = end - pos;
            foreach (i; 0 .. remaining)
                buffer[i] = buffer[pos + i];
            pos = 0;
            end = remaining;
            while (end < n)
                end += fillFrom(buffer[end .. $]);
        }
        return buffer[pos .. end];
    }

    /// The bytes buffered so far, without reading from the transport (may be empty).
    const(ubyte)[] window()() const @safe pure nothrow @nogc
    {
        return buffer[pos .. end];
    }

    /// Consumes `n` buffered bytes (at most `buffered`).
    void consume()(size_t n) @safe pure nothrow @nogc
    {
        assert(n <= end - pos, "BufferedReader.consume: more than is buffered");
        pos += n;
    }

    private void checkLength()(size_t length) const @safe
    {
        if (length > maxStringLength)
            throw new ProtocolException("String length exceeds the limit");
    }

    private size_t fillFrom(scope ubyte[] dst) @safe
    {
        const n = transport.read(dst);
        if (n == 0)
            throw new ConnectionException("Connection closed by the server");
        return n;
    }
}

/// Writes to a `Transport` through an internal buffer.
/// Nothing reaches the network until `flush` is called or the buffer fills up.
final class BufferedWriter
{
    private Transport transport;
    private ubyte[] buffer;
    private size_t used;

    /++
    Creates a writer.

    Params:
        transport = stream to write to.
        bufferSize = size of the internal buffer.
    +/
    this(Transport transport, size_t bufferSize = defaultBufferSize) @safe
    {
        assert(bufferSize > 0);
        this.transport = transport;
        buffer = new ubyte[bufferSize];
    }

    /// Number of bytes written but not flushed yet.
    @property size_t buffered() const @safe pure nothrow @nogc
    {
        return used;
    }

    /// Size of the internal buffer: the most `reserve` can provide.
    @property size_t capacity() const @safe pure nothrow @nogc
    {
        return buffer.length;
    }

    /// Appends raw bytes.
    void writeBytes()(scope const(ubyte)[] data) @safe
    {
        if (data.length > buffer.length - used)
        {
            flush();
            if (data.length >= buffer.length)
            {
                transport.write(data);
                return;
            }
        }
        buffer[used .. used + data.length] = data[];
        used += data.length;
    }

    /// Appends one byte. (A template, so that it is inlined into protocol code in other packages.)
    void writeByte()(ubyte b) @safe
    {
        if (used == buffer.length)
            flush();
        buffer[used++] = b;
    }

    /// Appends a fixed-size little-endian value.
    void writeFixed(T)(T value) @safe if (isFixedWireType!T)
    {
        auto bytes = toLittleEndian(value);
        writeBytes(bytes[]);
    }

    /// Appends a fixed-size big-endian (network order) value.
    void writeFixedBE(T)(T value) @safe if (isFixedWireType!T)
    {
        auto bytes = toBigEndian(value);
        writeBytes(bytes[]);
    }

    /++
    Returns free buffer space of at least `n` bytes (flushing first if needed)
    for the caller to fill; then `commit` the bytes actually written. `n` must
    not exceed `capacity`.
    +/
    ubyte[] reserve()(size_t n) @safe
    {
        assert(n <= buffer.length, "BufferedWriter.reserve: more than the buffer holds");
        if (buffer.length - used < n)
            flush();
        return buffer[used .. $];
    }

    /// Adds `n` bytes written into the space returned by `reserve`.
    void commit()(size_t n) @safe pure nothrow @nogc
    {
        assert(n <= buffer.length - used, "BufferedWriter.commit: more than was reserved");
        used += n;
    }

    /// Sends all buffered bytes to the transport.
    void flush() @safe
    {
        if (used)
        {
            transport.write(buffer[0 .. used]);
            used = 0;
        }
    }
}

/// Decodes a little-endian value of type `T`.
T fromLittleEndian(T)(const ubyte[T.sizeof] bytes) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : littleEndianToNative;

    static if (is(T == bool))
        return bytes[0] != 0;
    else
        return littleEndianToNative!T(bytes);
}

/// Encodes `value` as little-endian bytes.
ubyte[T.sizeof] toLittleEndian(T)(T value) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : nativeToLittleEndian;

    static if (is(T == bool))
        return [value ? 1 : 0];
    else
        return nativeToLittleEndian(value);
}

/// Decodes a big-endian (network order) value of type `T`.
T fromBigEndian(T)(const ubyte[T.sizeof] bytes) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : bigEndianToNative;

    static if (is(T == bool))
        return bytes[0] != 0;
    else
        return bigEndianToNative!T(bytes);
}

/// Encodes `value` as big-endian (network order) bytes.
ubyte[T.sizeof] toBigEndian(T)(T value) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : nativeToBigEndian;

    static if (is(T == bool))
        return [value ? 1 : 0];
    else
        return nativeToBigEndian(value);
}

///
@safe unittest
{
    import dbwire.io.mock : MockTransport;

    auto transport = new MockTransport;
    auto writer = new BufferedWriter(transport);
    writer.writeFixed!int(-2);
    writer.writeFixedBE!ushort(0x0102);
    writer.writeBytes(cast(const(ubyte)[]) "hello");
    writer.flush();
    assert(transport.written == [0xFE, 0xFF, 0xFF, 0xFF, 0x01, 0x02, 'h', 'e', 'l', 'l', 'o']);

    transport.feed(transport.written); // read back what was written
    auto reader = new BufferedReader(transport);
    assert(reader.readFixed!int() == -2);
    assert(reader.readFixedBE!ushort() == 0x0102);
    assert(reader.readExactString(5) == "hello");
}

/// A protocol encoding written on top of the buffers: unsigned LEB128 integers,
/// decoded from the buffer directly when enough bytes are there.
@safe unittest
{
    import dbwire.io.mock : MockTransport;

    static ulong readLeb128(BufferedReader reader)
    {
        const bytes = reader.window();
        if (bytes.length >= 10) // fast path: decode in place
        {
            ulong value;
            foreach (i, b; bytes[0 .. 10])
            {
                value |= cast(ulong)(b & 0x7F) << (7 * i);
                if ((b & 0x80) == 0)
                {
                    reader.consume(i + 1);
                    return value;
                }
            }
            throw new ProtocolException("LEB128 integer longer than 10 bytes");
        }
        ulong value;
        foreach (i; 0 .. 10) // near the end of the buffer: byte by byte
        {
            const b = reader.readByte();
            value |= cast(ulong)(b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0)
                return value;
        }
        throw new ProtocolException("LEB128 integer longer than 10 bytes");
    }

    static void writeLeb128(BufferedWriter writer, ulong value)
    {
        auto space = writer.reserve(10);
        size_t n;
        do
        {
            space[n++] = (value & 0x7F) | (value >= 0x80 ? 0x80 : 0);
            value >>= 7;
        }
        while (value);
        writer.commit(n);
    }

    auto transport = new MockTransport;
    auto writer = new BufferedWriter(transport);
    foreach (v; [0UL, 127, 128, 300, ulong.max])
        writeLeb128(writer, v); // at module level, UFCS works too: writer.writeLeb128(v)
    writer.flush();
    assert(transport.written[0 .. 6] == [0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02]);

    transport.feed(transport.written);
    auto reader = new BufferedReader(transport);
    foreach (v; [0UL, 127, 128, 300, ulong.max])
        assert(readLeb128(reader) == v);
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // Oversized and truncated input is rejected
    auto transport = new MockTransport;
    transport.feed(['a', 'b']);
    auto reader = new BufferedReader(transport);
    reader.maxStringLength = 4;
    assertThrown!ProtocolException(reader.readExactString(5));
    assertThrown!ProtocolException(reader.readExactBytes(5));
    assertThrown!ConnectionException(reader.readExactString(3));

    transport = new MockTransport;
    transport.feed([1, 2]);
    assertThrown!ConnectionException(new BufferedReader(transport).readFixed!uint());
    assertThrown!ConnectionException(new BufferedReader(new MockTransport).readByte());
}

@safe unittest
{
    import dbwire.io.mock : MockTransport;

    // Data split into 1-byte chunks and reads larger than the buffer
    auto payload = new ubyte[1000];
    foreach (i, ref b; payload)
        b = cast(ubyte) i;
    auto transport = new MockTransport;
    transport.maxChunk = 1;
    transport.feed(payload);
    auto reader = new BufferedReader(transport, 16);
    auto head = new ubyte[10];
    reader.readExact(head);
    assert(head == payload[0 .. 10]);
    auto rest = new ubyte[990];
    reader.readExact(rest);
    assert(rest == payload[10 .. $]);

    // Writes larger than the buffer
    transport = new MockTransport;
    auto writer = new BufferedWriter(transport, 16);
    writer.writeByte(1);
    writer.writeBytes(payload);
    writer.flush();
    assert(transport.written.length == 1001 && transport.written[1 .. $] == payload);
}

@safe unittest
{
    import dbwire.io.mock : MockTransport;

    // ensure, window, consume: bytes arrive in small pieces; the window is compacted
    auto payload = new ubyte[100];
    foreach (i, ref b; payload)
        b = cast(ubyte) i;
    auto transport = new MockTransport;
    transport.maxChunk = 3;
    transport.feed(payload);
    auto reader = new BufferedReader(transport, 16);
    assert(reader.window().length == 0 && reader.capacity == 16);
    size_t offset;
    while (offset < 96)
    {
        const want = 4 + offset % 13 < 100 - offset ? 4 + offset % 13 : 100 - offset; // at most 16
        const bytes = reader.ensure(want);
        assert(bytes.length >= want);
        assert(bytes[0 .. 4] == payload[offset .. offset + 4]);
        reader.consume(4);
        offset += 4;
    }
    assert(reader.readFixed!ubyte() == 96 && reader.buffered + transport.remaining == 3);

    // readFixed across the end of the buffered bytes
    transport = new MockTransport;
    transport.maxChunk = 1;
    transport.feed([0x78, 0x56, 0x34, 0x12, 0x12, 0x34, 0x56, 0x78]);
    reader = new BufferedReader(transport, 4);
    assert(reader.readFixed!uint() == 0x1234_5678 && reader.readFixedBE!uint() == 0x1234_5678);

    // reserve flushes when the space is short; commit adds the bytes
    transport = new MockTransport;
    auto writer = new BufferedWriter(transport, 8);
    writer.writeBytes([1, 2, 3, 4, 5, 6]);
    auto space = writer.reserve(4);
    assert(transport.written == [1, 2, 3, 4, 5, 6] && space.length == 8);
    space[0 .. 2] = [7, 8];
    writer.commit(2);
    assert(writer.buffered == 2);
    writer.flush();
    assert(transport.written == [1, 2, 3, 4, 5, 6, 7, 8]);
}

@safe unittest
{
    // Byte order helpers
    assert(toLittleEndian!uint(0x01020304) == [4, 3, 2, 1]);
    assert(toBigEndian!uint(0x01020304) == [1, 2, 3, 4]);
    assert(fromLittleEndian!short([0xFE, 0xFF]) == -2 && fromBigEndian!short([0xFF, 0xFE]) == -2);
    assert(fromLittleEndian!double(toLittleEndian(1.5)) == 1.5);
    assert(fromBigEndian!double(toBigEndian(-1.5)) == -1.5);
    assert(toLittleEndian(true) == [1] && toBigEndian(false) == [0]);
}

@safe unittest
{
    import std.exception : assertThrown;
    import dbwire.io.mock : MockTransport;

    // Strings read into an arena: short ones share a buffer, long ones get their own, limits still apply
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    string[] values = ["", "a", "hello", "x"];
    char[] big;
    big.length = StringArena.chunkSize / 4 + 1;
    big[] = 'b';
    values ~= big.idup;
    foreach (i; 0 .. 2000)
        values ~= "value" ~ cast(char)('0' + i % 10); // more than one buffer
    foreach (v; values)
    {
        w.writeFixed!uint(cast(uint) v.length);
        w.writeBytes(cast(const(ubyte)[]) v);
    }
    w.flush();
    t.feed(t.written);
    auto r = new BufferedReader(t);
    StringArena arena;
    string[] got;
    foreach (_; values)
        got ~= r.readExactString(r.readFixed!uint(), arena);
    assert(got == values);
    assert((() @trusted => got[1].ptr + 1 == got[2].ptr)()); // consecutive short values share a buffer
    static assert(!__traits(compiles, { StringArena a; auto b = a; })); // a copy would reuse regions

    auto limited = new MockTransport;
    limited.feed(cast(const(ubyte)[]) "too long");
    auto lr = new BufferedReader(limited);
    lr.maxStringLength = 4;
    assertThrown!ProtocolException(lr.readExactString(8, arena));
}
