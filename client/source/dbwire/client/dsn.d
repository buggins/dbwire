/++
URL-style connection strings (DSNs) and the parsing of their values.

A DSN looks like `scheme://user:password@host1:port1,host2/path?key=value&...`.
`Dsn.parse` splits it into its decoded parts; each connector maps the
parameters to its own options, using `parseSeconds`, `parseFlag`,
`parseEnumValue` and `parseIoMode` for typical values, and
`checkIoModeKeys` or `normalizeIoModeKey` for the I/O mode keys `io_mode` and
`io`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.client.dsn;

import core.time : Duration;

import dbwire.client.hosts : HostPort, parseHostPort;
import dbwire.exception : ClientException;
import dbwire.io.backend : IoMode;

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

/++
Parses the I/O mode: `auto`, or the name of another `IoMode` member
(`phobos`, `vibe`). `auto_`, the member's own name, is accepted too.

The connectors read it from the key `io_mode`, with `io` as a short form, so
that one spelling works with all of them (and through ddbc; #83).

Throws: `ClientException` naming `key` for any other value.
+/
IoMode parseIoMode(string key, string value) @safe
{
    if (value == "auto")
        return IoMode.auto_;
    static foreach (member; __traits(allMembers, IoMode))
        if (value == member)
            return __traits(getMember, IoMode, member);
    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (" ~ ioModeNames ~ " expected)");
}

///
@safe unittest
{
    import std.exception : assertThrown, collectExceptionMsg;

    assert(parseIoMode("io_mode", "auto") == IoMode.auto_);
    assert(parseIoMode("io_mode", "auto_") == IoMode.auto_);
    assert(parseIoMode("io", "phobos") == IoMode.phobos);
    assert(parseIoMode("io", "vibe") == IoMode.vibe);
    foreach (bad; ["", "threads", "Auto", "vibe "])
        assertThrown!ClientException(parseIoMode("io_mode", bad));
    const message = collectExceptionMsg(parseIoMode("io", "fibers"));
    assert(message == "Invalid value 'fibers' for 'io' (auto, phobos or vibe expected)", message);
}

/++
Checks the I/O mode keys of one source of parameters: `io_mode` and its short
form `io`. Each value must be a valid I/O mode (`parseIoMode`; an invalid one
is reported under its own key), and all of them must give the same mode
(`auto` and `auto_` are the same), rather than the associative array's order
deciding which one counts.

Params:
    params = the parameters of one source, e.g. a connection string's query
    ignoreKeyCase = whether keys match with ASCII letters in any case
        (`IO_MODE`), for connectors whose keys ignore case; then
        `io=vibe&IO=phobos` is a conflict too

Throws: `ClientException` for an invalid value, or for two different modes.
+/
void checkIoModeKeys(const string[string] params, bool ignoreKeyCase = false) @safe
{
    checkModes(params, ioModeKeys(params, ignoreKeyCase));
}

// checkIoModeKeys for the keys found by ioModeKeys.
private void checkModes(const string[string] params, const string[] keys) @safe
{
    auto modes = new IoMode[keys.length];
    foreach (i, key; keys)
        modes[i] = parseIoMode(key, params[key]); // all values first: an invalid one is reported as such
    foreach (i; 1 .. keys.length)
        if (modes[i] != modes[0])
            throw new ClientException("'" ~ keys[0] ~ "' and '" ~ keys[i] ~ "' give different I/O modes ('"
                    ~ params[keys[0]] ~ "' and '" ~ params[keys[i]] ~ "')");
}

///
@safe unittest
{
    import std.exception : assertNotThrown, assertThrown, collectExceptionMsg;

    assertNotThrown(checkIoModeKeys(["io": "vibe", "io_mode": "vibe"]));
    assertNotThrown(checkIoModeKeys(["io": "auto", "io_mode": "auto_"])); // the same mode
    assertNotThrown(checkIoModeKeys(["io": "phobos", "host": "h"]));
    assertNotThrown(checkIoModeKeys(null));

    auto message = collectExceptionMsg(checkIoModeKeys(["io": "vibe", "io_mode": "phobos"]));
    assert(message == "'io' and 'io_mode' give different I/O modes ('vibe' and 'phobos')", message);
    // an invalid value is reported as such, under its own key
    message = collectExceptionMsg(checkIoModeKeys(["io": "fibers", "io_mode": "phobos"]));
    assert(message == "Invalid value 'fibers' for 'io' (auto, phobos or vibe expected)", message);
    message = collectExceptionMsg(checkIoModeKeys(["io_mode": "threads"]));
    assert(message == "Invalid value 'threads' for 'io_mode' (auto, phobos or vibe expected)", message);

    // keys in another case: only with ignoreKeyCase
    assertNotThrown(checkIoModeKeys(["IO": "vibe", "io_mode": "phobos"]));
    message = collectExceptionMsg(checkIoModeKeys(["IO": "vibe", "Io_Mode": "phobos"], true));
    assert(message == "'IO' and 'Io_Mode' give different I/O modes ('vibe' and 'phobos')", message);
    assertThrown!ClientException(checkIoModeKeys(["IO_MODE": "fibers"], true));
    // two spellings of one key
    message = collectExceptionMsg(checkIoModeKeys(["io": "vibe", "IO": "phobos"], true));
    assert(message == "'IO' and 'io' give different I/O modes ('phobos' and 'vibe')", message);
    assertThrown!ClientException(checkIoModeKeys(["io": "vibe", "IO": "fibers"], true));
    assertNotThrown(checkIoModeKeys(["io": "vibe", "IO": "vibe", "IO_MODE": "vibe"], true));
}

/++
Returns a copy of `params` in which the I/O mode keys (`io_mode` and its short
form `io`) are a single `io_mode` key. When parameters from several sources
are merged (a connection string and a service file, or ddbc's properties and
URL), one source's `io` then overrides another source's `io_mode`, as for any
other key. Apply it to each source before merging, with the key rule of the
connector that reads the result: code that merges for several connectors
(ddbc) passes `ignoreKeyCase` for those whose keys ignore case (Oracle).

Values are checked here, under the key given, whenever a key is renamed or
dropped: a single key other than exactly `io_mode` (`io`, or `IO_MODE` with
`ignoreKeyCase`), and every value when the source gives more than one of the
keys, since they must agree. This happens even if another source overrides
them after merging. A single `io_mode` is checked after merging, when the
connector reads it, so that a source's invalid `io_mode` that another source
overrides doesn't matter, as for any other key. If several keys are given,
the value of `io_mode` is kept.

Params:
    params = the parameters of one source
    ignoreKeyCase = whether keys match in any case (see `checkIoModeKeys`);
        every spelling of the two keys is then replaced

Returns: the parameters with at most one I/O mode key, `io_mode`; empty (and
possibly `null`) for empty `params`.

Throws: `ClientException` as `checkIoModeKeys`, for the values checked.
+/
string[string] normalizeIoModeKey(const string[string] params, bool ignoreKeyCase = false) @safe
{
    const keys = ioModeKeys(params, ignoreKeyCase);
    if (keys.length > 1)
        checkModes(params, keys);
    else if (keys.length == 1 && keys[0] != "io_mode")
        parseIoMode(keys[0], params[keys[0]]); // renamed below: report an invalid value under the key given
    string[string] result;
    foreach (key, value; params)
        result[key] = value;
    if (keys.length == 0)
        return result;
    string value = params[keys[0]];
    foreach (key; keys)
    {
        if (key.length == 7) // io_mode, in some case; the others are io
        {
            value = params[key];
            break;
        }
    }
    foreach (key; keys)
        result.remove(key);
    result["io_mode"] = value;
    return result;
}

///
@safe unittest
{
    import std.exception : assertThrown, collectExceptionMsg;

    auto url = normalizeIoModeKey(["io": "vibe", "host": "h"]);
    auto properties = normalizeIoModeKey(["io_mode": "phobos", "user": "u"]);
    assert(url == ["io_mode": "vibe", "host": "h"]);
    // merged: the URL's mode overrides the properties' one
    foreach (key, value; url)
        properties[key] = value;
    assert(properties["io_mode"] == "vibe");

    assert(normalizeIoModeKey(["io": "auto", "io_mode": "auto_"]) == ["io_mode": "auto_"]);
    assert(normalizeIoModeKey(["IO": "vibe", "x": "1"], true) == ["io_mode": "vibe", "x": "1"]);
    assert(normalizeIoModeKey(["IO": "vibe", "x": "1"]) == ["IO": "vibe", "x": "1"]);
    assert(normalizeIoModeKey(["IO": "auto", "Io_Mode": "auto_"], true) == ["io_mode": "auto_"]);
    assert(normalizeIoModeKey(null).length == 0);
    // a single io_mode is checked after merging, when the connector reads it; io under its own name
    assert(normalizeIoModeKey(["io_mode": "fibers"]) == ["io_mode": "fibers"]);
    auto message = collectExceptionMsg(normalizeIoModeKey(["io": "fibers"]));
    assert(message == "Invalid value 'fibers' for 'io' (auto, phobos or vibe expected)", message);
    message = collectExceptionMsg(normalizeIoModeKey(["IO": "fibers"], true));
    assert(message == "Invalid value 'fibers' for 'IO' (auto, phobos or vibe expected)", message);
    message = collectExceptionMsg(normalizeIoModeKey(["IO_MODE": "fibers"], true));
    assert(message == "Invalid value 'fibers' for 'IO_MODE' (auto, phobos or vibe expected)", message);
    // checked although another source would override it: the properties' io here
    assertThrown!ClientException(normalizeIoModeKey(["io": "fibers", "user": "u"]));
    assertThrown!ClientException(normalizeIoModeKey(["io": "fibers", "io_mode": "vibe"]));
    assertThrown!ClientException(normalizeIoModeKey(["io_mode": "fibers", "IO_MODE": "vibe"], true));

    const string[string] conflict = ["io": "vibe", "io_mode": "phobos"];
    assertThrown!ClientException(normalizeIoModeKey(conflict));
    // other keys need not be valid UTF-8
    assert(normalizeIoModeKey(["\xFF": "x", "IO": "vibe"], true) == ["\xFF": "x", "io_mode": "vibe"]);
}

// The keys of `params` that are `io` or `io_mode` (with ASCII letters in any case with `ignoreKeyCase`),
// sorted, so that messages don't depend on the associative array's order. ASCII only: the names are ASCII,
// and other keys need not be valid UTF-8.
private string[] ioModeKeys(const string[string] params, bool ignoreKeyCase) @safe
{
    import std.algorithm.sorting : sort;

    string[] keys;
    foreach (key, value; params)
    {
        if (ignoreKeyCase)
        {
            if (equalsAsciiFold(key, "io") || equalsAsciiFold(key, "io_mode"))
                keys ~= key;
        }
        else if (key == "io" || key == "io_mode")
            keys ~= key;
    }
    keys.sort();
    return keys;
}

// Whether `key` is `name` (lowercase ASCII) with ASCII letters in any case. Compares bytes, so a key that
// isn't valid UTF-8 is simply different.
private bool equalsAsciiFold(string key, string name) @safe pure nothrow @nogc
{
    import std.ascii : toLower;

    if (key.length != name.length)
        return false;
    foreach (i, char c; key)
        if (toLower(c) != name[i])
            return false;
    return true;
}

// The accepted values for the error message, from the IoMode members: "auto, phobos or vibe"
private enum string ioModeNames = ioModeNameList();

private string ioModeNameList() @safe pure nothrow
{
    string[] names;
    foreach (member; __traits(allMembers, IoMode))
        names ~= member == "auto_" ? "auto" : member;
    string text;
    foreach (i, name; names)
        text ~= (i == 0 ? "" : i + 1 == names.length ? " or " : ", ") ~ name;
    return text;
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
