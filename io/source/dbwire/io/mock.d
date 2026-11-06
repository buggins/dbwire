/++
In-memory `Transport` for tests: replays bytes fed to it and records
everything written.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.mock;

import core.time : Duration;

import dbwire.exception : ConnectionException;
import dbwire.io.transport : Transport, WaitableTransport;

/// A `Transport` backed by memory buffers.
final class MockTransport : Transport, WaitableTransport
{
    private ubyte[] input;
    private bool closed;

    /// All bytes written so far.
    ubyte[] written;

    /// Maximum number of bytes returned by one `read`, to simulate partial reads.
    size_t maxChunk = size_t.max;

    /++
    Appends bytes that subsequent `read` calls will return.

    Once all fed bytes are consumed, `read` returns 0 (end of stream).
    +/
    void feed(scope const(ubyte)[] data) @safe
    {
        input ~= data;
    }

    /// Number of fed bytes not read yet.
    @property size_t remaining() const @safe pure nothrow
    {
        return input.length;
    }

    /// Discards everything recorded in `written`.
    void clearWritten() @safe pure nothrow
    {
        written = null;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        if (closed)
            throw new ConnectionException("Read from a closed transport");
        size_t n = input.length;
        if (n > buffer.length)
            n = buffer.length;
        if (n > maxChunk)
            n = maxChunk;
        buffer[0 .. n] = input[0 .. n];
        input = input[n .. $];
        return n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        if (closed)
            throw new ConnectionException("Write to a closed transport");
        written ~= data;
    }

    /// True while fed bytes remain.
    override bool dataAvailable() @safe
    {
        return input.length > 0;
    }

    /// The mock can't receive data while waiting: true if data is queued, else false at once.
    @property bool canWaitForData() @safe
    {
        return true;
    }

    /// ditto
    bool waitForData(Duration timeout) @safe
    {
        cast(void) timeout; // nothing can arrive while waiting
        return input.length > 0;
    }

    override void close() @safe nothrow
    {
        closed = true;
    }

    override bool connected() const @safe nothrow
    {
        return !closed;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }
}

///
@safe unittest
{
    auto t = new MockTransport;
    t.feed([1, 2, 3]);
    t.maxChunk = 2;
    ubyte[8] buf;
    assert(t.read(buf[]) == 2 && buf[0 .. 2] == [1, 2]);
    assert(t.read(buf[]) == 1 && buf[0] == 3);
    assert(t.read(buf[]) == 0); // end of stream

    t.write([9, 8]);
    assert(t.written == [9, 8]);
}
