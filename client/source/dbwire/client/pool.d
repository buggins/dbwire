/++
The connector-neutral core of a connection pool, for thread mode and fiber mode.

Connectors wrap `PoolCore` in a typed pool: their connection class implements
`Poolable`, a factory opens new connections, and `PoolLease` (returned by
`PoolCore.acquire`) gives the connection back when it goes out of scope.

In thread mode all threads share one set of connections. In fiber mode each
thread has its own set, because a vibe.d connection cannot move between event
loops; the limits apply per thread. Which mode a call uses follows the pool's
`IoMode`, as for single connections.

Idle connections are checked lazily, when connections are taken or returned,
so the pool needs no background thread or timer, and it never does I/O while
holding its lock.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.client.pool;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, hours, minutes, seconds;

import dbwire.exception : ClientException, DbException;
import dbwire.io.backend : clampWait, IoMode, PoolSync, backendFor, inVibeTask;

/// What the pool needs from a connection.
interface Poolable
{
    /// Whether the connection is open.
    @property bool isOpen() const @safe nothrow;

    /// Whether the connection is in the middle of an operation (e.g. a result
    /// not read to the end): such a connection is closed, not reused.
    @property bool isBusy() const @safe nothrow;

    /// Checks that the server still answers; throws a `DbException` if it doesn't.
    /// Other exceptions (e.g. an interrupted vibe.d task) reach `PoolCore.acquire`'s caller.
    void ping() @safe;

    /// Closes the connection.
    void close() @safe nothrow;
}

/// Opens a new connection for the pool, or throws.
alias PoolableFactory = Poolable delegate() @safe;

/// Pool limits and connection reuse rules.
struct PoolOptions
{
    /// Maximum number of open connections (per thread in fiber mode).
    size_t maxConnections = 16;
    /// How long `PoolCore.acquire` waits for a free connection before failing
    /// (`Duration.zero`: not at all; `Duration.max`: without limit).
    Duration waitTimeout = 30.seconds;
    /// Idle connections older than this are closed.
    Duration maxIdleTime = 5.minutes;
    /// Connections older than this are closed when returned; `Duration.zero` means no limit.
    Duration maxLifetime = 1.hours;
    /// A connection idle for longer than this is pinged before being handed out.
    Duration pingAfterIdle = 30.seconds;

    /++
    Reads pool options from `pool_*` parameters: `pool_max`, and
    `pool_wait_timeout`, `pool_max_idle_time`, `pool_max_lifetime`,
    `pool_ping_after_idle` in seconds (may be fractional). Other keys are ignored.

    Throws: `ClientException` if a value is invalid.
    +/
    static PoolOptions fromParams(const string[string] params) @safe
    {
        import std.conv : ConvException, to;
        import dbwire.client.dsn : parseSeconds;

        PoolOptions options;
        foreach (key, value; params)
        {
            switch (key)
            {
            case "pool_max":
                try
                    options.maxConnections = value.to!size_t;
                catch (ConvException)
                    throw new ClientException("Invalid value '" ~ value ~ "' for 'pool_max'");
                if (options.maxConnections == 0)
                    throw new ClientException("'pool_max' must be at least 1");
                break;
            case "pool_wait_timeout":
                options.waitTimeout = parseSeconds(key, value);
                break;
            case "pool_max_idle_time":
                options.maxIdleTime = parseSeconds(key, value);
                break;
            case "pool_max_lifetime":
                options.maxLifetime = parseSeconds(key, value);
                break;
            case "pool_ping_after_idle":
                options.pingAfterIdle = parseSeconds(key, value);
                break;
            default:
                break;
            }
        }
        return options;
    }

    /++
    Reads pool options from the `pool_*` parameters of a connection string
    (the part after `?`), as `fromParams` does.

    Throws: `ClientException` if a value is invalid.
    +/
    static PoolOptions fromDsn(string dsn) @safe
    {
        import std.algorithm.searching : findSplit;
        import dbwire.client.dsn : parseQuery, redactPassword;

        return fromParams(parseQuery(dsn.findSplit("?")[2], redactPassword(dsn)));
    }

    ///
    @safe unittest
    {
        import core.time : msecs;

        const o = PoolOptions.fromDsn("db://h/x?pool_max=4&pool_wait_timeout=2.5&max_threads=1");
        assert(o.maxConnections == 4 && o.waitTimeout == 2500.msecs);
    }
}

/++
A pool of connections opened by one factory (one server, or one set of
failover hosts).

`acquire` hands out a `PoolLease`, which returns the connection when it goes
out of scope. Connections that are closed, busy, or older than
`PoolOptions.maxLifetime` when returned are closed instead of reused.

In fiber mode each thread has its own connections, kept as long as the pool:
use the pool from threads that live as long as it, as vibe.d's worker threads do.
+/
final class PoolCore
{
    private PoolOptions poolOptions;
    private IoMode ioMode;
    private PoolableFactory factory;
    private SubPool threadPool;
    private SubPool[Thread] fiberPools;
    private PoolSync fiberPoolsLock;
    private shared bool closed; // set by close() from any thread

    /++
    Creates an empty pool; connections are opened on demand.

    Params:
        options = pool limits.
        ioMode = selects thread mode or fiber mode, as for connections.
        factory = opens a new connection.

    Throws: `ClientException` if `options.maxConnections` is 0.
    +/
    this(PoolOptions options, IoMode ioMode, PoolableFactory factory) @safe
    {
        import dbwire.io.phobos : ThreadPoolSync;

        if (options.maxConnections == 0)
            throw new ClientException("PoolOptions.maxConnections must be at least 1");
        poolOptions = options;
        this.ioMode = ioMode;
        this.factory = factory;
        threadPool = new SubPool(this, new ThreadPoolSync);
        fiberPoolsLock = new ThreadPoolSync;
    }

    /// The pool limits.
    @property const(PoolOptions) options() const @safe pure nothrow
    {
        return poolOptions;
    }

    /++
    Takes a connection from the pool, opening a new one if none is idle and
    the limit allows it; otherwise waits up to `PoolOptions.waitTimeout`.
    Connections idle for longer than `PoolOptions.pingAfterIdle` are pinged
    first; one that fails is closed and replaced.

    Throws: `ClientException` if the pool is closed or no connection became
    free in time; the factory's exception when a new connection can't be opened.
    +/
    PoolLease acquire() @safe
    {
        auto pool = currentSubPool();
        return PoolLease(pool, pool.acquire());
    }

    /// Number of idle connections available to the caller (its thread's set in fiber mode).
    @property size_t idleConnections() @safe
    {
        auto pool = currentSubPool();
        pool.sync.lock();
        scope (exit)
            pool.sync.unlock();
        return pool.idleCount;
    }

    /// Number of connections handed out to the caller's context and not yet returned.
    @property size_t activeConnections() @safe
    {
        auto pool = currentSubPool();
        pool.sync.lock();
        scope (exit)
            pool.sync.unlock();
        return pool.active;
    }

    /++
    Closes all idle connections and stops handing out new ones. Connections in
    use are closed when they are returned. In fiber mode, the idle connections
    of other threads are closed by those threads when they next use the pool.
    +/
    void close() @safe
    {
        atomicStore(closed, true);
        threadPool.closeIdle();
        fiberPoolsLock.lock();
        SubPool own;
        if (auto p = currentThread() in fiberPools)
            own = *p;
        fiberPoolsLock.unlock();
        if (own !is null)
            own.closeIdle();
    }

    private SubPool currentSubPool() @safe
    {
        // the choice backendFor makes, without creating a backend on every call
        if (ioMode == IoMode.phobos || (ioMode == IoMode.auto_ && !inVibeTask()))
            return threadPool;
        auto self = currentThread();
        fiberPoolsLock.lock();
        scope (exit)
            fiberPoolsLock.unlock();
        if (auto p = self in fiberPools)
            return *p;
        auto pool = new SubPool(this, backendFor(ioMode).newPoolSync()); // throws without vibe-core
        fiberPools[self] = pool;
        return pool;
    }
}

///
@safe unittest
{
    static final class Conn : Poolable
    {
        bool open = true;
        @property bool isOpen() const nothrow
        {
            return open;
        }

        @property bool isBusy() const nothrow
        {
            return false;
        }

        void ping()
        {
        }

        void close() nothrow
        {
            open = false;
        }
    }

    auto pool = new PoolCore(PoolOptions.init, IoMode.phobos, () => cast(Poolable) new Conn);
    Poolable first;
    {
        auto lease = pool.acquire(); // opens a connection
        first = lease.connection();
        assert(pool.activeConnections == 1);
    } // returned here
    assert(pool.idleConnections == 1 && pool.acquire().connection is first); // and reused
}

/++
A connection taken from a `PoolCore`. It returns the connection to the pool
when it goes out of scope (or on `release`), and cannot be copied.

Keep a lease on the stack, or in a struct that is. A lease the garbage
collector finalizes (held by a collected object) does nothing: the pool may
already be finalized, and a finalizer must not lock or allocate. Its
connection is then never returned: the slot stays taken and the connection
stays open until the process ends. Call `release` before dropping an object
that holds a lease.
+/
struct PoolLease
{
    private SubPool pool;
    private Poolable item;

    @disable this(this);

    private this(SubPool pool, Poolable item) @safe
    {
        this.pool = pool;
        this.item = item;
    }

    ~this() @safe
    {
        import core.memory : GC;

        // the GC finalizes in any order (at exit everything), so the pool may be gone: leave it alone
        if (GC.inFinalizer)
            return;
        release();
    }

    /// The connection. Null after `release`.
    @property Poolable connection() @safe pure nothrow
    {
        return item;
    }

    /// Returns the connection to the pool now. Calling it again does nothing.
    void release() @safe
    {
        if (pool !is null && item !is null)
            pool.release(item);
        pool = null;
        item = null;
    }
}

/// The connections of one context: all threads (thread mode) or one thread (fiber mode).
private final class SubPool
{
    struct Idle
    {
        Poolable conn;
        MonoTime since;
    }

    PoolCore owner;
    PoolSync sync;
    Idle[] idle; // idle[0 .. idleCount]: most recently returned last; the rest is room to grow
    size_t idleCount;
    size_t active;
    MonoTime[Poolable] openedAt;

    this(PoolCore owner, PoolSync sync) @safe
    {
        this.owner = owner;
        this.sync = sync;
    }

    Poolable acquire() @safe
    {
        const options = owner.poolOptions;
        const deadline = MonoTime.currTime + clampWait(options.waitTimeout);
        for (;;)
        {
            Poolable[] expired;
            Poolable candidate;
            Duration idleFor;
            bool create;

            sync.lock();
            {
                scope (exit)
                    sync.unlock();
                for (;;)
                {
                    if (atomicLoad(owner.closed))
                        throw new ClientException("The connection pool is closed");
                    takeExpired(expired);
                    if (idleCount)
                    {
                        candidate = idle[idleCount - 1].conn;
                        idleFor = MonoTime.currTime - idle[idleCount - 1].since;
                        idle[--idleCount] = Idle.init; // no reference to it left behind
                        active++;
                        break;
                    }
                    if (active < options.maxConnections)
                    {
                        active++;
                        create = true;
                        break;
                    }
                    const remaining = deadline - MonoTime.currTime;
                    if (remaining <= Duration.zero || !sync.wait(remaining))
                        throw new ClientException("Timed out waiting for a free connection in the pool");
                }
            }
            foreach (c; expired)
                c.close();

            if (create)
            {
                try
                {
                    auto conn = owner.factory();
                    sync.lock();
                    openedAt[conn] = MonoTime.currTime;
                    sync.unlock();
                    return conn;
                }
                catch (Exception e)
                {
                    forget(null);
                    throw e;
                }
            }

            if (idleFor < options.pingAfterIdle)
                return candidate;
            try
            {
                candidate.ping();
                return candidate;
            }
            catch (DbException)
            {
                candidate.close(); // dead: try another one
                forget(candidate);
            }
            catch (Exception e)
            {
                // not a database error, e.g. the task was interrupted: the connection is in an
                // unknown state, and the caller must see the exception
                candidate.close();
                forget(candidate);
                throw e;
            }
        }
    }

    void release(Poolable conn) @safe
    {
        const lifetime = owner.poolOptions.maxLifetime;
        sync.lock();
        const opened = openedAt.get(conn, MonoTime.currTime);
        const tooOld = lifetime != Duration.zero && MonoTime.currTime - opened > lifetime;
        const reuse = !atomicLoad(owner.closed) && conn.isOpen && !conn.isBusy && !tooOld;
        if (reuse)
        {
            if (idleCount == idle.length)
                idle.length = idle.length ? idle.length * 2 : 4;
            idle[idleCount++] = Idle(conn, MonoTime.currTime);
        }
        else
            openedAt.remove(conn);
        active--;
        sync.notifyAll();
        sync.unlock();
        if (!reuse)
            conn.close(); // e.g. a busy connection has an unread result: it cannot be reused
    }

    /// Closes all idle connections.
    void closeIdle() @safe
    {
        sync.lock();
        auto toClose = idle[0 .. idleCount];
        idle = null;
        idleCount = 0;
        foreach (entry; toClose)
            openedAt.remove(entry.conn);
        sync.notifyAll();
        sync.unlock();
        foreach (entry; toClose)
            entry.conn.close();
    }

    /// Removes a connection that will not come back, freeing its slot. Call without the lock.
    private void forget(Poolable conn) @safe
    {
        sync.lock();
        if (conn !is null)
            openedAt.remove(conn);
        active--;
        sync.notifyAll();
        sync.unlock();
    }

    /// Moves idle connections past their idle time or lifetime to `expired`. Call with the lock held.
    private void takeExpired(ref Poolable[] expired) @safe
    {
        const now = MonoTime.currTime;
        const options = owner.poolOptions;
        size_t kept;
        foreach (entry; idle[0 .. idleCount])
        {
            const opened = openedAt.get(entry.conn, now);
            if (now - entry.since > options.maxIdleTime
                    || (options.maxLifetime != Duration.zero && now - opened > options.maxLifetime)
                    || !entry.conn.isOpen)
            {
                expired ~= entry.conn;
                openedAt.remove(entry.conn);
            }
            else
                idle[kept++] = entry;
        }
        idle[kept .. idleCount] = Idle.init;
        idleCount = kept;
    }
}

private Thread currentThread() @safe nothrow
{
    return Thread.getThis();
}

version (unittest)
{
    import core.time : msecs;
    import dbwire.exception : ConnectionException;

    /// A connection for the tests: records pings and closes.
    private final class FakeConnection : Poolable
    {
        int id;
        bool open = true;
        bool busy;
        bool failPing;
        bool interruptPing; // throws a non-database exception, as an interrupted vibe.d task does
        int pings;

        this(int id) @safe
        {
            this.id = id;
        }

        @property bool isOpen() const @safe nothrow
        {
            return open;
        }

        @property bool isBusy() const @safe nothrow
        {
            return busy;
        }

        void ping() @safe
        {
            pings++;
            if (failPing)
                throw new ConnectionException("server gone");
            if (interruptPing)
                throw new Exception("interrupted");
        }

        void close() @safe nothrow
        {
            open = false;
        }
    }

    /// A pool of `FakeConnection`s numbered from 1, in thread mode.
    private struct TestPool
    {
        PoolCore pool;
        FakeConnection[] opened;
        bool failNext;

        static TestPool* create(PoolOptions options) @safe
        {
            auto t = new TestPool;
            Poolable open()
            {
                if (t.failNext)
                {
                    t.failNext = false;
                    throw new ConnectionException("cannot connect");
                }
                t.opened ~= new FakeConnection(cast(int) t.opened.length + 1);
                return t.opened[$ - 1];
            }

            t.pool = new PoolCore(options, IoMode.phobos, &open);
            return t;
        }
    }

    private FakeConnection fake(ref PoolLease lease) @trusted
    {
        return cast(FakeConnection) lease.connection; // the tests' factory makes only FakeConnections
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    // Limit and wait timeout
    PoolOptions options;
    options.maxConnections = 2;
    options.waitTimeout = 50.msecs;
    auto t = TestPool.create(options);
    auto a = t.pool.acquire();
    auto b = t.pool.acquire();
    assert(t.pool.activeConnections == 2 && t.opened.length == 2);
    const start = MonoTime.currTime;
    assertThrown!ClientException(t.pool.acquire());
    assert(MonoTime.currTime - start >= 40.msecs);

    // Duration.max waits without limit (the deadline must not overflow)
    {
        import core.thread : Thread;

        PoolOptions forever;
        forever.maxConnections = 1;
        forever.waitTimeout = Duration.max;
        auto f = TestPool.create(forever);
        auto held = f.pool.acquire();
        void releaseLater()
        {
            Thread.sleep(30.msecs);
            held.release();
        }

        auto releaser = (() @trusted => new Thread(&releaseLater).start())();
        auto next = f.pool.acquire();
        assert(fake(next).id == 1);
        (() @trusted => releaser.join())();
    }

    // Busy and closed connections are closed when returned, not reused
    fake(a).busy = true;
    a.release();
    a.release(); // a second release does nothing
    assert(!t.opened[0].open && t.pool.idleConnections == 0 && t.pool.activeConnections == 1);
    fake(b).open = false;
    b.release();
    assert(t.pool.idleConnections == 0 && t.pool.activeConnections == 0);

    // Healthy connections are reused, the most recently returned first
    {
        auto c = t.pool.acquire();
        auto d = t.pool.acquire();
        assert(fake(c).id == 3 && fake(d).id == 4);
    }
    assert(t.pool.idleConnections == 2);
    auto e = t.pool.acquire();
    assert(fake(e).id == 3); // released last (destructors run in reverse order)
}

@safe unittest
{
    import core.thread : Thread;

    // Ping after idle: a dead connection is replaced
    PoolOptions options;
    options.pingAfterIdle = Duration.zero;
    auto t = TestPool.create(options);
    t.pool.acquire(); // a temporary lease: returned at once
    {
        auto a = t.pool.acquire();
        assert(fake(a).id == 1 && t.opened[0].pings == 1);
        fake(a).failPing = true;
    }
    {
        auto a = t.pool.acquire();
        assert(fake(a).id == 2 && !t.opened[0].open);
        fake(a).interruptPing = true;
    }
    // Other exceptions reach the caller; the connection is closed, not reused
    {
        import std.exception : collectException;

        const e = collectException(t.pool.acquire());
        assert(e !is null && e.msg == "interrupted" && cast(const ClientException) e is null);
        assert(!t.opened[1].open && t.pool.activeConnections == 0 && t.pool.idleConnections == 0);
    }

    // Idle connections expire; old connections are not reused
    options = PoolOptions.init;
    options.maxIdleTime = 10.msecs;
    t = TestPool.create(options);
    t.pool.acquire();
    () @trusted { Thread.sleep(30.msecs); }();
    {
        auto a = t.pool.acquire();
        assert(fake(a).id == 2 && !t.opened[0].open);
    }
    options = PoolOptions.init;
    options.maxLifetime = 10.msecs;
    t = TestPool.create(options);
    {
        auto a = t.pool.acquire();
        () @trusted { Thread.sleep(30.msecs); }();
        a.release();
    }
    assert(!t.opened[0].open && t.pool.idleConnections == 0);
}

@safe unittest
{
    import std.exception : assertThrown;

    // A failed connect frees its slot
    PoolOptions options;
    options.maxConnections = 1;
    auto t = TestPool.create(options);
    t.failNext = true;
    assertThrown!ConnectionException(t.pool.acquire());
    assert(t.pool.activeConnections == 0);
    auto a = t.pool.acquire();
    assert(fake(a).id == 1);
}

@safe unittest
{
    import std.exception : assertThrown;

    // close(): idle connections are closed at once, connections in use when returned
    auto t = TestPool.create(PoolOptions.init);
    auto inUse = t.pool.acquire();
    t.pool.acquire(); // a second connection, returned at once: idle
    t.pool.close();
    assert(!t.opened[1].open && t.opened[0].open);
    assertThrown!ClientException(t.pool.acquire());
    inUse.release();
    assert(!t.opened[0].open);

    assertThrown!ClientException(new PoolCore(PoolOptions(0), IoMode.phobos, null));
}

@system unittest
{
    import core.thread : Thread;

    // Threads share the connections; a waiting thread gets the one returned
    PoolOptions options;
    options.maxConnections = 1;
    options.waitTimeout = 5.seconds;
    auto t = TestPool.create(options);
    auto held = t.pool.acquire();
    int gotId;
    MonoTime gotAt;
    auto other = new Thread({
        auto lease = t.pool.acquire();
        gotId = fake(lease).id;
        gotAt = MonoTime.currTime;
    });
    other.start();
    Thread.sleep(50.msecs);
    const releasedAt = MonoTime.currTime;
    held.release();
    other.join();
    assert(gotId == 1 && gotAt >= releasedAt && t.opened.length == 1);
}

@safe unittest
{
    import std.exception : assertThrown;

    // Pool options from parameters
    const o = PoolOptions.fromParams([
        "pool_max": "3",
        "pool_max_idle_time": "1",
        "pool_max_lifetime": "0",
        "pool_ping_after_idle": "0.25",
        "other": "x"
    ]);
    assert(o.maxConnections == 3 && o.maxIdleTime == 1.seconds && o.maxLifetime == Duration.zero);
    assert(o.pingAfterIdle == 250.msecs && o.waitTimeout == PoolOptions.init.waitTimeout);
    assert(PoolOptions.fromDsn("db://h") == PoolOptions.init);
    foreach (bad; ["db://h?pool_max=0", "db://h?pool_max=x", "db://h?pool_wait_timeout=-1"])
        assertThrown!ClientException(PoolOptions.fromDsn(bad), bad);
}

version (unittest)
{
    private shared int leaseHoldersFinalized;

    // An object holding a lease, as a connector's PooledConnection in a user's class.
    private final class LeaseHolder
    {
        PoolLease lease;

        ~this()
        {
            import core.atomic : atomicOp;

            atomicOp!"+="(leaseHoldersFinalized, 1);
        }
    }

    private void dropLeaseHolders(PoolCore pool) @safe
    {
        foreach (i; 0 .. 8)
        {
            auto holder = new LeaseHolder;
            holder.lease = pool.acquire();
        }
    }
}

@system unittest
{
    import core.atomic : atomicLoad;
    import core.memory : GC;

    // A lease finalized by the GC leaves the pool alone (it may be finalized already): the connection
    // stays checked out
    auto t = TestPool.create(PoolOptions.init);
    dropLeaseHolders(t.pool);
    foreach (i; 0 .. 3)
        GC.collect();
    assert(atomicLoad(leaseHoldersFinalized) > 0, "the test needs the GC to collect a holder");
    assert(t.pool.activeConnections == 8 && t.pool.idleConnections == 0);
}
