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
import dbwire.io.transport : Transport, WaitableTransport;

/// TLS protocol versions (`TlsOptions.minVersion`). TLS 1.0 and 1.1 are not supported.
enum TlsVersion
{
    /// TLS 1.2 (RFC 5246).
    tls12,
    /// TLS 1.3 (RFC 8446).
    tls13,
}

/// TLS settings for a connection.
struct TlsOptions
{
    /// PEM file with the certificate authorities to trust. Empty: the system's default store.
    string caFile;
    /// PEM file with the client certificate (and its chain), for mutual TLS.
    string certFile;
    /// PEM file with the client certificate's private key. Empty: taken from `certFile`.
    string keyFile;
    /// Password of an encrypted private key (`ENCRYPTED PRIVATE KEY`, e.g. in an Oracle wallet).
    string keyPassword;
    /++
    PEM file with certificate revocation lists (CRLs). When it or `crlDir` is
    set, every certificate of the server's chain is checked against the CRLs,
    and a certificate whose issuer has no CRL fails verification (OpenSSL's
    `-crl_check_all`, as libpq does). Ignored with `skipVerify`.
    +/
    string crlFile;
    /++
    Directory of CRLs, each in a PEM file named by its issuer's hash,
    `<hash>.r0` (`openssl rehash` names them so); looked up when needed.
    See `crlFile`.
    +/
    string crlDir;
    /// Don't verify the server certificate or its name. For development only.
    bool skipVerify;
    /++
    Verify the server's certificate chain but not its name. For clients that
    check the certificate otherwise, e.g. its subject (`TlsTransport.peerSubject`).
    +/
    bool skipNameCheck;
    /// Name to send (SNI) and verify instead of the host connected to, e.g. when
    /// connecting through an IP address, a tunnel or a proxy.
    string serverName;
    /// The lowest protocol version to accept.
    TlsVersion minVersion = TlsVersion.tls12;
    /// The highest protocol version to offer, e.g. TLS 1.2 for a handshake that
    /// runs inside protocol packets (see `TlsTransport`'s `handshakeTransport`).
    TlsVersion maxVersion = TlsVersion.tls13;
    /++
    Application protocols to offer with ALPN (RFC 7301), most preferred first,
    e.g. `["tds/8.0"]`; empty: no ALPN. `TlsTransport.alpnProtocol` tells which
    one the server selected.
    +/
    string[] alpn;
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
    private const(char)* keyPassword; // a zero-terminated copy, the password callback's user data
    /// Certificates added from the Windows "ROOT" system store (Windows only).
    package size_t windowsRootCertificates;

    private struct Key
    {
        string caFile;
        string certFile;
        string keyFile;
        string keyPassword;
        string crlFile;
        string crlDir;
        bool skipVerify;
        TlsVersion minVersion;
        TlsVersion maxVersion;
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
        const key = Key(options.caFile, options.certFile, options.keyFile, options.keyPassword, options.crlFile,
                options.crlDir, options.skipVerify, options.minVersion, options.maxVersion);
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

        if (options.minVersion > options.maxVersion)
            throw new ClientException("TlsOptions.minVersion is above maxVersion");
        api = openSsl();
        api.errClearError(); // so that the reasons below are this context's
        ctx = api.sslCtxNew(server ? api.tlsServerMethod() : api.tlsClientMethod());
        if (ctx is null)
            throw new ClientException("Cannot create a TLS context: " ~ errorQueueText(api));
        scope (failure)
        {
            api.sslCtxFree(ctx); // a failed context is never used, and nothing else refers to it
            ctx = null;
        }
        api.sslCtxCtrl(ctx, sslCtrlSetMinProtoVersion, protocolNumber(options.minVersion), null);
        api.sslCtxCtrl(ctx, sslCtrlSetMaxProtoVersion, protocolNumber(options.maxVersion), null);

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
            if (options.crlFile.length || options.crlDir.length)
            {
                auto store = api.sslCtxGetCertStore(ctx);
                check(api.x509StoreLoadLocations(store, options.crlFile.length ? options.crlFile.toStringz
                        : null,
                        options.crlDir.length ? options.crlDir.toStringz : null),
                        "Cannot load certificate revocation lists from "
                        ~ (options.crlFile.length ? options.crlFile : options.crlDir));
                check(api.x509StoreSetFlags(store, x509VFlagCrlCheck | x509VFlagCrlCheckAll),
                        "Cannot enable certificate revocation checks");
            }
            api.sslCtxSetVerify(ctx, server ? sslVerifyPeer | sslVerifyFailIfNoPeerCert : sslVerifyPeer, null);
        }
        else
            api.sslCtxSetVerify(ctx, sslVerifyNone, null);

        if (options.certFile.length)
        {
            const keyFile = options.keyFile.length ? options.keyFile : options.certFile;
            if (options.keyPassword.length)
            {
                // OpenSSL's default password callback returns its user data as the password
                keyPassword = options.keyPassword.toStringz;
                api.sslCtxSetDefaultPasswdCbUserdata(ctx, cast(void*) keyPassword);
            }
            check(api.sslCtxUseCertificateChainFile(ctx, options.certFile.toStringz),
                    "Cannot load the certificate " ~ options.certFile);
            check(api.sslCtxUsePrivateKeyFile(ctx, keyFile.toStringz, sslFiletypePem),
                    "Cannot load the private key " ~ keyFile);
            check(api.sslCtxCheckPrivateKey(ctx), "The private key " ~ keyFile ~ " does not match the certificate");
        }
    }

    private static int protocolNumber(TlsVersion v) @safe pure nothrow @nogc
    {
        return v == TlsVersion.tls13 ? tls13Version : tls12Version;
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

Two features serve protocols that run TLS inside their own messages, such as
SQL Server's TDS 7.x: the handshake can go through another transport than the
data (`handshakeTransport`, e.g. an adapter that wraps the handshake records
in the protocol's packets), and `detach` ends TLS while the connection goes on
unencrypted.
+/
final class TlsTransport : Transport, WaitableTransport
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
    private ubyte[] cipherOut; // ciphertext being sent; used only while holding writeLock
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
        options = TLS options; `serverName`, `skipVerify` and `alpn` are used
            here, the others by `TlsContext.client`.
        handshakeTimeout = receive and send timeout set on the transport of the
            handshake. The caller sets the normal timeouts afterwards.
        handshakeTransport = if not null, the transport the handshake goes
            through, e.g. an adapter over `raw` that wraps the records in the
            protocol's packets; the data that follows goes through `raw`.
            Records the peer sends after its last handshake message must not
            reach this transport: with TLS 1.3 a server sends session tickets
            right after the handshake, so protocols that frame the handshake
            (SQL Server's TDS 7.x) use TLS 1.2.

    Throws: `ConnectionException` if the handshake fails or the server
    certificate is not accepted.
    +/
    this(Transport raw, IoBackend backend, TlsContext context, string host, const TlsOptions options,
            Duration handshakeTimeout, Transport handshakeTransport = null) @safe
    {
        const name = options.serverName.length ? options.serverName : host;
        this(raw, backend, context, false, name, !options.skipVerify && !options.skipNameCheck, options.alpn,
                handshakeTimeout, handshakeTransport);
    }

    /// Accepts a TLS connection as the server (used by the unit tests).
    package static TlsTransport accept(Transport raw, IoBackend backend, TlsContext context,
            Duration handshakeTimeout, Transport handshakeTransport = null) @safe
    {
        return new TlsTransport(raw, backend, context, true, "the client", false, null, handshakeTimeout,
                handshakeTransport);
    }

    private this(Transport raw, IoBackend backend, TlsContext context, bool server, string name, bool verifyName,
            const string[] alpn, Duration handshakeTimeout, Transport handshakeTransport) @safe
    {
        auto via = handshakeTransport !is null ? handshakeTransport : raw;
        this.raw = via;
        api = context.api;
        peerName = name;
        sslLock = backend.newLock();
        writeLock = backend.newLock();
        input = new ubyte[17 * 1024]; // one maximum-size TLS record and its overhead
        plainBuffer = new ubyte[16 * 1024];
        scope (failure)
        {
            close();
            raw.close(); // when the handshake went through an adapter, close the transport too
        }
        failed = true; // until the handshake completes, close() must not send a close_notify
        createSsl(context, server, verifyName, alpn);
        via.setTimeouts(handshakeTimeout, handshakeTimeout);
        handshake();
        this.raw = raw;
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
                throw failure("TLS read failed", r.reasons);
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
            string reasons;
            if (!sslWrite(chunk, reasons))
                throw failure("TLS write failed", reasons);
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
                throw failure("TLS read failed", r.reasons);
        }
        return false;
    }

    /// Whether `waitForData` can wait: when the raw transport can.
    @property bool canWaitForData() @safe
    {
        auto waitable = cast(WaitableTransport) raw;
        return waitable !is null && waitable.canWaitForData;
    }

    /++
    Waits until application data can be read (or the stream ended), up to
    `timeout`: TLS records without application data (session tickets, key
    updates) are processed and don't end the wait.

    Throws: `ClientException` if the raw transport can't wait (see
    `canWaitForData`); `ConnectionException` on network or TLS errors.
    +/
    bool waitForData(Duration timeout) @safe
    {
        import core.time : MonoTime;
        import dbwire.exception : ClientException;

        if (dataAvailable())
            return true;
        auto waitable = cast(WaitableTransport) raw;
        if (waitable is null || !waitable.canWaitForData)
            throw new ClientException("The transport under the TLS stream can't wait for data");
        const forever = timeout == Duration.max;
        const deadline = forever ? MonoTime.max : MonoTime.currTime + timeout;
        for (;;)
        {
            const now = MonoTime.currTime;
            if (!forever && now >= deadline)
                return false;
            if (!waitable.waitForData(forever ? Duration.max : deadline - now))
                return false;
            if (dataAvailable())
                return true; // else only records without application data, or part of a record
        }
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

    /++
    Ends TLS without sending a close_notify and returns the raw transport, which
    stays open; this object is closed afterwards. For protocols that encrypt
    only part of a connection: SQL Server encrypts only its login packet when
    neither side asks for encryption.

    Call it after the last encrypted write and before reading anything the
    peer sends unencrypted, with no other call in progress.

    Throws: `ClientException` if decrypted or received data is still buffered
    (it would be lost); `ConnectionException` if the transport is closed.
    +/
    Transport detach() @safe
    {
        checkOpen();
        if (plain.length || sslPendingBytes() > 0 || receivedPending() > 0)
            throw new ClientException("Cannot end TLS: data received from " ~ peerName ~ " is not read yet");
        closed = true;
        freeSsl();
        return raw;
    }

    /// The application protocol the server selected with ALPN (see `TlsOptions.alpn`), or empty.
    @property string alpnProtocol() @trusted
    {
        // copies bytes owned by the live connection while holding its lock
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        if (ssl is null)
            return "";
        const(ubyte)* data;
        uint length;
        api.sslGet0AlpnSelected(ssl, &data, &length);
        return data is null ? "" : (cast(const(char)[]) data[0 .. length]).idup;
    }

    /++
    The subject of the server's certificate as RFC 2253 text, e.g.
    `CN=db.example.com,O=Example,C=US` (the most specific part first; non-ASCII
    text in UTF-8); null if the server sent no certificate.
    +/
    @property string peerSubject() @trusted
    {
        // the chain and its certificates are owned by the SSL object; the memory BIO is freed here
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        if (ssl is null)
            return null;
        auto chain = api.sslGetPeerCertChain(ssl);
        if (chain is null || api.skNum(chain) < 1)
            return null;
        auto certificate = cast(const(X509)*) api.skValue(chain, 0);
        auto bio = api.bioNew(api.bioSMem());
        if (bio is null)
            return null;
        scope (exit)
            api.bioFree(bio);
        if (api.x509NamePrintEx(bio, api.x509GetSubjectName(certificate), 0, xnFlagRfc2253Utf8) < 0)
            return null;
        const pending = api.bioCtrl(bio, bioCtrlPending, 0, null);
        auto text = new char[pending > 0 ? cast(size_t) pending : 0];
        const n = text.length ? api.bioRead(bio, text.ptr, cast(int) text.length) : 0;
        return n > 0 ? cast(string) text[0 .. n] : "";
    }

    /++
    The server's certificate (the leaf, not its chain) in DER form, e.g. for
    SCRAM channel binding (`tls-server-end-point`, RFC 5929), which hashes
    it; null if the server sent no certificate.
    +/
    @property immutable(ubyte)[] peerCertificate() @trusted
    {
        // the chain and its certificates are owned by the SSL object; i2d_X509 writes into our buffer
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        if (ssl is null)
            return null;
        auto chain = api.sslGetPeerCertChain(ssl);
        if (chain is null || api.skNum(chain) < 1)
            return null;
        auto certificate = cast(const(X509)*) api.skValue(chain, 0);
        const length = api.i2dX509(certificate, null);
        if (length <= 0)
            return null;
        auto der = new ubyte[length];
        ubyte* output = der.ptr;
        if (api.i2dX509(certificate, &output) != length)
            return null;
        return cast(immutable) der;
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

    private void createSsl(TlsContext context, bool server, bool verifyName, const string[] alpn) @trusted
    {
        // OpenSSL objects are created and connected here; the strings are zero-terminated
        // copies, and OpenSSL copies them in turn.
        import std.string : toStringz;

        api.errClearError(); // so that the reasons below are this connection's
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
        if (alpn.length)
        {
            // The ALPN list: each name as a length byte and its bytes; OpenSSL copies it
            ubyte[] protos;
            foreach (p; alpn)
            {
                if (p.length == 0 || p.length > 255)
                    throw new ClientException("Invalid ALPN protocol name '" ~ p ~ "'");
                protos ~= cast(ubyte) p.length;
                protos ~= cast(const(ubyte)[]) p;
            }
            if (api.sslSetAlpnProtos(ssl, protos.ptr, cast(uint) protos.length) != 0)
                throw new ConnectionException("Cannot set the ALPN protocols: " ~ errorQueueText(api));
        }
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
            const step = handshakeStep();
            flushOutput();
            if (step.error == sslErrorNone)
                return;
            if (step.error != sslErrorWantRead)
                throw failure("TLS handshake with " ~ peerName ~ " failed", step.reasons);
            if (!fill())
            {
                // a rejected certificate makes the peer close the connection
                auto e = failure("TLS handshake with " ~ peerName ~ " failed", null);
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

    /++
    OpenSSL's error queue belongs to the thread, and in fiber mode other
    connections on the thread use it as soon as this one yields (e.g. while
    sending). The steps below therefore take the reasons of a failure at once,
    while holding the lock.
    +/
    private static bool isFailure(int error) @safe pure nothrow @nogc
    {
        return error != sslErrorNone && error != sslErrorWantRead && error != sslErrorWantWrite
            && error != sslErrorZeroReturn;
    }

    /// Result of one `SSL_do_handshake`.
    private static struct StepResult
    {
        int error; /// `sslErrorNone` once the handshake is complete, else the SSL error code
        string reasons; /// OpenSSL's reasons when it failed
    }

    /// Advances the handshake.
    private StepResult handshakeStep() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        const r = api.sslDoHandshake(ssl);
        StepResult step;
        step.error = r == 1 ? sslErrorNone : api.sslGetError(ssl, r);
        if (isFailure(step.error))
            step.reasons = errorQueueText(api);
        return step;
    }

    /// Result of one `SSL_read`.
    private static struct ReadResult
    {
        int bytes; /// decrypted bytes, or <= 0
        int error; /// SSL error code when `bytes <= 0`
        bool outputPending; /// OpenSSL produced data to send (e.g. a queued key update)
        string reasons; /// OpenSSL's reasons when it failed
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
        if (isFailure(r.error))
            r.reasons = errorQueueText(api);
        r.outputPending = api.bioCtrl(wbio, bioCtrlPending, 0, null) > 0;
        return r;
    }

    private bool sslWrite(scope const(ubyte)[] data, out string reasons) @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        api.errClearError();
        // With a memory BIO for output, SSL_write consumes all of data or fails. Lengths
        // beyond int (never from write's chunks) are cut, which reports a failure.
        const length = data.length > int.max ? int.max : cast(int) data.length;
        if (api.sslWrite(ssl, data.ptr, length) == data.length)
            return true;
        reasons = errorQueueText(api);
        return false;
    }

    /// Bytes received from the peer and not decrypted yet (in the input BIO).
    private c_long receivedPending() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        return api.bioCtrl(rbio, bioCtrlPending, 0, null);
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
        // A memory BIO accepts all the data. Lengths beyond int (never from fill's
        // buffer) are cut, which reports a failure.
        const length = data.length > int.max ? int.max : cast(int) data.length;
        if (api.bioWrite(rbio, data.ptr, length) != data.length)
            throw new ConnectionException("TLS buffer write failed");
    }

    /// The ciphertext OpenSSL has produced, in `cipherOut`, which grows to the largest
    /// amount seen. The caller holds `writeLock` and sends it before the next call.
    private ubyte[] takeOutput() @trusted
    {
        sslLock.lock();
        scope (exit)
            sslLock.unlock();
        checkSsl();
        const pending = api.bioCtrl(wbio, bioCtrlPending, 0, null);
        if (pending <= 0)
            return null;
        if (cipherOut.length < pending)
            cipherOut = new ubyte[cast(size_t) pending];
        // reads at most `pending` bytes, which fit in cipherOut
        const n = api.bioRead(wbio, cipherOut.ptr, cast(int) pending);
        return n > 0 ? cipherOut[0 .. n] : null;
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

    /// An exception for a failed OpenSSL call, with `reasons` from OpenSSL's error queue.
    private ConnectionException failure(string what, string reasons) @trusted
    {
        // reads the verification result of a live connection
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
    import core.time : MonoTime, msecs, seconds;
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

// The DER bytes of the first certificate in a PEM file.
version (unittest) private immutable(ubyte)[] pemCertificate(string file)
{
    import std.algorithm.searching : findSplit;
    import std.base64 : Base64;
    import std.file : readText;
    import std.string : lineSplitter, strip;

    const text = readText(file).findSplit("-----BEGIN CERTIFICATE-----")[2].findSplit("-----END CERTIFICATE-----")[0];
    string base64;
    foreach (line; text.lineSplitter)
        base64 ~= line.strip;
    return Base64.decode(base64).idup;
}

// The server certificate's subject; chain verification without the name check
unittest
{
    import std.algorithm.searching : canFind;

    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null, pair.clientError.msg);
    assert(pair.client.peerSubject == "CN=localhost", pair.client.peerSubject);
    // the certificate in DER form: the server.pem certificate decoded
    assert(pair.client.peerCertificate == pemCertificate(testFile("server.pem")), "peerCertificate");

    auto wrongName = trustingOptions();
    wrongName.serverName = "wrong.example";
    wrongName.skipNameCheck = true; // the chain is still verified
    auto renamed = connectPair(wrongName);
    renamed.close();
    assert(renamed.clientError is null, renamed.clientError.msg);

    TlsOptions untrusted;
    untrusted.caFile = testFile("other-ca.pem");
    untrusted.skipNameCheck = true;
    auto unknownCa = connectPair(untrusted);
    unknownCa.close();
    assert(cast(ConnectionException) unknownCa.clientError !is null);
    assert(unknownCa.clientError.msg.canFind("verification failed"), unknownCa.clientError.msg);
}

// Certificate revocation lists: from a file or a hashed directory, for the whole chain
unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    if (!haveOpenSsl())
        return;
    TlsContext crlServer(string name)
    {
        TlsOptions options;
        options.certFile = testFile(name ~ ".pem");
        options.keyFile = testFile(name ~ ".key");
        return new TlsContext(options, true);
    }

    TlsOptions fromFile;
    fromFile.caFile = testFile("crl-ca.pem");
    fromFile.crlFile = testFile("crl.pem");
    TlsOptions fromDir;
    fromDir.caFile = testFile("crl-ca.pem");
    fromDir.crlDir = testFile("crls");
    foreach (options; [fromFile, fromDir])
    {
        auto good = connectPair(options, "localhost", crlServer("crl-good"));
        good.close();
        assert(good.clientError is null, good.clientError.msg);

        auto revoked = connectPair(options, "localhost", crlServer("crl-revoked"));
        revoked.close();
        assert(cast(ConnectionException) revoked.clientError !is null);
        assert(revoked.clientError.msg.canFind("certificate revoked"), revoked.clientError.msg);

        // without revocation checks the revoked certificate passes
        TlsOptions unchecked;
        unchecked.caFile = options.caFile;
        auto passes = connectPair(unchecked, "localhost", crlServer("crl-revoked"));
        passes.close();
        assert(passes.clientError is null, passes.clientError.msg);
    }

    // a chain whose issuer has no CRL fails, as with -crl_check_all
    auto noCrl = trustingOptions();
    noCrl.crlFile = testFile("crl.pem");
    auto missing = connectPair(noCrl);
    missing.close();
    assert(cast(ConnectionException) missing.clientError !is null);
    assert(missing.clientError.msg.canFind("CRL"), missing.clientError.msg);

    // skipVerify ignores the CRLs
    TlsOptions skipped;
    skipped.skipVerify = true;
    skipped.crlFile = testFile("crl.pem");
    auto ignored = connectPair(skipped, "localhost", crlServer("crl-revoked"));
    ignored.close();
    assert(ignored.clientError is null, ignored.clientError.msg);

    // an unreadable CRL file fails when the context is created
    TlsOptions unreadable;
    unreadable.caFile = testFile("crl-ca.pem");
    unreadable.crlFile = testFile("no-such-crl.pem");
    auto e = collectException!ClientException(TlsContext.client(unreadable));
    assert(e !is null && e.msg.canFind("no-such-crl.pem"), e is null ? "no exception" : e.msg);
}

// An encrypted private key with its password
unittest
{
    import std.exception : assertThrown;

    if (!haveOpenSsl())
        return;
    auto options = trustingOptions();
    options.certFile = testFile("client.pem");
    options.keyFile = testFile("client-encrypted.key");
    options.keyPassword = "dbwire-test";
    auto pair = connectPair(options, "localhost", serverContext(true));
    scope (exit)
        pair.close();
    assert(pair.clientError is null, pair.clientError.msg);
    assert(pair.serverError is null, pair.serverError.msg);

    options.keyPassword = "wrong";
    assertThrown!ClientException(new TlsContext(options, false), "a wrong key password");
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

// waitForData: a timeout when only records without application data arrive (TLS 1.3 session
// tickets after the handshake), then data written by the server from another thread
unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;

    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null, pair.clientError.msg);
    assert(pair.client.canWaitForData);
    const start = MonoTime.currTime;
    assert(!pair.client.waitForData(150.msecs), "no application data yet");
    assert(MonoTime.currTime - start >= 140.msecs, "waited for the timeout");
    auto writer = new Thread({ Thread.sleep(50.msecs); pair.server.write([5]); });
    writer.start();
    assert(pair.client.waitForData(5.seconds), "data arrived");
    writer.join();
    ubyte[1] received;
    assert(pair.client.read(received[]) == 1 && received[0] == 5);
    assert(!pair.client.waitForData(10.msecs), "nothing more");
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

version (unittest)
{
    /++
    A test stand-in for protocol packets around TLS records (as SQL Server's
    PRELOGIN packets): every write becomes a frame with a 4-byte big-endian
    length; reads return the frames' contents.
    +/
    private final class FramingTransport : Transport
    {
        Transport inner;
        size_t framesWritten;
        size_t framesRead;
        private ubyte[] pending;

        this(Transport inner) @safe
        {
            this.inner = inner;
        }

        override size_t read(scope ubyte[] buffer) @safe
        {
            if (pending.length == 0)
            {
                ubyte[4] header;
                if (!readAll(header[]))
                    return 0;
                const length = (cast(size_t) header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
                pending = new ubyte[length];
                if (!readAll(pending))
                    return 0;
                framesRead++;
            }
            const n = buffer.length < pending.length ? buffer.length : pending.length;
            buffer[0 .. n] = pending[0 .. n];
            pending = pending[n .. $];
            return n;
        }

        override void write(scope const(ubyte)[] data) @safe
        {
            const length = data.length;
            const ubyte[4] header = [
                cast(ubyte)(length >> 24), cast(ubyte)(length >> 16), cast(ubyte)(length >> 8),
                cast(ubyte) length
            ];
            inner.write(header[] ~ data);
            framesWritten++;
        }

        override bool dataAvailable() @safe
        {
            return pending.length > 0 || inner.dataAvailable();
        }

        override void close() @safe nothrow
        {
            inner.close();
        }

        override bool connected() const @safe nothrow
        {
            return inner.connected;
        }

        override void setTimeouts(Duration receive, Duration send) @safe
        {
            inner.setTimeouts(receive, send);
        }

        private bool readAll(scope ubyte[] buffer) @safe
        {
            size_t got;
            while (got < buffer.length)
            {
                const n = inner.read(buffer[got .. $]);
                if (n == 0)
                    return false;
                got += n;
            }
            return true;
        }
    }

    /// A TLS pair whose handshakes go through `FramingTransport`s; the data afterwards goes directly.
    private struct FramedPair
    {
        TlsPair tls;
        FramingTransport clientFraming;
        FramingTransport serverFraming;
    }

    private FramedPair connectFramedPair() @system
    {
        // TLS 1.2, as SQL Server's TDS 7.x handshakes: a TLS 1.3 server sends its session
        // tickets right after the handshake, still through the adapter
        auto server = serverContext(false);
        server.api.sslCtxCtrl(server.ctx, sslCtrlSetMaxProtoVersion, tls12Version, null);
        auto listener = new TcpSocket;
        scope (exit)
            listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(1);
        const port = (cast(InternetAddress) listener.localAddress).port;

        FramedPair pair;
        auto backend = new PhobosBackend;
        auto serverThread = new Thread({
            try
            {
                auto raw = new PhobosTransport(listener.accept());
                pair.serverFraming = new FramingTransport(raw);
                pair.tls.server = TlsTransport.accept(raw, backend, server, 10.seconds, pair.serverFraming);
                pair.tls.server.setTimeouts(10.seconds, 10.seconds);
            }
            catch (Exception e)
                pair.tls.serverError = e;
        });
        serverThread.start();
        try
        {
            auto raw = backend.connect("127.0.0.1", port, 10.seconds);
            pair.clientFraming = new FramingTransport(raw);
            const options = trustingOptions();
            pair.tls.client = new TlsTransport(raw, backend, new TlsContext(options, false), "localhost", options,
                    10.seconds, pair.clientFraming);
            pair.tls.client.setTimeouts(10.seconds, 10.seconds);
        }
        catch (Exception e)
            pair.tls.clientError = e;
        serverThread.join();
        return pair;
    }

    /// Server-side ALPN for the tests: selects "tds/8.0" when the client offers it.
    private extern (C) int selectTds(Ssl* ssl, const(ubyte)** output, ubyte* outputLength, const(ubyte)* input,
            uint inputLength, void* arg) nothrow @nogc @system
    {
        static immutable ubyte[7] wanted = cast(immutable(ubyte)[7]) "tds/8.0";
        uint pos;
        while (pos < inputLength)
        {
            const length = input[pos];
            const fits = pos + 1 + length <= inputLength;
            if (length == wanted.length && fits && input[pos + 1 .. pos + 1 + length] == wanted[])
            {
                *output = input + pos + 1;
                *outputLength = length;
                return sslTlsextErrOk;
            }
            pos += 1 + length;
        }
        return sslTlsextErrNoAck;
    }
}

// The handshake goes through an adapter (as inside SQL Server's PRELOGIN packets),
// the data afterwards directly over the raw transport
@system unittest
{
    if (!haveOpenSsl())
        return;
    auto pair = connectFramedPair();
    scope (exit)
        pair.tls.close();
    assert(pair.tls.clientError is null && pair.tls.serverError is null);
    assert(pair.clientFraming.framesWritten > 0 && pair.serverFraming.framesWritten > 0);
    const clientFrames = pair.clientFraming.framesWritten;
    const serverFrames = pair.serverFraming.framesWritten;

    pair.tls.client.write(cast(const(ubyte)[]) "hello");
    auto got = new ubyte[5];
    readExactly(pair.tls.server, got);
    assert(got == "hello");
    pair.tls.server.write(cast(const(ubyte)[]) "world!");
    got = new ubyte[6];
    readExactly(pair.tls.client, got);
    assert(got == "world!");
    // no more frames: the records went directly over the sockets
    assert(pair.clientFraming.framesWritten == clientFrames && pair.serverFraming.framesWritten == serverFrames);
}

// detach: TLS ends, the connection goes on unencrypted (SQL Server's login-only encryption)
@system unittest
{
    import std.exception : assertThrown;

    if (!haveOpenSsl())
        return;
    auto pair = connectFramedPair();
    assert(pair.tls.clientError is null && pair.tls.serverError is null);

    pair.tls.client.write(cast(const(ubyte)[]) "login");
    auto got = new ubyte[5];
    readExactly(pair.tls.server, got);
    assert(got == "login");
    auto clientRaw = pair.tls.client.detach();
    auto serverRaw = pair.tls.server.detach();
    scope (exit)
    {
        clientRaw.close();
        serverRaw.close();
    }
    assert(!pair.tls.client.connected && clientRaw.connected);
    assertThrown!ConnectionException(pair.tls.client.write([1]));
    pair.tls.client.close(); // does nothing now: the raw transport stays open
    assert(clientRaw.connected);

    serverRaw.write(cast(const(ubyte)[]) "plain answer");
    got = new ubyte[12];
    readExactly(clientRaw, got);
    assert(got == "plain answer"); // unencrypted bytes on the socket
}

// detach refuses while received data would be lost
@system unittest
{
    import std.exception : assertThrown;

    if (!haveOpenSsl())
        return;
    auto pair = connectPair(trustingOptions());
    scope (exit)
        pair.close();
    assert(pair.clientError is null && pair.serverError is null);
    pair.server.write(cast(const(ubyte)[]) "unread");
    const deadline = MonoTime.currTime + 10.seconds;
    while (!pair.client.dataAvailable && MonoTime.currTime < deadline)
        Thread.sleep(1.msecs);
    assertThrown!ClientException(pair.client.detach());
    auto got = new ubyte[6];
    readExactly(pair.client, got); // still usable
    assert(got == "unread");
}

// ALPN
@system unittest
{
    import std.exception : assertThrown;

    if (!haveOpenSsl())
        return;
    auto server = serverContext(false);
    server.api.sslCtxSetAlpnSelectCb(server.ctx, &selectTds, null);

    auto options = trustingOptions();
    options.alpn = ["h2", "tds/8.0"];
    auto pair = connectPair(options, "localhost", server);
    assert(pair.clientError is null && pair.serverError is null);
    assert(pair.client.alpnProtocol == "tds/8.0" && pair.server.alpnProtocol == "tds/8.0");
    pair.close();

    pair = connectPair(trustingOptions(), "localhost", server); // no ALPN offered
    assert(pair.clientError is null && pair.client.alpnProtocol == "");
    pair.close();

    options.alpn = [""];
    pair = connectPair(options, "localhost", server);
    assert(cast(ClientException) pair.clientError !is null);
    pair.close();
}

// The minimum protocol version
@system unittest
{
    if (!haveOpenSsl())
        return;
    auto options = trustingOptions();
    options.minVersion = TlsVersion.tls13;
    auto pair = connectPair(options);
    assert(pair.clientError is null && pair.client.protocolVersion == "TLSv1.3");
    pair.close();

    auto tls12Only = serverContext(false);
    tls12Only.api.sslCtxCtrl(tls12Only.ctx, sslCtrlSetMaxProtoVersion, tls12Version, null);
    pair = connectPair(options, "localhost", tls12Only);
    assert(cast(ConnectionException) pair.clientError !is null, "a TLS 1.2 server was accepted");
    pair.close();

    pair = connectPair(trustingOptions(), "localhost", tls12Only); // the default minimum is TLS 1.2
    assert(pair.clientError is null && pair.client.protocolVersion == "TLSv1.2");
    pair.close();

    // A client capped at TLS 1.2 gets TLS 1.2 from a server that offers 1.3
    auto capped = trustingOptions();
    capped.maxVersion = TlsVersion.tls12;
    pair = connectPair(capped);
    assert(pair.clientError is null && pair.client.protocolVersion == "TLSv1.2");
    pair.close();

    import std.exception : assertThrown;

    capped.minVersion = TlsVersion.tls13;
    assertThrown!ClientException(new TlsContext(capped, false));
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
    import std.exception : assertThrown;
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
    assertThrown!ConnectionException(new TlsTransport(other, backend, TlsContext.client(options), host, options,
            10.seconds).close(), "a certificate for the wrong name was accepted");
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
