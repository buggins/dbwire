/++
Run-time binding to the system OpenSSL library (1.1.1 or 3.x), used for TLS.

OpenSSL is not linked at build time. It is loaded with `dlopen` /
`LoadLibrary` when the first secure connection is made, or earlier with
`loadOpenSsl`. Builds that never use TLS never touch it. Only the few
functions that `dbwire.tls.transport` needs are declared; their signatures are
the same in OpenSSL 1.1.1 and 3.x.

The library names tried are, in order:
$(UL
    $(LI Linux and other POSIX systems: `libssl.so.3`, `libssl.so.1.1`, then
        the unversioned `libssl.so` (each with the matching libcrypto).)
    $(LI macOS: Homebrew's OpenSSL 3 (`/opt/homebrew/opt/openssl@3/lib`,
        `/usr/local/opt/openssl@3/lib`), then `libssl.3.dylib` on the library
        search path. The unversioned system `/usr/lib/libssl.dylib` is never
        loaded: macOS aborts processes that load it.)
    $(LI Windows: `libssl-3-x64.dll` (`libssl-3.dll` for 32-bit programs), then
        `libssl-1_1-x64.dll` (`libssl-1_1.dll`), found by the usual DLL search:
        the program's directory, the system directories, then `PATH`.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.tls.openssl;

import core.stdc.config : c_long, c_ulong;

import dbwire.exception : ClientException;

// Opaque OpenSSL types
package struct SslCtx;
package struct Ssl;
package struct SslMethod;
package struct Bio;
package struct BioMethod;
package struct X509;
package struct X509Store;
package struct X509VerifyParam;
package struct SslCipher;
package struct X509Name;
package struct OpenSslStack;

// Constants from the OpenSSL headers (identical in 1.1.1 and 3.x)
package enum : int
{
    sslErrorNone = 0,
    sslErrorSsl = 1,
    sslErrorWantRead = 2,
    sslErrorWantWrite = 3,
    sslErrorSyscall = 5,
    sslErrorZeroReturn = 6,
}

package enum : int
{
    sslVerifyNone = 0,
    sslVerifyPeer = 1,
    sslVerifyFailIfNoPeerCert = 2,
}

package enum int sslFiletypePem = 1;
package enum int sslCtrlSetTlsextHostname = 55; // SSL_set_tlsext_host_name is SSL_ctrl(55, 0, name)
package enum int tlsextNametypeHostName = 0;
package enum int sslCtrlSetMinProtoVersion = 123; // SSL_CTX_set_min_proto_version is SSL_CTX_ctrl(123, v)
package enum int sslCtrlSetMaxProtoVersion = 124; // SSL_CTX_set_max_proto_version is SSL_CTX_ctrl(124, v)
package enum int tls12Version = 0x0303;
package enum int tls13Version = 0x0304;
package enum int sslTlsextErrOk = 0;
package enum int sslTlsextErrNoAck = 3;
package enum int bioCtrlPending = 10; // BIO_pending is BIO_ctrl(10)
package enum c_long x509VOk = 0;
package enum int sslKeyUpdateRequested = 1;
package enum c_ulong x509VFlagCrlCheck = 0x4; // X509_V_FLAG_CRL_CHECK: the leaf certificate
package enum c_ulong x509VFlagCrlCheckAll = 0x8; // X509_V_FLAG_CRL_CHECK_ALL: the whole chain
/++
`X509_NAME_print_ex` flags: `XN_FLAG_RFC2253` (RFC 2253 escaping, comma
separators, last RDN first, short names, unknown fields dumped) without
`ASN1_STRFLGS_ESC_MSB`, so that non-ASCII text stays UTF-8.
+/
package enum c_ulong xnFlagRfc2253Utf8 = 0x0111_0313;

/// Name of the libssl function a field of `OpenSslApi` is bound to.
private struct LibSsl
{
    string name;
}

/// Name of the libcrypto function a field of `OpenSslApi` is bound to.
private struct LibCrypto
{
    string name;
}

/// The OpenSSL functions dbwire uses, resolved at run time.
package struct OpenSslApi
{
extern (C) nothrow @nogc:
    // libcrypto
    @LibCrypto("OpenSSL_version_num") c_ulong function() versionNum;
    @LibCrypto("OpenSSL_version") const(char)* function(int type) versionText;
    @LibCrypto("ERR_get_error") c_ulong function() errGetError;
    @LibCrypto("ERR_clear_error") void function() errClearError;
    @LibCrypto("ERR_error_string_n") void function(c_ulong e, char* buf, size_t len) errErrorStringN;
    @LibCrypto("BIO_s_mem") const(BioMethod)* function() bioSMem;
    @LibCrypto("BIO_new") Bio* function(const(BioMethod)* type) bioNew;
    @LibCrypto("BIO_free") int function(Bio* a) bioFree;
    @LibCrypto("BIO_read") int function(Bio* b, void* data, int dlen) bioRead;
    @LibCrypto("BIO_write") int function(Bio* b, const(void)* data, int dlen) bioWrite;
    @LibCrypto("BIO_ctrl") c_long function(Bio* bp, int cmd, c_long larg, void* parg) bioCtrl;
    @LibCrypto("X509_verify_cert_error_string") const(char)* function(c_long n) x509VerifyCertErrorString;
    @LibCrypto("X509_VERIFY_PARAM_set1_ip_asc")
    int function(X509VerifyParam* param, const(char)* ipasc) x509VerifyParamSet1IpAsc;
    @LibCrypto("d2i_X509") X509* function(X509** a, const(ubyte)** pp, c_long length) d2iX509;
    @LibCrypto("X509_free") void function(X509* a) x509Free;
    @LibCrypto("i2d_X509") int function(const(X509)* a, ubyte** output) i2dX509;
    @LibCrypto("X509_STORE_add_cert") int function(X509Store* ctx, X509* x) x509StoreAddCert;
    @LibCrypto("X509_STORE_load_locations")
    int function(X509Store* ctx, const(char)* file, const(char)* dir) x509StoreLoadLocations;
    @LibCrypto("X509_STORE_set_flags") int function(X509Store* ctx, c_ulong flags) x509StoreSetFlags;
    @LibCrypto("X509_get_subject_name") X509Name* function(const(X509)* x) x509GetSubjectName;
    @LibCrypto("X509_NAME_print_ex")
    int function(Bio* output, const(X509Name)* name, int indent, c_ulong flags) x509NamePrintEx;
    @LibCrypto("OPENSSL_sk_num") int function(const(OpenSslStack)* st) skNum;
    @LibCrypto("OPENSSL_sk_value") void* function(const(OpenSslStack)* st, int i) skValue;

    // libssl
    @LibSsl("TLS_client_method") const(SslMethod)* function() tlsClientMethod;
    @LibSsl("TLS_server_method") const(SslMethod)* function() tlsServerMethod;
    @LibSsl("SSL_CTX_new") SslCtx* function(const(SslMethod)* meth) sslCtxNew;
    @LibSsl("SSL_CTX_free") void function(SslCtx* ctx) sslCtxFree;
    @LibSsl("SSL_CTX_ctrl") c_long function(SslCtx* ctx, int cmd, c_long larg, void* parg) sslCtxCtrl;
    @LibSsl("SSL_CTX_set_verify") void function(SslCtx* ctx, int mode, void* callback) sslCtxSetVerify;
    @LibSsl("SSL_CTX_set_default_verify_paths") int function(SslCtx* ctx) sslCtxSetDefaultVerifyPaths;
    @LibSsl("SSL_CTX_load_verify_locations")
    int function(SslCtx* ctx, const(char)* caFile, const(char)* caPath) sslCtxLoadVerifyLocations;
    @LibSsl("SSL_CTX_use_certificate_chain_file")
    int function(SslCtx* ctx, const(char)* file) sslCtxUseCertificateChainFile;
    @LibSsl("SSL_CTX_use_PrivateKey_file")
    int function(SslCtx* ctx, const(char)* file, int type) sslCtxUsePrivateKeyFile;
    @LibSsl("SSL_CTX_check_private_key") int function(const(SslCtx)* ctx) sslCtxCheckPrivateKey;
    @LibSsl("SSL_CTX_set_default_passwd_cb_userdata")
    void function(SslCtx* ctx, void* userdata) sslCtxSetDefaultPasswdCbUserdata;
    // the peer certificate is the chain's first entry on the client side (SSL_get_peer_certificate
    // was renamed SSL_get1_peer_certificate in OpenSSL 3.0, and every symbol here must exist in both)
    @LibSsl("SSL_get_peer_cert_chain") OpenSslStack* function(const(Ssl)* s) sslGetPeerCertChain;
    @LibSsl("SSL_CTX_get_cert_store") X509Store* function(const(SslCtx)* ctx) sslCtxGetCertStore;
    @LibSsl("SSL_new") Ssl* function(SslCtx* ctx) sslNew;
    @LibSsl("SSL_free") void function(Ssl* ssl) sslFree;
    @LibSsl("SSL_set_bio") void function(Ssl* s, Bio* rbio, Bio* wbio) sslSetBio;
    @LibSsl("SSL_set_connect_state") void function(Ssl* s) sslSetConnectState;
    @LibSsl("SSL_set_accept_state") void function(Ssl* s) sslSetAcceptState;
    @LibSsl("SSL_do_handshake") int function(Ssl* s) sslDoHandshake;
    @LibSsl("SSL_read") int function(Ssl* ssl, void* buf, int num) sslRead;
    @LibSsl("SSL_write") int function(Ssl* ssl, const(void)* buf, int num) sslWrite;
    @LibSsl("SSL_pending") int function(const(Ssl)* s) sslPending;
    @LibSsl("SSL_get_error") int function(const(Ssl)* s, int retCode) sslGetError;
    @LibSsl("SSL_shutdown") int function(Ssl* s) sslShutdown;
    @LibSsl("SSL_ctrl") c_long function(Ssl* s, int cmd, c_long larg, void* parg) sslCtrl;
    @LibSsl("SSL_set1_host") int function(Ssl* s, const(char)* hostname) sslSet1Host;
    @LibSsl("SSL_get0_param") X509VerifyParam* function(Ssl* ssl) sslGet0Param;
    @LibSsl("SSL_get_verify_result") c_long function(const(Ssl)* ssl) sslGetVerifyResult;
    @LibSsl("SSL_get_version") const(char)* function(const(Ssl)* s) sslGetVersion;
    @LibSsl("SSL_get_current_cipher") const(SslCipher)* function(const(Ssl)* s) sslGetCurrentCipher;
    @LibSsl("SSL_CIPHER_get_name") const(char)* function(const(SslCipher)* c) sslCipherGetName;
    @LibSsl("SSL_key_update") int function(Ssl* s, int updatetype) sslKeyUpdate;
    // ALPN (OpenSSL 1.0.2+). Note: SSL_set_alpn_protos returns 0 on success.
    @LibSsl("SSL_set_alpn_protos") int function(Ssl* ssl, const(ubyte)* protos, uint protosLen) sslSetAlpnProtos;
    @LibSsl("SSL_get0_alpn_selected")
    void function(const(Ssl)* ssl, const(ubyte)** data, uint* len) sslGet0AlpnSelected;
    @LibSsl("SSL_CTX_set_alpn_select_cb")
    void function(SslCtx* ctx, AlpnSelectCallback cb, void* arg) sslCtxSetAlpnSelectCb;
}

/// Server-side ALPN selection callback (`SSL_CTX_alpn_select_cb_func`).
package alias AlpnSelectCallback = extern (C) int function(Ssl* ssl, const(ubyte)** output, ubyte* outputLength,
        const(ubyte)* input, uint inputLength, void* arg) nothrow @nogc;

/// A pair of library files to try together.
private struct Candidate
{
    string crypto;
    string ssl;
}

version (Windows)
{
    version (Win64)
        private immutable Candidate[] defaultCandidates = [
        Candidate("libcrypto-3-x64.dll", "libssl-3-x64.dll"),
        Candidate("libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll"),
    ];
    else
        private immutable Candidate[] defaultCandidates = [
        Candidate("libcrypto-3.dll", "libssl-3.dll"),
        Candidate("libcrypto-1_1.dll", "libssl-1_1.dll"),
    ];
}
else version (OSX)
{
    private enum homebrewArm = "/opt/homebrew/opt/openssl@3/lib/"; // Apple silicon
    private enum homebrewIntel = "/usr/local/opt/openssl@3/lib/";
    private immutable Candidate[] defaultCandidates = [
        Candidate(homebrewArm ~ "libcrypto.3.dylib", homebrewArm ~ "libssl.3.dylib"),
        Candidate(homebrewIntel ~ "libcrypto.3.dylib", homebrewIntel ~ "libssl.3.dylib"),
        Candidate("libcrypto.3.dylib", "libssl.3.dylib"),
    ];
}
else version (Posix)
{
    private immutable Candidate[] defaultCandidates = [
        Candidate("libcrypto.so.3", "libssl.so.3"),
        Candidate("libcrypto.so.1.1", "libssl.so.1.1"),
        Candidate("libcrypto.so", "libssl.so"),
    ];
}
else
    private immutable Candidate[] defaultCandidates = [];

/// Oldest supported OpenSSL version, as `OpenSSL_version_num()` reports it (1.1.1).
private enum c_ulong minimumVersion = 0x1010_1000;

private __gshared OpenSslApi loadedApi;
private __gshared bool apiLoaded;
private __gshared string loadedDescription;
private __gshared string loadedFile;

/++
Loads OpenSSL now, instead of on the first secure connection.

Call it at program start to fail early, or to load OpenSSL from specific
files. Without arguments the default library names are tried (see the module
description). Once OpenSSL is loaded, later calls do nothing.

Params:
    sslPath = path of the libssl library file; `null` to use the default names.
    cryptoPath = path of the matching libcrypto file. Needed with `sslPath`,
        because libssl is loaded after libcrypto.

Returns: the version of the loaded library, e.g. `"OpenSSL 3.0.13 30 Jan 2024"`.

Throws: `ClientException` if no usable OpenSSL (1.1.1 or newer) can be loaded.
The message lists every file that was tried and why it failed.
+/
string loadOpenSsl(string sslPath = null, string cryptoPath = null) @safe
{
    if (sslPath.length && !cryptoPath.length)
        throw new ClientException("loadOpenSsl: give the libcrypto path together with the libssl path");
    string load() @safe
    {
        if (!isLoaded())
        {
            const(Candidate)[] candidates = defaultCandidates;
            if (sslPath.length)
                candidates = [Candidate(cryptoPath, sslPath)];
            string description, file;
            auto api = loadFrom(candidates, description, file);
            setLoaded(api, description, file);
        }
        return loadedVersion();
    }

    return withLoaderLock(&load);
}

/++
The libssl file that was loaded (as it was passed to the system loader), or
`null` if OpenSSL has not been loaded yet. For diagnostics.
+/
string openSslLibrary() @safe
{
    string file() @trusted
    {
        return apiLoaded ? loadedFile : null; // written once, under the loader lock held here
    }

    return withLoaderLock(&file);
}

/// Runs `action` under the lock that guards loading (one `synchronized` statement, one mutex).
private string withLoaderLock(scope string delegate() @safe action) @safe
{
    synchronized
    {
        return action();
    }
}

/++
The loaded OpenSSL functions, loading the library first if needed.

Throws: `ClientException` if OpenSSL cannot be loaded.
+/
package const(OpenSslApi)* openSsl() @safe
{
    loadOpenSsl();
    return loadedApiPointer();
}

private bool isLoaded() @trusted nothrow
{
    return apiLoaded; // only called under the loader lock
}

private void setLoaded(OpenSslApi api, string description, string file) @trusted nothrow
{
    // only called under the loader lock
    loadedApi = api;
    loadedDescription = description;
    loadedFile = file;
    apiLoaded = true;
}

private string loadedVersion() @trusted nothrow
{
    return loadedDescription; // written once, before apiLoaded is set, under the same lock
}

private const(OpenSslApi)* loadedApiPointer() @trusted nothrow
{
    // The table is written once, under loadOpenSsl's lock, before any caller can get here;
    // loadOpenSsl took that lock in this thread too, so the writes are visible.
    return &loadedApi;
}

/// Tries each candidate in turn; returns the first fully bound one.
private OpenSslApi loadFrom(scope const Candidate[] candidates, out string description, out string file) @safe
{
    string errors;
    foreach (candidate; candidates)
    {
        OpenSslApi api;
        const error = tryLoad(candidate, api);
        if (error is null)
        {
            const ver = (() @trusted => api.versionNum())(); // a bound function without arguments
            if (ver >= minimumVersion)
            {
                description = (() @trusted => fromCString(api.versionText(0)))(); // OPENSSL_VERSION = 0
                file = candidate.ssl;
                return api;
            }
            errors ~= "\n  " ~ candidate.ssl ~ ": version " ~ hexVersion(ver) ~ " is older than 1.1.1";
            continue;
        }
        errors ~= "\n  " ~ error;
    }
    throw new ClientException(
            "TLS needs the OpenSSL library (1.1.1 or 3.x), which could not be loaded. Tried:"
            ~ (errors.length ? errors : " nothing (no default library names for this platform)")
            ~ "\nInstall OpenSSL, or call dbwire.tls.openssl.loadOpenSsl with the paths of libssl and libcrypto.");
}

/// Loads one libcrypto/libssl pair and binds every function. Returns null on success, else an error text.
private string tryLoad(scope const Candidate candidate, ref OpenSslApi api) @trusted
{
    // Library handles and symbol addresses come from the system loader; each address is cast
    // to the declared function pointer type of the field it is stored in.
    string error;
    void* crypto = openLibrary(candidate.crypto, error);
    if (crypto is null)
        return candidate.crypto ~ ": " ~ error;
    void* ssl = openLibrary(candidate.ssl, error);
    if (ssl is null)
    {
        closeLibrary(crypto);
        return candidate.ssl ~ ": " ~ error;
    }
    static foreach (member; __traits(allMembers, OpenSslApi))
    {
        {
            alias Field = typeof(__traits(getMember, api, member));
            static foreach (attr; __traits(getAttributes, __traits(getMember, OpenSslApi, member)))
            {
                static if (is(typeof(attr) == LibSsl))
                {
                    enum string symbol = attr.name;
                    void* library = ssl;
                    string file = candidate.ssl;
                }
                else static if (is(typeof(attr) == LibCrypto))
                {
                    enum string symbol = attr.name;
                    void* library = crypto;
                    string file = candidate.crypto;
                }
            }
            const address = findSymbol(library, symbol);
            if (address is null)
            {
                closeLibrary(ssl);
                closeLibrary(crypto);
                return file ~ ": function " ~ symbol ~ " not found (OpenSSL 1.1.1 or newer is needed)";
            }
            __traits(getMember, api, member) = cast(Field) address;
        }
    }
    return null;
}

version (Windows)
{
    import core.sys.windows.winbase : FreeLibrary, GetLastError, GetProcAddress, LoadLibraryW;
    import core.sys.windows.windef : HMODULE;

    private void* openLibrary(string name, out string error) @trusted
    {
        import std.utf : toUTF16z;
        import std.windows.syserror : sysErrorString;

        auto handle = LoadLibraryW(name.toUTF16z);
        if (handle is null)
            error = sysErrorString(GetLastError());
        return handle;
    }

    private void* findSymbol(void* library, string symbol) @system nothrow
    {
        import std.string : toStringz;

        return GetProcAddress(cast(HMODULE) library, symbol.toStringz);
    }

    private void closeLibrary(void* library) @system nothrow
    {
        FreeLibrary(cast(HMODULE) library);
    }
}
else version (Posix)
{
    import core.sys.posix.dlfcn : RTLD_NOW, dlclose, dlerror, dlopen, dlsym;

    private void* openLibrary(string name, out string error) @trusted
    {
        import std.string : toStringz;

        auto handle = dlopen(name.toStringz, RTLD_NOW);
        if (handle is null)
            error = fromCString(dlerror());
        return handle;
    }

    private void* findSymbol(void* library, string symbol) @system nothrow
    {
        import std.string : toStringz;

        return dlsym(library, symbol.toStringz);
    }

    private void closeLibrary(void* library) @system nothrow
    {
        dlclose(library);
    }
}
else
{
    private void* openLibrary(string, out string error) @safe
    {
        error = "loading libraries is not supported on this platform";
        return null;
    }

    private void* findSymbol(void*, string) @system nothrow
    {
        return null;
    }

    private void closeLibrary(void*) @system nothrow
    {
    }
}

/// Copies a C string; null gives an empty string.
package string fromCString(const(char)* s) @system nothrow
{
    import core.stdc.string : strlen;

    return s is null ? "" : s[0 .. strlen(s)].idup;
}

private string hexVersion(c_ulong v) @safe pure
{
    import std.format : format;

    return format!"0x%08x"(v);
}

@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectExceptionMsg;

    // A missing library is reported with its name, and the default names are not tried
    string description, file;
    const msg = collectExceptionMsg!ClientException(loadFrom([
        Candidate("/nonexistent/libcrypto-test.so", "/nonexistent/libssl-test.so")
    ], description, file));
    assert(msg.canFind("/nonexistent/libcrypto-test.so"), msg);
    assert(msg.canFind("loadOpenSsl"), msg);
}
