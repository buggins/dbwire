/++
TLS over any `Transport`, using the system OpenSSL library (loaded at run time,
see `dbwire.tls.openssl`).

`TlsTransport` wraps a raw transport (a Phobos socket, a vibe.d connection, or
a user-supplied one) and works the same in thread and fiber mode. OpenSSL never
touches the socket: it encrypts and decrypts in memory buffers, and every byte
still goes through the raw transport, with its timeouts and its fiber
behaviour.

One `read` and one concurrent `write` are allowed, as cancelling a running
query needs: a cancel may be written from another thread or task while the
owner is blocked reading.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.tls.transport;

import core.stdc.config : c_long;
import core.time : Duration;

import dbwire.exception : ClientException, ConnectionException;
import dbwire.io.backend : IoBackend, IoLock;
import dbwire.tls.openssl;
import dbwire.io.transport : Transport;

/// TLS settings for a connection.
struct TlsOptions
{
    /// PEM file with the certificate authorities to trust. Empty: the system's default store.
    string caFile;
    /// PEM file with the client certificate (and its chain), for mutual TLS.
    string certFile;
    /// PEM file with the client certificate's private key. Empty: taken from `certFile`.
    string keyFile;
    /// Don't verify the server certificate or its name. For development only.
    bool skipVerify;
    /// Name to send (SNI) and verify instead of the host connected to, e.g. when
    /// connecting through an IP address, a tunnel or a proxy.
    string serverName;
}

/++
A configured OpenSSL context. Client contexts are cached per set of options
(see `client`) and shared by all connections that use those options.
+/
final class TlsContext
{
    private const(OpenSslApi)* api;
    private SslCtx* ctx;
    private bool verifyPeer;
    /// Certificates added from the Windows "ROOT" system store (Windows only).
    package size_t windowsRootCertificates;

    private struct Key
    {
        string caFile;
        string certFile;
        string keyFile;
        bool skipVerify;
    }

    private __gshared TlsContext[Key] cache;

    /++
    Returns the client context for `options`, creating it on first use.
    `options.serverName` is per connection and does not affect the context.

    Throws: `ClientException` if OpenSSL cannot be loaded, or a certificate
    or key file cannot be used.
    +/
    static TlsContext client(const TlsOptions options) @safe
    {
        const key = Key(options.caFile, options.certFile, options.keyFile, options.skipVerify);
        synchronized
        {
            if (auto found = cachedContext(key))
                return found;
            auto context = new TlsContext(options, false);
            cacheContext(key, context);
            return context;
        }
    }

    /++
    Creates a context. A server context (used by the unit tests) presents
    `certFile` and, when `caFile` is set, requires client certificates signed
    by it.
    +/
    package this(const TlsOptions options, bool server) @trusted
    {
        // Every pointer passed to OpenSSL is either a context it just returned or a
        // zero-terminated copy of a D string that lives during the call.
        import std.string : toStringz;

        api = openSsl();
        ctx = api.sslCtxNew(server ? api.tlsServerMethod() : api.tlsClientMethod());
        if (ctx is null)
            throw new ClientException("Cannot create a TLS context: " ~ errorQueueText(api));
        api.sslCtxCtrl(ctx, sslCtrlSetMinProtoVersion, tls12Version, null);

        void check(int result, string what)
        {
            if (result != 1)
                throw new ClientException(what ~ ": " ~ errorQueueText(api));
        }

        verifyPeer = server ? options.caFile.length > 0 : !options.skipVerify;
        if (verifyPeer)
        {
            if (options.caFile.length)
                check(api.sslCtxLoadVerifyLocations(ctx, options.caFile.toStringz, null),
                        "Cannot load trusted certificates from " ~ options.caFile);
            else
            {
                check(api.sslCtxSetDefaultVerifyPaths(ctx), "Cannot load the system's trusted certificates");
                // OpenSSL's defaults don't include the Windows certificate store
                version (Windows)
                    windowsRootCertificates = addWindowsRootCertificates(api, ctx);
            }
            api.sslCtxSetVerify(ctx, server ? sslVerifyPeer | sslVerifyFailIfNoPeerCert : sslVerifyPeer, null);
        }
        else
            api.sslCtxSetVerify(ctx, sslVerifyNone, null);

        if (options.certFile.length)
        {
            const keyFile = options.keyFile.length ? options.keyFile : options.certFile;
            check(api.sslCtxUseCertificateChainFile(ctx, options.certFile.toStringz),
                    "Cannot load the certificate " ~ options.certFile);
            check(api.sslCtxUsePrivateKeyFile(ctx, keyFile.toStringz, sslFiletypePem),
                    "Cannot load the private key " ~ keyFile);
            check(api.sslCtxCheckPrivateKey(ctx), "The private key " ~ keyFile ~ " does not match the certificate");
        }
    }

    private static TlsContext cachedContext(const Key key) @trusted
    {
        auto found = key in cache; // only called inside the synchronized block of client()
        return found ? *found : null;
    }

    private static void cacheContext(const Key key, TlsContext context) @trusted
    {
        cache[key] = context; // only called inside the synchronized block of client()
    }
}

/++
A TLS connection over a raw `Transport`.

The constructor performs the handshake. Afterwards the object is used like
any other transport; `close` also closes the raw transport.
+/
final class TlsTransport : Transport
{
    private enum size_t writeChunk = 64 * 1024;

    private Transport raw;
    private const(OpenSslApi)* api;
    private Ssl* ssl;
    private Bio* rbio; // ciphertext from the peer, owned by ssl
    private Bio* wbio; // ciphertext for the peer, owned by ssl
    private IoLock sslLock; // guards every OpenSSL call; never held during raw I/O
    private IoLock writeLock; // serializes raw writes; output is taken from wbio only while holding it
    private ubyte[] input; // buffer for raw reads
    private ubyte[] plainBuffer; // storage for data decrypted by dataAvailable
    private ubyte[] plain; // decrypted data not yet returned by read
    private string peerName;
    private bool ended; // the peer closed the stream
    private bool failed; // an operation failed; the stream state is unknown
    private bool closed;

    /++
    Performs a TLS client handshake over `raw`.

    Params:
        raw = the connected raw transport. On failure it is closed.
        backend = the I/O backend of the connection, which provides the locks.
        context = the client context, from `TlsContext.client`.
        host = the host connected to.
        options = TLS options; only `serverName` and `skipVerify` are used here.
        handshakeTimeout = receive and send timeout set on `raw` for the
            handshake. The caller sets the normal timeouts afterwards.

    Throws: `ConnectionException` if the handshake fails or the server
    certificate is not accepted.
    +/
    this(Transport raw, IoBackend backend, TlsContext context, string host, const TlsOptions options,
            Duration handshakeTimeout) @safe
    {
        const name = options.serverName.length ? options.serverName : host;
        this(raw, backend, context, false, name, !options.skipVerify, handshakeTimeout);
    }

    /// Accepts a TLS connection as the server (used by the unit tests).
    package static TlsTransport accept(Transport raw, IoBackend backend, TlsContext context,
            Duration handshakeTimeout) @safe
    {
        return new TlsTransport(raw, backend, context, true, "the client", false, handshakeTimeout);
    }

    private this(Transport raw, IoBackend backend, TlsContext context, bool server, string name, bool verifyName,
            Duration handshakeTimeout) @safe
    {
        this.raw = raw;
        api = context.api;
        peerName = name;
        sslLock = backend.newLock();
        writeLock = backend.newLock();
        input = new ubyte[17 * 1024]; // one maximum-size TLS record and its overhead
        plainBuffer = new ubyte[16 * 1024];
        scope (failure)
            close();
        failed = true; // until the handshake completes, close() must not send a close_notify
        createSsl(context, server, verifyName);
        raw.setTimeouts(handshakeTimeout, handshakeTimeout);
        handshake();
        failed = false;
    }

    override size_t read(scope ubyte[] buffer) @safe
    {
        checkOpen();
        scope (failure)
            failed = true;
        if (plain.length)
            return takePlain(buffer);
        if (ended)
            return 0;
        for (;;)
        {
            const r = sslRead(buffer);
            if (r.outputPending)
            {
                version (unittest)
                    readsThatSent++;
                flushOutput();
            }
            if (r.bytes > 0)
                return r.bytes;
            if (r.error == sslErrorZeroReturn)
            {
                ended = true;
                return 0;
            }
            if (r.error != sslErrorWantRead)
                throw failure("TLS read failed");
            if (!fill())
                return 0;
        }
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        checkOpen();
        scope (failure)
            failed = true;
        writeLock.lock();
        scope (exit)
            writeLock.unlock();
        while (data.length)
        {
            const chunk = data.length < writeChunk ? data : data[0 .. writeChunk];
            if (!sslWrite(chunk))
                throw failure("TLS write failed");
            sendPending();
            data = data[chunk.length .. $];
        }
    }

    /++
    Whether `read` can return without blocking. Raw data that is ready is read
    and decrypted here: a TLS record without application data (such as a
    session ticket) does not count.
    +/
    override bool dataAvailable() @safe
    {
        checkOpen();
        scope (failure)
            failed = true;
        if (plain.length || ended || sslPendingBytes() > 0)
            return true;
        while (raw.dataAvailable())
        {
            if (!fill())
                return true; // end of stream: read() returns 0 without blocking
            const r = sslRead(plainBuffer);
            if (r.outputPending)
                flushOutput();
            if (r.bytes > 0)
            {
                plain = plainBuffer[0 .. r.bytes];
                return true;
            }
            if (r.error == sslErrorZeroReturn)
            {
                ended = true;
                return true;
            }
            if (r.error != sslErrorWantRead)
                throw failure("TLS read failed");
        }
        return false;
    }

    /++
    Closes the TLS connection and the raw transport. If the connection is
    healthy, a close_notify alert is sent first, with a short timeout.
    +/
    override void close() @safe nothrow
    {
        import core.time : seconds;

        if (closed)
            return;
        closed = true;
        if (!failed && !ended && ssl !is null)
        {
            try
            {
                raw.setTimeouts(1.seconds, 1.seconds);
                writeLock.lock();
                scope (exit)
                    writeLock.unlock();
                sslShutdown();
                sendPending();
            }
            catch (Exception)
            {
                // the alert is a courtesy; the connection is closed either way
            }
        }
        raw.close();
        freeSsl();
    }

    override bool connected() const @safe nothrow
    {
        return !closed && raw.connected;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        raw.setTimeouts(receive, send);
    }

    /// The negotiated protocol, e.g. `"TLSv1.3"`.
    @property string protocolVersion() @trusted
    {
        // reads a static string owned by OpenSSL
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        return ssl is null ? "" : fromCString(api.sslGetVersion(ssl));
    }

    /// The negotiated cipher suite, e.g. `"TLS_AES_256_GCM_SHA384"`.
    @property string cipher() @trusted
    {
        // reads a static string owned by OpenSSL
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        if (ssl is null)
            return "";
        auto suite = api.sslGetCurrentCipher(ssl);
        return suite is null ? "" : fromCString(api.sslCipherGetName(suite));
    }

    version (unittest)
    {
        /// How many `read` calls had to send data (e.g. a queued key update).
        package size_t readsThatSent;

        /// Asks the peer to update its keys too; tests a read that has to send.
        package void requestKeyUpdate() @trusted
        {
            // ssl is a live connection; the call only queues a handshake message
            sslLock.lock();
            scope (exit)
                sslLock.unlock();
            api.sslKeyUpdate(ssl, sslKeyUpdateRequested);
        }
    }

    private void createSsl(TlsContext context, bool server, bool verifyName) @trusted
    {
        // OpenSSL objects are created and connected here; the strings are zero-terminated
        // copies, and OpenSSL copies them in turn.
        import std.string : toStringz;

        ssl = api.sslNew(context.ctx);
        if (ssl is null)
            throw new ConnectionException("Cannot create a TLS connection: " ~ errorQueueText(api));
        rbio = api.bioNew(api.bioSMem());
        wbio = api.bioNew(api.bioSMem());
        if (rbio is null || wbio is null)
        {
            if (rbio !is null)
                api.bioFree(rbio);
            if (wbio !is null)
                api.bioFree(wbio);
            rbio = wbio = null;
            throw new ConnectionException("Cannot create TLS buffers: " ~ errorQueueText(api));
        }
        api.sslSetBio(ssl, rbio, wbio); // ssl owns both BIOs from now on
        if (server)
        {
            api.sslSetAcceptState(ssl);
            return;
        }
        api.sslSetConnectState(ssl);
        const ip = isIpLiteral(peerName);
        if (!ip) // SNI carries host names only (RFC 6066)
            api.sslCtrl(ssl, sslCtrlSetTlsextHostname, tlsextNametypeHostName, cast(void*) peerName.toStringz);
        if (verifyName && context.verifyPeer)
        {
            const ok = ip ? api.x509VerifyParamSet1IpAsc(api.sslGet0Param(ssl), peerName.toStringz) : api.sslSet1Host(
                    ssl, peerName.toStringz);
            if (ok != 1)
                throw new ConnectionException("Cannot set the TLS peer name " ~ peerName ~ ": " ~ errorQueueText(api));
        }
    }

    private void handshake() @safe
    {
        for (;;)
        {
            const error = handshakeStep();
            flushOutput();
            if (error == sslErrorNone)
                return;
            if (error != sslErrorWantRead)
                throw failure("TLS handshake with " ~ peerName ~ " failed");
            if (!fill())
            {
                // a rejected certificate makes the peer close the connection
                auto e = failure("TLS handshake with " ~ peerName ~ " failed");
                throw new ConnectionException(e.msg ~ " (the connection was closed by the peer)");
            }
        }
    }

    /// Reads raw data into the TLS input. Returns false at the end of the stream.
    private bool fill() @safe
    {
        const n = raw.read(input);
        if (n == 0)
        {
            ended = true;
            return false;
        }
        feed(input[0 .. n]);
        return true;
    }

    private size_t takePlain(scope ubyte[] buffer) @safe
    {
        const n = buffer.length < plain.length ? buffer.length : plain.length;
        buffer[0 .. n] = plain[0 .. n];
        plain = plain[n .. $];
        return n;
    }

    /// Sends everything OpenSSL has produced, taking the write lock.
    private void flushOutput() @safe
    {
        writeLock.lock();
        scope (exit)
            writeLock.unlock();
        sendPending();
    }

    /// Sends everything OpenSSL has produced. The caller holds `writeLock`.
    private void sendPending() @safe
    {
        for (;;)
        {
            auto output = takeOutput();
            if (output.length == 0)
                return;
            raw.write(output);
        }
    }

    private void checkOpen() const @safe
    {
        if (closed)
            throw new ConnectionException("The TLS connection is closed");
    }

    // The functions below are the only ones calling OpenSSL on a live connection. Each
    // holds sslLock, checks that ssl is still allocated, and passes OpenSSL pointers and
    // lengths of D arrays that stay alive during the call.

    /// Advances the handshake. Returns `sslErrorNone` once it is complete, else the SSL error code.
    private int handshakeStep() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        const r = api.sslDoHandshake(ssl);
        return r == 1 ? sslErrorNone : api.sslGetError(ssl, r);
    }

    /// Result of one `SSL_read`.
    private static struct ReadResult
    {
        int bytes; /// decrypted bytes, or <= 0
        int error; /// SSL error code when `bytes <= 0`
        bool outputPending; /// OpenSSL produced data to send (e.g. a queued key update)
    }

    private ReadResult sslRead(scope ubyte[] buffer) @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        ReadResult r;
        r.bytes = api.sslRead(ssl, buffer.ptr, buffer.length > int.max ? int.max : cast(int) buffer.length);
        r.error = r.bytes > 0 ? sslErrorNone : api.sslGetError(ssl, r.bytes);
        r.outputPending = api.bioCtrl(wbio, bioCtrlPending, 0, null) > 0;
        return r;
    }

    private bool sslWrite(scope const(ubyte)[] data) @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        // With a memory BIO for output, SSL_write consumes all of data or fails
        return api.sslWrite(ssl, data.ptr, cast(int) data.length) == cast(int) data.length;
    }

    private int sslPendingBytes() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        return api.sslPending(ssl);
    }

    private void sslShutdown() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        api.sslShutdown(ssl);
    }

    private void feed(scope const(ubyte)[] data) @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        // A memory BIO accepts all the data
        if (api.bioWrite(rbio, data.ptr, cast(int) data.length) != cast(int) data.length)
            throw new ConnectionException("TLS buffer write failed");
    }

    private ubyte[] takeOutput() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        const pending = api.bioCtrl(wbio, bioCtrlPending, 0, null);
        if (pending <= 0)
            return null;
        auto output = new ubyte[cast(size_t) pending];
        const n = api.bioRead(wbio, output.ptr, cast(int) output.length);
        return n > 0 ? output[0 .. n] : null;
    }

    private void freeSsl() @trusted nothrow
    {
        try
        {
            sslLock.lock();
            scope (exit)
                sslLock.unlock();
            if (ssl !is null)
                api.sslFree(ssl); // frees rbio and wbio too
            ssl = null;
            rbio = wbio = null;
        }
        catch (Exception)
        {
            // a lock failure here only leaks the connection's memory
        }
    }

    private void checkSsl() const @safe
    {
        if (ssl is null)
            throw new ConnectionException("The TLS connection is closed");
    }

    /// An exception for a failed OpenSSL call, with OpenSSL's reasons.
    private ConnectionException failure(string what) @trusted
    {
        // reads the verification result of a live connection and this thread's error queue
        c_long verify = x509VOk;
        try
        {
            sslLock.lock();
            scope (exit)
                sslLock.unlock();
            if (ssl !is null)
                verify = api.sslGetVerifyResult(ssl);
        }
        catch (Exception)
        {
            // keep the generic message
        }
        const reasons = errorQueueText(api);
        if (verify != x509VOk)
            return new ConnectionException("TLS certificate verification failed for " ~ peerName ~ ": "
                    ~ fromCString(
                        api.x509VerifyCertErrorString(verify)));
        return new ConnectionException(what ~ (reasons.length ? ": " ~ reasons : ""));
    }
}

version (Windows)
{
    import core.sys.windows.wincrypt : CertCloseStore, CertOpenSystemStoreW, HCERTSTORE, HCRYPTPROV,
        PCCERT_CONTEXT, X509_ASN_ENCODING;

    // crypt32 is linked through "libs-windows" in dub.json: a pragma(lib) in a static
    // library does not reach the final link with every compiler.

    // Not declared in druntime's wincrypt module
    private extern (Windows) PCCERT_CONTEXT CertEnumCertificatesInStore(HCERTSTORE store,
            PCCERT_CONTEXT previous) nothrow @nogc;

    /// Adds the certificates of the Windows "ROOT" system store to the trust store of `ctx`.
    /// Returns: how many were added.
    private size_t addWindowsRootCertificates(const(OpenSslApi)* api, SslCtx* ctx) @trusted nothrow
    {
        // The store and certificate contexts come from crypt32 and are used only while open;
        // d2i_X509 reads exactly cbCertEncoded bytes of the DER-encoded certificate.
        auto store = CertOpenSystemStoreW(HCRYPTPROV.init, "ROOT"w.ptr);
        if (store is null)
            return 0;
        scope (exit)
            CertCloseStore(store, 0);
        auto trusted = api.sslCtxGetCertStore(ctx);
        size_t added;
        for (auto cert = CertEnumCertificatesInStore(store, null); cert !is null; cert = CertEnumCertificatesInStore(
                store, cert))
        {
            if ((cert.dwCertEncodingType & X509_ASN_ENCODING) == 0)
                continue;
            const(ubyte)* der = cert.pbCertEncoded;
            auto x509 = api.d2iX509(null, &der, cert.cbCertEncoded);
            if (x509 is null)
                continue;
            if (api.x509StoreAddCert(trusted, x509) == 1)
                added++;
            api.x509Free(x509); // the store keeps its own reference
        }
        api.errClearError(); // e.g. duplicates or certificates OpenSSL cannot parse
        return added;
    }
}

/// The messages in this thread's OpenSSL error queue, which is emptied.
private string errorQueueText(const(OpenSslApi)* api) @trusted nothrow
{
    // ERR_error_string_n writes at most buffer.length bytes, zero-terminated
    string text;
    char[256] buffer;
    for (;;)
    {
        const code = api.errGetError();
        if (code == 0)
            break;
        api.errErrorStringN(code, buffer.ptr, buffer.length);
        text ~= (text.length ? "; " : "") ~ fromCString(buffer.ptr);
    }
    return text;
}

/// Whether `name` is an IPv4 or IPv6 address rather than a host name.
private bool isIpLiteral(string name) @safe pure nothrow @nogc
{
    foreach (c; name)
        if (c == ':')
            return true; // only IPv6 addresses contain colons
    size_t parts = 1, digits;
    foreach (c; name)
    {
        if (c == '.')
        {
            if (digits == 0)
                return false;
            parts++;
            digits = 0;
        }
        else if (c >= '0' && c <= '9' && digits < 3)
            digits++;
        else
            return false;
    }
    return parts == 4 && digits > 0;
}

@safe unittest
{
    assert(isIpLiteral("127.0.0.1"));
    assert(isIpLiteral("::1"));
    assert(isIpLiteral("2001:db8::7"));
    assert(!isIpLiteral("localhost"));
    assert(!isIpLiteral("db1.example.com"));
    assert(!isIpLiteral("1.2.3"));
    assert(!isIpLiteral("1.2.3.4.example"));
}

version (unittest)
{
    import core.thread : Thread;
    import core.time : msecs, seconds;
    import std.socket : InternetAddress, TcpSocket;

    import dbwire.io.phobos : PhobosBackend, PhobosTransport;

    private string testFile(string name) @safe
    {
        import std.path : buildPath, dirName;

        return buildPath(dirName(__FILE_FULL_PATH__), "testdata", name);
    }

    /// Whether OpenSSL can be loaded. CI sets DBWIRE_REQUIRE_OPENSSL=1 so that it must.
    private bool haveOpenSsl() @trusted // stderr is a __gshared File
    {
        import std.process : environment;
        import std.stdio : stderr;

        static bool reported;
        try
        {
            const ver = loadOpenSsl();
            if (!reported)
                stderr.writeln("dbwire: TLS unit tests use ", ver, " (", openSslLibrary(), ")");
            reported = true;
            return true;
        }
        catch (ClientException e)
        {
            if (environment.get("DBWIRE_REQUIRE_OPENSSL", "") == "1")
                throw e;
            stderr.writeln("dbwire: OpenSSL not available, TLS unit tests skipped");
            return false;
        }
    }

    private TlsOptions trustingOptions() @safe
    {
        TlsOptions options;
        options.caFile = testFile("ca.pem");
        return options;
    }

    private TlsContext serverContext(bool requireClientCertificate) @safe
    {
        TlsOptions options;
        options.certFile = testFile("server.pem");
        options.keyFile = testFile("server.key");
        if (requireClientCertificate)
            options.caFile = testFile("ca.pem");
        return new TlsContext(options, true);
    }

    /// A TLS client and server connected over a local TCP socket.
    private struct TlsPair
    {
        TlsTransport client;
        TlsTransport server;
        Exception clientError;
        Exception serverError;

        void close() @safe
        {
            if (client !is null)
                client.close();
            if (server !is null)
                server.close();
        }
    }

    private TlsPair connectPair(const TlsOptions clientOptions, string host = "localhost",
            TlsContext server = null) @system
    {
        if (server is null)
            server = serverContext(false);
        auto listener = new TcpSocket;
        scope (exit)
            listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(1);
        const port = (cast(InternetAddress) listener.localAddress).port;

        TlsPair pair;
        auto backend = new PhobosBackend;
        auto serverThread = new Thread({
            try
            {
                auto raw = new PhobosTransport(listener.accept());
                pair.server = TlsTransport.accept(raw, backend, server, 10.seconds);
                pair.server.setTimeouts(10.seconds, 10.seconds);
            }
            catch (Exception e)
                pair.serverError = e;
        });
        serverThread.start();
        try
        {
            auto raw = backend.connect("127.0.0.1", port, 10.seconds);
            pair.client = new TlsTransport(raw, backend, new TlsContext(clientOptions, false), host,
                    clientOptions, 10.seconds);
            pair.client.setTimeouts(10.seconds, 10.seconds);
        }
        catch (Exception e)
            pair.clientError = e;
        serverThread.join();
        return pair;
    }

    private void readExactly(Transport t, ubyte[] buffer) @safe
    {
        size_t got;
        while (got < buffer.length)
        {
            const n = t.read(buffer[got .. $]);
            assert(n > 0, "unexpected end of stream");
            got += n;
        }
    }

    private ubyte patternByte(size_t i) @safe pure nothrow
    {
        return cast(ubyte)(i * 31 + 7);
    }
}

// Handshake with verification, data both ways, reads of many sizes
unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null, pair.clientError.msg);
    assert(pair.serverError is null, pair.serverError.msg);
    assert(pair.client.protocolVersion == "TLSv1.3", pair.client.protocolVersion);
    assert(pair.client.cipher.length > 0);

    pair.client.write(cast(const(ubyte)[]) "hello");
    auto hello = new ubyte[5];
    readExactly(pair.server, hello);
    assert(hello == cast(const(ubyte)[]) "hello");

    auto data = new ubyte[200_000];
    foreach (i, ref b; data)
        b = patternByte(i);
    pair.server.write(data);
    size_t got;
    size_t size = 1;
    auto buffer = new ubyte[70_000];
    while (got < data.length)
    {
        const want = size < data.length - got ? size : data.length - got;
        const n = pair.client.read(buffer[0 .. want]);
        assert(n > 0 && n <= want);
        assert(buffer[0 .. n] == data[got .. got + n]);
        got += n;
        size = size * 3 + 1; // 1, 4, 13, 40, ... up to the buffer size
        if (size > buffer.length)
            size = 1;
    }
}

// dataAvailable ignores records without application data (TLS 1.3 session tickets)
unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null && pair.serverError is null);
    Thread.sleep(100.msecs); // let the session tickets arrive
    assert(!pair.client.dataAvailable());
    pair.server.write([42]);
    foreach (attempt; 0 .. 500)
    {
        if (pair.client.dataAvailable())
            break;
        Thread.sleep(10.msecs);
    }
    assert(pair.client.dataAvailable());
    auto reply = new ubyte[4];
    assert(pair.client.read(reply) == 1 && reply[0] == 42);
    assert(!pair.client.dataAvailable());
}

// Server certificate verification: IP address, wrong name, untrusted CA, skipVerify, serverName
unittest
{
    import std.algorithm.searching : canFind;

    if (!haveOpenSsl())
        return;

    auto byIp = connectPair(trustingOptions(), "127.0.0.1");
    byIp.close();
    assert(byIp.clientError is null, byIp.clientError.msg);

    auto wrongName = trustingOptions();
    wrongName.serverName = "wrong.example";
    auto bad = connectPair(wrongName);
    bad.close();
    assert(cast(ConnectionException) bad.clientError !is null);
    assert(bad.clientError.msg.canFind("verification failed for wrong.example"), bad.clientError.msg);

    TlsOptions untrusted;
    untrusted.caFile = testFile("other-ca.pem");
    auto unknownCa = connectPair(untrusted);
    unknownCa.close();
    assert(cast(ConnectionException) unknownCa.clientError !is null);
    assert(unknownCa.clientError.msg.canFind("verification failed"), unknownCa.clientError.msg);

    untrusted.skipVerify = true;
    untrusted.serverName = "wrong.example";
    auto skipped = connectPair(untrusted);
    skipped.close();
    assert(skipped.clientError is null, skipped.clientError.msg);

    auto renamed = trustingOptions();
    renamed.serverName = "localhost";
    auto viaIp = connectPair(renamed, "127.0.0.1");
    viaIp.close();
    assert(viaIp.clientError is null, viaIp.clientError.msg);
}

// Client certificates (mutual TLS)
unittest
{
    if (!haveOpenSsl())
        return;
    auto withCert = trustingOptions();
    withCert.certFile = testFile("client.pem");
    withCert.keyFile = testFile("client.key");
    auto pair = connectPair(withCert, "localhost", serverContext(true));
    scope (exit)
        pair.close();
    assert(pair.clientError is null, pair.clientError.msg);
    assert(pair.serverError is null, pair.serverError.msg);
    pair.client.write([1, 2, 3]);
    auto got = new ubyte[3];
    readExactly(pair.server, got);
    assert(got == [1, 2, 3]);

    // Without a certificate the server rejects the client. With TLS 1.3 the client
    // finishes its handshake first and sees the rejection on its first read.
    auto without = connectPair(trustingOptions(), "localhost", serverContext(true));
    scope (exit)
        without.close();
    assert(without.serverError !is null);
    if (without.clientError is null)
    {
        bool rejected;
        try
            rejected = without.client.read(new ubyte[1]) == 0;
        catch (ConnectionException)
            rejected = true;
        assert(rejected);
    }
}

// close_notify and an abrupt close both end the peer's stream
unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    assert(pair.clientError is null && pair.serverError is null);
    // Consume the session tickets first: closing a socket with unread data makes
    // Windows reset the connection, which can discard the close_notify in transit
    Thread.sleep(100.msecs);
    assert(!pair.client.dataAvailable());
    pair.client.close();
    assert(!pair.client.connected);
    assert(pair.server.read(new ubyte[16]) == 0);
    pair.server.close();

    // Without close_notify the client sees the end of the stream, or a reset on Windows
    auto abrupt = connectPair(trustingOptions());
    assert(abrupt.clientError is null && abrupt.serverError is null);
    abrupt.server.raw.close();
    bool ended;
    try
        ended = abrupt.client.read(new ubyte[16]) == 0;
    catch (ConnectionException)
        ended = true;
    assert(ended);
    abrupt.close();
}

// A read sends what OpenSSL has queued, here a key update request. (OpenSSL sends
// the peer's reply with its next write.)
unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null && pair.serverError is null);

    void transfer(TlsTransport from, TlsTransport to, const(ubyte)[] data)
    {
        from.write(data);
        auto received = new ubyte[data.length];
        for (size_t got = 0; got < received.length;)
        {
            const n = to.read(received[got .. $]);
            assert(n > 0, "end of stream");
            got += n;
        }
        assert(received == data);
    }

    pair.server.requestKeyUpdate();
    transfer(pair.client, pair.server, [1, 2, 3]);
    assert(pair.server.readsThatSent > 0, "the read didn't send the key update request");
    // New keys in both directions: server to client since the request, client to server
    // since the reply, which goes with the client's next write
    transfer(pair.server, pair.client, [4, 5, 6, 7]);
    transfer(pair.client, pair.server, [8, 9]);
}

// One reader and one concurrent writer on each side, with key updates that make
// reads send data: the case of a cancel during a query. Whether a read or
// a write sends a key update depends on the timing, so only the data is checked.
unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null && pair.serverError is null);

    enum size_t downTotal = 4 * 1024 * 1024; // server -> client
    enum int messages = 3000; // client -> server, small writes
    size_t upTotal;
    foreach (m; 0 .. messages)
        upTotal += m % 64 + 1;

    auto serverWriter = new Thread({
        auto chunk = new ubyte[16 * 1024];
        for (size_t sent = 0, round = 0; sent < downTotal; round++)
        {
            foreach (i, ref b; chunk)
                b = patternByte(sent + i);
            pair.server.write(chunk);
            sent += chunk.length;
            if (round % 16 == 0)
                pair.server.requestKeyUpdate();
        }
    });
    auto serverReader = new Thread({
        auto buffer = new ubyte[4096];
        size_t got;
        while (got < upTotal)
        {
            const n = pair.server.read(buffer);
            assert(n > 0, "end of stream");
            foreach (i; 0 .. n)
                assert(buffer[i] == patternByte(got + i), "corrupted client data");
            got += n;
        }
    });
    auto clientWriter = new Thread({
        size_t offset;
        foreach (m; 0 .. messages)
        {
            auto message = new ubyte[m % 64 + 1];
            foreach (i, ref b; message)
                b = patternByte(offset + i);
            pair.client.write(message);
            offset += message.length;
        }
    });
    serverWriter.start();
    serverReader.start();
    clientWriter.start();

    auto buffer = new ubyte[10_000];
    size_t got;
    while (got < downTotal)
    {
        const n = pair.client.read(buffer);
        assert(n > 0, "end of stream");
        foreach (i; 0 .. n)
            assert(buffer[i] == patternByte(got + i), "corrupted server data");
        got += n;
    }
    // join rethrows a failure (exception or assertion) of the thread
    serverWriter.join();
    clientWriter.join();
    serverReader.join();
}

// On Windows, client contexts trust the certificates of the system store
version (Windows) @safe unittest
{
    if (!haveOpenSsl())
        return;
    auto context = new TlsContext(TlsOptions.init, false);
    assert(context.windowsRootCertificates > 0, "no certificates imported from the Windows ROOT store");
}

// The system trust store verifies a public server. Opt-in, as it needs the internet:
// CI sets DBWIRE_TLS_PUBLIC_HOST, e.g. to github.com:443
unittest
{
    import std.algorithm.searching : findSplit;
    import std.conv : to;
    import std.process : environment;

    const target = environment.get("DBWIRE_TLS_PUBLIC_HOST", "");
    if (target.length == 0 || !haveOpenSsl())
        return;
    auto hostPort = target.findSplit(":");
    const host = hostPort[0];
    const port = hostPort[2].length ? hostPort[2].to!ushort : cast(ushort) 443;
    auto backend = new PhobosBackend;
    auto raw = backend.connect(host, port, 10.seconds);
    TlsOptions options; // the system's trusted certificates
    auto tls = new TlsTransport(raw, backend, TlsContext.client(options), host, options, 10.seconds);
    scope (exit)
        tls.close();
    assert(tls.protocolVersion.length > 0);

    // The same server under a name its certificate doesn't cover is rejected
    options.serverName = "wrong.example";
    auto other = backend.connect(host, port, 10.seconds);
    bool rejected;
    try
        new TlsTransport(other, backend, TlsContext.client(options), host, options, 10.seconds).close();
    catch (ConnectionException e)
        rejected = true;
    assert(rejected, "a certificate for the wrong name was accepted");
}

// Contexts are cached per option set; a missing file is a ClientException
@safe unittest
{
    import std.exception : assertThrown;

    if (!haveOpenSsl())
        return;
    auto a = trustingOptions();
    auto b = trustingOptions();
    b.serverName = "other"; // per connection, same context
    assert(TlsContext.client(a) is TlsContext.client(b));
    b.skipVerify = true;
    assert(TlsContext.client(a) !is TlsContext.client(b));

    TlsOptions missing;
    missing.caFile = testFile("no-such-file.pem");
    assertThrown!ClientException(TlsContext.client(missing));
}
