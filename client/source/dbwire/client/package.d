/++
Connection plumbing for database connectors (subpackage `dbwire:client`).

$(UL
    $(LI `dbwire.client.dsn`: `Dsn`, URL-style connection strings, and value
        parsers for their parameters.)
    $(LI `dbwire.client.hosts`: `HostPort`, `HostSelection`, and `connectFirst`,
        which tries several hosts in turn.)
    $(LI `dbwire.client.pool`: `PoolCore`, the connector-neutral core of a
        connection pool for thread and fiber mode, with `Poolable`,
        `PoolLease` and `PoolOptions`.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.client;

public import dbwire.client.dsn;
public import dbwire.client.hosts;
public import dbwire.client.pool;
