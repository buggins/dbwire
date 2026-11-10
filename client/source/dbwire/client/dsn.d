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
        const shown = redactPassword(text); // error messages must not reveal the password

        string query;
        if (auto q = rest.findSplit("?"))
        {
            rest = q[0];
            query = q[2];
        }
        const slash = rest.indexOf('/');
        if (slash >= 0)
        {
            dsn.path = decode(rest[slash + 1 .. $], shown);
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
                dsn.user = decode(up[0], shown);
                dsn.hasPassword = true;
                dsn.password = decode(up[2], shown);
            }
            else
                dsn.user = decode(userInfo, shown);
        }
        dsn.params = parseQuery(query, shown);
        if (rest.length == 0)
            throw new ClientException("The connection string has no host");
        foreach (hostPort; rest.split(","))
        {
            try
                dsn.hosts ~= parseHostPort(hostPort);
            catch (ClientException e)
                throw new ClientException(e.msg ~ " in '" ~ shown ~ "'");
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
`text` with its passwords replaced by `***`, for error messages and logs: the
one in the user info (`db://user:***@host/db`) and the values of query
parameters whose name contains `password` or is `pwd` or `passwd`, in any
case and after percent-decoding (`?password=***`, `wallet_password=***`,
`sslpassword=***`). The parts are
found as `Dsn.parse` finds them; text without `://` is returned unchanged.
+/
string redactPassword(string text) @safe pure
{
    import std.array : split;
    import std.string : indexOf, lastIndexOf;

    const scheme = text.indexOf("://");
    if (scheme < 0)
        return text;
    const start = scheme + 3;
    size_t end = text.length;
    const query = text[start .. $].indexOf('?');
    if (query >= 0)
        end = start + query;
    const slash = text[start .. end].indexOf('/');
    if (slash >= 0)
        end = start + slash;
    string result = text[0 .. end];
    const at = text[start .. end].lastIndexOf('@');
    if (at >= 0)
    {
        const colon = text[start .. start + at].indexOf(':');
        if (colon >= 0)
            result = text[0 .. start + colon + 1] ~ "***" ~ text[start + at .. end];
    }
    if (query < 0)
        return result ~ text[end .. $];
    result ~= text[end .. start + query + 1]; // the path and the '?'
    foreach (i, pair; text[start + query + 1 .. $].split("&"))
    {
        if (i)
            result ~= '&';
        const eq = pair.indexOf('=');
        result ~= eq >= 0 && isPasswordKey(pair[0 .. eq]) ? pair[0 .. eq + 1] ~ "***" : pair;
    }
    return result;
}

// Whether a query parameter holds a password: its name, percent-decoded as `Dsn.parse` decodes it, contains
// "password" or is "pwd" or "passwd" (any case)
private bool isPasswordKey(string key) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.ascii : isHexDigit, toLower;

    static uint hex(char c) @safe pure nothrow @nogc
    {
        return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
    }

    char[] name;
    for (size_t i; i < key.length; i++)
    {
        char c = key[i];
        if (c == '%' && i + 2 < key.length && isHexDigit(key[i + 1]) && isHexDigit(key[i + 2]))
        {
            c = cast(char)(hex(key[i + 1]) << 4 | hex(key[i + 2]));
            i += 2;
        }
        name ~= toLower(c);
    }
    return name.canFind("password") || name == "pwd" || name == "passwd";
}

///
@safe unittest
{
    assert(redactPassword("pg://app:s3cret@db1,db2/main?x=1") == "pg://app:***@db1,db2/main?x=1");
    assert(redactPassword("pg://app:p@ss@db") == "pg://app:***@db"); // the last '@' ends the user info
    assert(redactPassword("pg://app@db/x?a=b@c") == "pg://app@db/x?a=b@c"); // no password
    assert(redactPassword("pg://db:5432") == "pg://db:5432");
    // passwords in query parameters
    assert(redactPassword("oracle://u@h:99999/s?password=s3cret") == "oracle://u@h:99999/s?password=***");
    assert(redactPassword("oracle://u:p@h/s?wallet_password=w&x=1&SSLPassword=k&pwd=z")
            == "oracle://u:***@h/s?wallet_password=***&x=1&SSLPassword=***&pwd=***");
    assert(redactPassword("pg://h?&a=1&&password") == "pg://h?&a=1&&password"); // empty pairs, no value
    assert(redactPassword("pg://h/db?") == "pg://h/db?");
    // names as Dsn.parse decodes them
    assert(redactPassword("pg://h?pass%77ord=a&%50WD=b&ssl%70assword=c&passwd=d&pa%7=e")
            == "pg://h?pass%77ord=***&%50WD=***&ssl%70assword=***&passwd=***&pa%7=e");
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
    const hnsecs = cast(long)(secondsValue * 10_000_000);
    // a positive value never becomes zero, which means "no limit" for timeouts
    return dur!"hnsecs"(hnsecs == 0 && secondsValue > 0 ? 1 : hnsecs);
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
E parseEnumValue(E)(string key, string value) if (is(E == enum))
{
    static foreach (member; __traits(allMembers, E))
        if (value == member)
            return __traits(getMember, E, member);
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

    // Error messages quote the string without its password
    foreach (bad; [
        "db://u:topsecret@h:99999", "db://u:topsecret@h/?x=%zz", "db://u:topsecret%zz@h",
        "db://u@h:99999?password=topsecret"
    ])
    {
        import std.algorithm.searching : canFind;
        import std.exception : collectException;

        auto e = collectException!ClientException(Dsn.parse(bad, "db"));
        assert(e !is null && !e.msg.canFind("topsecret") && e.msg.canFind("***"), e.msg);
    }

    // Value parsers
    assertThrown!ClientException(parseSeconds("t", "-1"));
    assertThrown!ClientException(parseSeconds("t", "nan"));
    import core.time : Duration, hnsecs;

    assert(parseSeconds("t", "0.00000001") == hnsecs(1) && parseSeconds("t", "0") == Duration.zero);
    assertThrown!ClientException(parseSeconds("t", "1e10"));
    assertThrown!ClientException(parseFlag("f", "yes"));
    assert(!parseFlag("f", "0") && parseFlag("f", "1"));
}
