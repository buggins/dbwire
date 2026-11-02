/++
URL-style connection strings (DSNs) and the parsing of their values.

A DSN looks like `scheme://user:password@host1:port1,host2/path?key=value&...`.
`Dsn.parse` splits it into its decoded parts; each connector maps the
parameters to its own options, using `parseSeconds`, `parseFlag` and
`parseEnumValue` for typical values.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.client.dsn;

import core.time : Duration;

import dbwire.client.hosts : HostPort, parseHostPort;
import dbwire.exception : ClientException;

/// The parts of a connection string, percent-decoded.
struct Dsn
{
    /// The scheme, e.g. `"clickhouse"`.
    string scheme;
    /// Whether a user name was given (`user@` or `user:password@`).
    bool hasUser;
    /// The user name, or empty.
    string user;
    /// Whether a password was given (`user:password@`).
    bool hasPassword;
    /// The password, or empty.
    string password;
    /// The hosts, in the given order (at least one); a port of 0 means the connector's default.
    HostPort[] hosts;
    /// The path after the hosts without its leading `/` (typically the database), or empty.
    string path;
    /// The query parameters; a parameter without `=` has the value `"true"`.
    string[string] params;

    /++
    Parses `scheme://[user[:password]@]host[:port][,host[:port]...][/path][?key=value&...]`.

    User, password, path, keys and values may be percent-encoded. IPv6
    addresses go in brackets: `[::1]:9000`. When a key repeats, the last value wins.

    Throws: `ClientException` if the string does not start with `scheme://`,
    has no host, or is malformed.
    +/
    static Dsn parse(string text, string scheme) @safe
    {
        import std.algorithm.searching : findSplit, startsWith;
        import std.array : split;
        import std.string : indexOf, lastIndexOf;

        const prefix = scheme ~ "://";
        if (!text.startsWith(prefix))
            throw new ClientException("A connection string must start with '" ~ prefix ~ "'");
        Dsn dsn;
        dsn.scheme = scheme;
        string rest = text[prefix.length .. $];

        string query;
        if (auto q = rest.findSplit("?"))
        {
            rest = q[0];
            query = q[2];
        }
        const slash = rest.indexOf('/');
        if (slash >= 0)
        {
            dsn.path = decode(rest[slash + 1 .. $], text);
            rest = rest[0 .. slash];
        }
        const at = rest.lastIndexOf('@');
        if (at >= 0)
        {
            const userInfo = rest[0 .. at];
            rest = rest[at + 1 .. $];
            dsn.hasUser = true;
            if (auto up = userInfo.findSplit(":"))
            {
                dsn.user = decode(up[0], text);
                dsn.hasPassword = true;
                dsn.password = decode(up[2], text);
            }
            else
                dsn.user = decode(userInfo, text);
        }
        dsn.params = parseQuery(query, text);
        if (rest.length == 0)
            throw new ClientException("The connection string has no host");
        foreach (hostPort; rest.split(","))
        {
            try
                dsn.hosts ~= parseHostPort(hostPort);
            catch (ClientException e)
                throw new ClientException(e.msg ~ " in '" ~ text ~ "'");
        }
        return dsn;
    }
}

///
@safe unittest
{
    const dsn = Dsn.parse("clickhouse://reader:s%40cret@db1:9001,db2/analytics?compress=lz4&max_threads=4",
            "clickhouse");
    assert(dsn.user == "reader" && dsn.password == "s@cret" && dsn.path == "analytics");
    assert(dsn.hosts == [HostPort("db1", 9001), HostPort("db2")]); // db2: the connector's default port
    assert(dsn.params.length == 2 && dsn.params["compress"] == "lz4" && dsn.params["max_threads"] == "4");
}

/++
Parses the query part of a connection string (`key=value&key2=value2`,
without the `?`), percent-decoding keys and values. A key without `=` gets
the value `"true"`; empty pairs are skipped.

Params:
    query = the text after `?`.
    context = the whole string, quoted in error messages.

Throws: `ClientException` on invalid percent-encoding.
+/
string[string] parseQuery(string query, string context = null) @safe
{
    import std.algorithm.searching : findSplit;
    import std.array : split;

    string[string] params;
    foreach (pair; query.split("&"))
    {
        if (pair.length == 0)
            continue;
        if (auto kv = pair.findSplit("="))
            params[decode(kv[0], context)] = decode(kv[2], context);
        else
            params[decode(pair, context)] = "true";
    }
    return params;
}

/++
Parses a number of seconds, possibly fractional (`"2.5"`), as a `Duration`.

Throws: `ClientException` naming `key` if the value is not a number from 0 to 10^9.
+/
Duration parseSeconds(string key, string value) @safe
{
    import core.time : dur;
    import std.conv : ConvException, to;

    double secondsValue;
    try
        secondsValue = value.to!double;
    catch (ConvException)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (seconds expected)");
    if (!(secondsValue >= 0) || secondsValue > 1e9)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (seconds expected)");
    return dur!"hnsecs"(cast(long)(secondsValue * 10_000_000));
}

/++
Parses a flag: `true`/`1` or `false`/`0`.

Throws: `ClientException` naming `key` for any other value.
+/
bool parseFlag(string key, string value) @safe
{
    switch (value)
    {
    case "true":
    case "1":
        return true;
    case "false":
    case "0":
        return false;
    default:
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (true or false expected)");
    }
}

/++
Parses the name of a member of enum `E`.

Throws: `ClientException` naming `key` if `value` is not a member name.
+/
E parseEnumValue(E)(string key, string value) @safe if (is(E == enum))
{
    import std.conv : ConvException, to;

    try
        return value.to!E;
    catch (ConvException)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
}

///
@safe unittest
{
    import core.time : msecs;

    enum Mode
    {
        fast,
        safe
    }

    const params = parseQuery("timeout=0.5&verbose&mode=safe&name=a%20b");
    assert(parseSeconds("timeout", params["timeout"]) == 500.msecs);
    assert(parseFlag("verbose", params["verbose"]));
    assert(parseEnumValue!Mode("mode", params["mode"]) == Mode.safe);
    assert(params["name"] == "a b");
}

private string decode(string encoded, string context) @safe
{
    import std.uri : URIException, decodeComponent;

    try
        return decodeComponent(encoded);
    catch (URIException)
        throw new ClientException("Invalid percent-encoding in '" ~ (context.length ? context : encoded) ~ "'");
}

@safe unittest
{
    import std.exception : assertThrown;

    // Minimal strings, users without passwords, encoded parts, IPv6
    auto d = Dsn.parse("db://localhost", "db");
    assert(d.hosts == [HostPort("localhost")] && !d.hasUser && !d.hasPassword && d.path == "" && d.params.length == 0);
    d = Dsn.parse("db://admin@h/my%20db", "db");
    assert(d.hasUser && d.user == "admin" && !d.hasPassword && d.path == "my db");
    d = Dsn.parse("db://u:@h", "db");
    assert(d.hasPassword && d.password == "");
    d = Dsn.parse("db://u:p%3Aq@[::1]:9440,[fe80::1]/?a=1&a=2&flag", "db");
    assert(d.password == "p:q" && d.hosts == [HostPort("::1", 9440), HostPort("fe80::1")]);
    assert(d.params == ["a": "2", "flag": "true"] && d.path == "");
    d = Dsn.parse("db://us%40er:p@ss@h", "db"); // the last '@' ends the user info
    assert(d.user == "us@er" && d.password == "p@ss" && d.hosts == [HostPort("h")]);

    foreach (bad; [
        "http://h", "db://", "db://h:notaport", "db://h:99999", "db://[::1", "db://[::1]x",
        "db://h?x=%zz", "db://h,,h2", "db://:9000", "db://user@"
    ])
        assertThrown!ClientException(Dsn.parse(bad, "db"), bad);

    // Value parsers
    assertThrown!ClientException(parseSeconds("t", "-1"));
    assertThrown!ClientException(parseSeconds("t", "nan"));
    assertThrown!ClientException(parseSeconds("t", "1e10"));
    assertThrown!ClientException(parseFlag("f", "yes"));
    assert(!parseFlag("f", "0") && parseFlag("f", "1"));
}
