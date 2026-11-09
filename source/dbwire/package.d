/++
dbwire: shared building blocks for native D database connectors.

The package is split into subpackages, so that each user pulls in only what it
needs:

$(UL
    $(LI `dbwire:types`: exceptions and value types (exact decimals, 128/256-bit
        integers, intervals, time zones); no dependencies.)
    $(LI `dbwire:io`: byte-stream transports and I/O backends for blocking
        Phobos sockets and vibe.d fibers.)
    $(LI `dbwire:tls`: TLS over any transport, with OpenSSL loaded at run time.)
    $(LI `dbwire:crypto`: pure-D cryptography for authentication protocols.)
    $(LI `dbwire:charset`: UTF-16 and code page conversions.)
    $(LI `dbwire:client`: connection strings, host failover, connection pool core.)
)

This root package depends on all of them; `import dbwire;` imports everything.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   Vadim Lopatin
+/
module dbwire;

public import dbwire.charset;
public import dbwire.client;
public import dbwire.crypto;
public import dbwire.io;
public import dbwire.tls;
public import dbwire.types;

/// Library version.
enum uint dbwireVersionMajor = 0;
/// ditto
enum uint dbwireVersionMinor = 9;
/// ditto
enum uint dbwireVersionPatch = 1;

/// Library version as a string, e.g. `"0.1.0"`.
enum string dbwireVersion = versionString(dbwireVersionMajor, dbwireVersionMinor, dbwireVersionPatch);

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

///
@safe unittest
{
    import std.algorithm.searching : count;

    assert(dbwireVersion.count('.') == 2);
}
