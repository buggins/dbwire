/++
I/O backend selection: thread mode (Phobos sockets) or fiber mode (vibe-core).

An `IoBackend` provides everything that may block. Fiber mode is available
when vibe-core is in the application's dependency graph; dub then defines
`version (Have_vibe_core)`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io.backend;

import core.time : days, Duration;

import dbwire.exception : ClientException;
import dbwire.io.transport : Transport, WaitableTransport;

/++
The longest wait the backends and the pool use (50 years). Longer timeouts,
`Duration.max` included, are cut to it, so that deadlines (`MonoTime` plus a
timeout) and `select`'s 32-bit seconds on Windows can't overflow.
+/
package(dbwire) enum Duration longestWait = days(50 * 365);

/// `timeout`, cut to `longestWait`.
package(dbwire) Duration clampWait(Duration timeout) @safe pure nothrow @nogc
{
    return timeout > longestWait ? longestWait : timeout;
}

/// Which I/O backend a connection uses.
enum IoMode
{
    /// Fiber mode when called inside a vibe.d task (and vibe-core is compiled
    /// in), otherwise thread mode.
    auto_,
    /// Blocking Phobos sockets, for ordinary threads. Inside a vibe.d task this
    /// blocks the whole event loop.
    phobos,
    /// vibe-core sockets, for vibe.d tasks. Requires vibe-core.
    vibe,
}

/// Everything that may block, implemented for one concurrency model.
interface IoBackend
{
    /// Short backend name: `"phobos"` or `"vibe"`.
    @property string name() const @safe pure nothrow;

    /++
    Opens a connection to `host`:`port`, giving up after `timeout`
    (`Duration.zero` or `Duration.max`: without limit).

    Throws: `dbwire.exception.ConnectionException` on failure or timeout.
    +/
    Transport connect(string host, ushort port, Duration timeout) @safe;

    /// Lets other fibers run (fiber mode); does nothing in thread mode.
    void yieldNow() @safe;

    /// Creates a lock with a wait/notify condition, for the connection pool.
    PoolSync newPoolSync() @safe;

    /++
    Creates a mutual-exclusion lock that may be held across blocking I/O: a
    thread mutex in thread mode, a task mutex in fiber mode. Not recursive.
    +/
    IoLock newLock() @safe;
}

/// A non-recursive lock, created by `IoBackend.newLock`.
interface IoLock
{
    /// Acquires the lock, blocking (or suspending the task) while another holder has it.
    void lock() @safe;
    /// Releases the lock.
    void unlock() @safe;
}

/++
A lock plus a condition to wait on, as the connection pool needs it.
`wait` must be called with the lock held; it releases the lock while waiting.
+/
interface PoolSync
{
    /// Acquires the lock.
    void lock() @safe;
    /// Releases the lock.
    void unlock() @safe;
    /++
    Releases the lock, waits until `notifyAll` is called or `timeout`
    passes, then reacquires the lock.

    Returns: false on timeout.
    +/
    bool wait(Duration timeout) @safe;
    /// Wakes all waiters.
    void notifyAll() @safe;
}

/// Whether fiber mode (vibe-core) is compiled in.
version (Have_vibe_core)
    private enum bool vibeCompiledIn = true;
else
    private enum bool vibeCompiledIn = false;

/++
Whether the caller runs inside a vibe.d task. Always false when vibe-core is
not compiled in.
+/
bool inVibeTask() @safe nothrow
{
    version (Have_vibe_core)
    {
        import dbwire.io.vibecore : vibeInTask = inVibeTask;

        return vibeInTask();
    }
    else
        return false;
}

/++
Returns the backend for `mode`.

Throws: `ClientException` if `mode` is `IoMode.vibe` and vibe-core is not compiled in.
+/
IoBackend backendFor(IoMode mode) @safe
{
    import dbwire.io.phobos : PhobosBackend;

    final switch (mode)
    {
    case IoMode.auto_:
        version (Have_vibe_core)
        {
            if (inVibeTask())
                return vibeBackend();
        }
        return new PhobosBackend;
    case IoMode.phobos:
        debug warnIfBlockingEventLoop();
        return new PhobosBackend;
    case IoMode.vibe:
        version (Have_vibe_core)
            return vibeBackend();
        else
            throw new ClientException("IoMode.vibe needs vibe-core: add it to your project's dependencies");
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;

    assert(backendFor(IoMode.phobos).name == "phobos");
    // Outside a vibe.d task, automatic selection uses thread mode
    assert(backendFor(IoMode.auto_).name == "phobos");
    static if (!vibeCompiledIn)
        assertThrown!ClientException(backendFor(IoMode.vibe));
}

version (Have_vibe_core)
{
    private IoBackend vibeBackend() @safe
    {
        import dbwire.io.vibecore : VibeBackend;

        return new VibeBackend;
    }
}

/// Logs a warning (once per thread) when blocking sockets are requested inside a vibe.d task.
private void warnIfBlockingEventLoop() @safe nothrow
{
    static bool warned;
    if (warned || !inVibeTask())
        return;
    warned = true;
    try
    {
        static if (__traits(compiles, () { import std.logger; }))
            import std.logger : warning;
        else
            import std.experimental.logger : warning; // frontend < 2.101

        warning("dbwire: IoMode.phobos is used inside a vibe.d task; blocking sockets stall the event loop. "
                ~ "Use IoMode.auto_ or IoMode.vibe.");
    }
    catch (Exception)
    {
        // logging is best effort
    }
}

/++
Waits up to `timeout` (`Duration.max`: without limit) until data from the
server can be read from `transport` without blocking. Transports that
implement `WaitableTransport` wait for it; for the others the data is checked
every few milliseconds (at most 50), pausing in `backend`'s I/O mode (other
tasks run meanwhile in fiber mode).

Returns: true when data can be read, false on timeout.
Throws: `dbwire.exception.ConnectionException` on network errors.
+/
bool waitForData(Transport transport, Duration timeout, IoBackend backend) @safe
{
    import core.time : MonoTime, msecs;

    if (auto waitable = cast(WaitableTransport) transport)
        if (waitable.canWaitForData)
            return waitable.waitForData(timeout);
    if (transport.dataAvailable())
        return true;
    const forever = timeout == Duration.max;
    const deadline = forever ? MonoTime.max : MonoTime.currTime + clampWait(timeout);
    auto pause = 1.msecs;
    PoolSync sync;
    for (;;)
    {
        const now = MonoTime.currTime;
        if (now >= deadline)
            return false;
        const remaining = deadline - now;
        if (sync is null)
            sync = backend.newPoolSync();
        sync.lock();
        sync.wait(forever || pause < remaining ? pause : remaining);
        sync.unlock();
        if (transport.dataAvailable())
            return true;
        if (pause < 50.msecs)
            pause *= 2;
    }
}

@safe unittest
{
    import core.time : msecs, MonoTime;
    import dbwire.io.mock : MockTransport;
    import dbwire.io.phobos : PhobosBackend;

    // the mock transport waits for nothing: queued data or not
    auto mock = new MockTransport;
    assert(!waitForData(mock, 20.msecs, new PhobosBackend));
    mock.feed([1]);
    assert(waitForData(mock, 20.msecs, new PhobosBackend));
}

@safe unittest
{
    import core.time : msecs, MonoTime;
    import dbwire.io.phobos : PhobosBackend;

    // a transport that can't wait: polled until the timeout
    static final class Polled : Transport
    {
        int checks;
        int dataAfter = int.max;

        override size_t read(scope ubyte[] buffer) @safe
        {
            return 0;
        }

        override void write(scope const(ubyte)[] data) @safe
        {
        }

        override bool dataAvailable() @safe
        {
            return ++checks >= dataAfter;
        }

        override void close() @safe nothrow
        {
        }

        override bool connected() const @safe nothrow
        {
            return true;
        }

        override void setTimeouts(Duration receive, Duration send) @safe
        {
        }
    }

    auto polled = new Polled;
    const start = MonoTime.currTime;
    assert(!waitForData(polled, 60.msecs, new PhobosBackend));
    assert(MonoTime.currTime - start >= 60.msecs && polled.checks > 2);
    polled.checks = 0;
    polled.dataAfter = 3;
    assert(waitForData(polled, Duration.max, new PhobosBackend) && polled.checks == 3);
}
