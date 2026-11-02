/++
Exceptions thrown by dbwire and by the connectors built on it.

`DbException` is the base of everything; the connectors derive their server
error classes (error codes reported by the database) from it.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.exception;

import std.exception : basicExceptionCtors;

/// Base class of all exceptions thrown by dbwire and the connectors built on it.
class DbException : Exception
{
    ///
    mixin basicExceptionCtors;
}

/// Invalid use of the library, invalid options or values, or an unsupported feature.
class ClientException : DbException
{
    ///
    mixin basicExceptionCtors;
}

/// Network failure or timeout. The connection is closed and cannot be reused.
class ConnectionException : DbException
{
    ///
    mixin basicExceptionCtors;
}

/// The server sent malformed or unexpected data. The connection is closed and
/// cannot be reused.
class ProtocolException : DbException
{
    ///
    mixin basicExceptionCtors;
}

///
@safe unittest
{
    import std.exception : assertThrown;

    void connect()
    {
        throw new ConnectionException("connection refused");
    }

    assertThrown!DbException(connect()); // every dbwire exception is a DbException
    assert(new ProtocolException("bad packet").msg == "bad packet");
}
