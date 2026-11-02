/++
Server addresses and failover: `HostPort`, `HostSelection` and `connectFirst`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.client.hosts;

import dbwire.exception : ClientException, ConnectionException, ProtocolException;

/// A server address.
struct HostPort
{
    /// Host name or IP address.
    string host;
    /// Port; 0 means the connector's default.
    ushort port;

    /// `host:port`, with IPv6 addresses in brackets; just the host when the port is 0.
    string toString() const @safe pure
    {
        import std.algorithm.searching : canFind;
        import std.conv : to;

        const name = host.canFind(':') ? "[" ~ host ~ "]" : host;
        return port ? name ~ ":" ~ port.to!string : name;
    }
}

/++
Parses `host`, `host:port`, `[ipv6]` or `[ipv6]:port`. A missing port is 0.

Throws: `ClientException` if the host is empty or the port is not a number from 0 to 65535.
+/
HostPort parseHostPort(string text) @safe
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.conv : ConvException, to;
    import std.string : indexOf;

    string host = text;
    string port;
    if (text.startsWith("["))
    {
        const close = text.indexOf(']');
        if (close < 0)
            throw new ClientException("Invalid host '" ~ text ~ "'");
        host = text[1 .. close];
        const after = text[close + 1 .. $];
        if (after.length)
        {
            if (!after.startsWith(":"))
                throw new ClientException("Invalid host '" ~ text ~ "'");
            port = after[1 .. $];
        }
    }
    else if (auto hp = text.findSplit(":"))
    {
        host = hp[0];
        port = hp[2];
    }
    if (host.length == 0)
        throw new ClientException("Empty host '" ~ text ~ "'");
    auto result = HostPort(host);
    if (port.length)
    {
        try
            result.port = port.to!ushort;
        catch (ConvException)
            throw new ClientException("Invalid port '" ~ port ~ "'");
    }
    return result;
}

/// The order in which several hosts are tried.
enum HostSelection
{
    /// In the given order: the first host is the primary, the others are fallbacks.
    inOrder,
    /// In random order, spreading connections over the hosts.
    random,
}

/// A copy of `hosts` in the order `selection` says.
HostPort[] orderHosts(const HostPort[] hosts, HostSelection selection) @safe
{
    import std.random : randomShuffle;

    auto result = hosts.dup;
    if (selection == HostSelection.random)
        randomShuffle(result);
    return result;
}

/++
Tries `connect` on each of `hosts` in turn and returns the first host for
which it succeeds. A `ConnectionException` or `ProtocolException` (the host
is down, unreachable, or not the expected server) moves on to the next host;
any other exception, such as a login the server rejected, is thrown at once.

Params:
    hosts = the hosts, in the order to try (see `orderHosts`).
    connect = opens the connection to one host, or throws.
    what = what is connected to, for the error message, e.g. `"ClickHouse"`.

Throws: `ConnectionException` listing each host's error if none succeeds;
the first exception of another kind as is.
+/
HostPort connectFirst(const HostPort[] hosts, scope void delegate(HostPort) @safe connect,
        string what = "the server") @safe
{
    string failures;
    foreach (host; hosts)
    {
        try
        {
            connect(host);
            return host;
        }
        catch (ConnectionException e)
            failures ~= (failures.length ? "; " : "") ~ host.toString() ~ ": " ~ e.msg;
        catch (ProtocolException e)
            failures ~= (failures.length ? "; " : "") ~ host.toString() ~ ": " ~ e.msg;
    }
    if (hosts.length == 0)
        throw new ClientException("No host to connect to");
    throw new ConnectionException("Cannot connect to " ~ what ~ ": " ~ failures);
}

///
@safe unittest
{
    const hosts = [HostPort("db1", 9000), HostPort("db2", 9000)];
    string[] tried;
    void connect(HostPort h)
    {
        tried ~= h.host;
        if (h.host == "db1")
            throw new ConnectionException("connection refused");
    }

    assert(connectFirst(hosts, &connect) == HostPort("db2", 9000));
    assert(tried == ["db1", "db2"]);
}

@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.exception : assertThrown, collectException;

    // Parsing and printing
    assert(parseHostPort("h") == HostPort("h") && parseHostPort("h:1") == HostPort("h", 1));
    assert(parseHostPort("[::1]") == HostPort("::1") && parseHostPort("[::1]:2") == HostPort("::1", 2));
    assert(HostPort("::1", 9440).toString() == "[::1]:9440" && HostPort("h").toString() == "h");
    foreach (bad; ["", ":1", "h:x", "h:65536", "[::1", "[::1]x", "[]:1"])
        assertThrown!ClientException(parseHostPort(bad), bad);

    // Ordering keeps the hosts
    const hosts = [HostPort("a"), HostPort("b"), HostPort("c")];
    assert(orderHosts(hosts, HostSelection.inOrder) == hosts);
    const sorted = orderHosts(hosts, HostSelection.random).sort!((x, y) => x.host < y.host).release();
    assert(sorted == hosts);

    // All hosts fail: one ConnectionException listing them; a rejection stops at once
    void refuse(HostPort h)
    {
        if (h.host == "b")
            throw new ProtocolException("not a database server");
        throw new ConnectionException("down");
    }

    const e = collectException!ConnectionException(connectFirst(hosts, &refuse, "the test server"));
    assert(e.msg == "Cannot connect to the test server: a: down; b: not a database server; c: down", e.msg);

    string[] tried;
    void reject(HostPort h)
    {
        tried ~= h.host;
        throw new ClientException("login rejected");
    }

    assertThrown!ClientException(connectFirst(hosts, &reject));
    assert(tried == ["a"]);
    assertThrown!ClientException(connectFirst([], &reject));
}
