# Changelog

All notable changes to dbwire are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Added

- `dbwire:types` (#57): `shortestDigits`, the shortest decimal digits that
  read back as a `float` or `double` (the closest ones on a tie), with the
  position of the decimal point. Moved from clickhoused's float text, where it
  was checked against about 765k server values; connectors keep their own
  notation. Moderate magnitudes don't allocate.

## 0.9.0 — 2026-11-08

The code review (#48–#50): robustness and security fixes, faster charset
conversions and fewer allocations, narrower `@trusted` code, and builds with
`-preview=dip1000`. See "Changed" for what can affect callers.

### Added

- `dbwire:client` (#48): `redactPassword(dsn)`, the connection string with
  its password replaced by `***`, for error messages and logs.

### Changed

- `dbwire:client` (#50): `parseEnumValue` matches the member names without
  `std.conv` and no longer catches; its attributes are inferred.
- `dbwire:io` (#48): `StringArena` can't be copied any more (`@disable
  this(this)`): a copy handed out the same memory again and overwrote strings
  already returned. Pass it by `ref`.
- `dbwire:io` (#48): `IoBackend.connect` and `TransportFactory` take
  `Duration.zero` or `Duration.max` for no time limit (zero used to fail at
  once). Longer timeouts than 50 years are cut to 50 years.
- `dbwire:crypto` (#48): `pbkdf2` throws `ClientException` for 0 iterations
  (an `assert` before; the count often comes from the server).

### Fixed

- `dbwire:types` (#50): builds with `-preview=dip1000` (the whole library now
  does, on current compilers; CI checks it). TZif data with non-ASCII time
  zone abbreviations is rejected as malformed (RFC 8536 allows only ASCII).
- `dbwire:io` (#50): error texts come from `strerror_r` (thread-safe) instead
  of `strerror`.
- `dbwire:client` (#50): `PoolCore.close` sets its flag atomically; other
  threads read it under their own locks.

- `dbwire:types` (#48): a TZif header with huge counts made
  `TzifTimeZone.parse` allocate gigabytes before it found the data truncated;
  more than 256 local time types are rejected.
- `dbwire:types` (#48): `Decimal.toDouble` is correctly rounded. It parsed
  the decimal text, which could be 1 ulp off.
- `dbwire:io` (#48): `PhobosBackend.connect` tries the next address (and
  `connectFirst` the next host) when a socket can't be created, e.g. for IPv6
  on a host without it.
- `dbwire:io` (#48): `VibeBackend.connect` lets an interrupted task's
  `InterruptException` through instead of trying the next host.
- `dbwire:client` (#48): `Dsn.parse` and `PoolOptions.fromDsn` no longer
  quote the password in error messages.
- `dbwire:client` (#48): `PoolOptions.waitTimeout = Duration.max` timed out at
  once (the deadline overflowed). A ping that fails with something other than
  a `DbException` (e.g. an interrupted task) closes the connection and
  reaches the caller, instead of being taken for a dead connection.
- `dbwire:tls` (#48): a `TlsContext` that fails to load its certificates,
  keys or CRLs frees its OpenSSL context. In fiber mode, error messages take
  OpenSSL's reasons before other connections on the thread can replace them.

### Performance

- `dbwire:charset` (#49): UTF-16 encoding and decoding, and the double-byte
  and UTF-8 code pages, write into an array of the exact (or largest) length
  instead of appending byte by byte: 10 to 13 times faster (decoding 70 MB of
  UTF-16: 3.8 s before, 0.3 s now).
- `dbwire:types` (#49): `Decimal.toString` formats into a stack buffer (one
  allocation instead of five); `toHash` doesn't allocate. `WideInt.toBigInt`
  and `fromBigInt` convert the words directly.
- `dbwire:tls` (#49): no allocation per flush; ciphertext goes through a
  reused buffer.
- `dbwire:client` (#49): `PoolCore.acquire` no longer creates a backend
  object per call, and returning connections doesn't reallocate the idle list.
- `dbwire:io` (#49): `readFixedBE` reads straight from the buffer when the
  bytes are there, `readExactBytes` doesn't zero the array first, and
  `PhobosTransport.dataAvailable`/`waitForData` reuse their `SocketSet`.

## 0.8.0 — 2026-11-07

### Added

- `dbwire:io` (#40): Unix-domain sockets. `connectUnixSocket(backend, path,
  timeout)` through the optional `UnixSocketBackend` interface, implemented
  by `PhobosBackend` (also Linux abstract sockets) and `VibeBackend` on POSIX
  systems; `peerUserId(transport)` (`PeerCredentials`: `SO_PEERCRED` on
  Linux, `getpeereid` on macOS and the BSDs) and `userName(uid)`, e.g. for
  PostgreSQL's `requirepeer`.
- `dbwire:tls` (#41): certificate revocation lists, `TlsOptions.crlFile` (a
  PEM file) and `TlsOptions.crlDir` (CRLs named `<hash>.r0`). When either is
  set, the server's whole certificate chain is checked, and a certificate
  whose issuer has no CRL fails verification (as libpq's `sslcrl`).

## 0.7.0 — 2026-11-06

### Added

- `dbwire:tls` (#32): `TlsTransport.peerCertificate`, the server's
  certificate in DER form (for SCRAM channel binding, `tls-server-end-point`).
- `dbwire:io` (#34): `WaitableTransport` (`waitForData(timeout)`,
  `canWaitForData`), implemented by the Phobos (`select`), vibe.d
  (`waitForDataEx`), TLS (only application data ends the wait) and mock
  transports; `dbwire.io.backend.waitForData(transport, timeout, backend)`
  falls back to polling with pauses in the backend's I/O mode.

### Changed

- `dbwire:types` (#33): `resolveTimeZone` reads the tz database's TZif files
  itself (`TzifTimeZone`, RFC 8536), with `PosixTimeZone` as the fallback:
  before a zone's first transition the offset is time type 0's (the local
  mean time, e.g. +05:41:16 for Asia/Kathmandu before 1920), and after the
  last transition the rules of the file's POSIX TZ footer apply (daylight
  saving time after 2037). `TZDIR` names another tz database (also on
  Windows).

## 0.6.0 — 2026-11-03

### Added

- `dbwire:tls` (#29): `TlsOptions.keyPassword` for encrypted private keys
  (`ENCRYPTED PRIVATE KEY`, e.g. in an Oracle `ewallet.pem`);
  `TlsOptions.skipNameCheck` verifies the certificate chain but not the
  server name, for clients that check the certificate otherwise;
  `TlsTransport.peerSubject` gives the server certificate's subject as
  RFC 2253 text.

## 0.5.1 — 2026-11-03

### Fixed

- `dbwire:crypto` on Windows with DMD: `randomBytes` failed to link
  (`BCryptGenRandom` unresolved) in applications using dbwire as a dependency.
  DMD splits library modules into one object per function, which loses the
  `pragma(lib, "bcrypt")` directive; the package now links `bcrypt` itself.

## 0.5.0 — 2026-11-02

### Added

- `dbwire:crypto` (#10), pure D, each part written from its specification and
  checked against its published test vectors:
  - `Aes` (FIPS-197): AES-128/192/256 block encryption and decryption;
    `cbcEncrypt`/`cbcDecrypt` (NIST SP 800-38A); `pkcs7Pad`/`pkcs7Unpad`.
    Byte-oriented and not constant-time: meant for login handshakes (Oracle's
    O5LOGON), not bulk encryption;
  - `pbkdf2!H` (RFC 8018) over HMAC with any Phobos digest, e.g. SHA-512 for
    Oracle 12c password keys;
  - `MD4` (RFC 1320) with Phobos' digest interface, for NTLM;
  - `randomBytes`: secure random bytes from the operating system
    (`getrandom`, `/dev/urandom`, `arc4random_buf`, `BCryptGenRandom`).

## 0.4.0 — 2026-11-02

### Added

- `dbwire:charset`: the double-byte code pages of SQL Server collations (#24):
  932 (Japanese), 936 (Simplified Chinese), 949 (Korean), 950 (Traditional
  Chinese). Decoding follows Windows' rules (an invalid pair gives the page's
  default character, a lead byte at the end is dropped); encoding writes the
  byte sequences Windows chooses, and only for characters that decode back.
  `CodePage.bytesOf` gives a character's one or two bytes; `isDoubleByte`.
  The tables were produced by SQL Server converting every byte pair and every
  character (`charset/tables/README.md`); they are read with string imports.

## 0.3.0 — 2026-11-02

### Added

- `dbwire:charset` (#11):
  - UTF-16 in either byte order: `encodeUtf16le`/`be`, `decodeUtf16le`/`be`.
    Decoding never fails: unpaired surrogates become U+FFFD; invalid UTF-8
    given to the encoders becomes U+FFFD too.
  - `CodePage`: the Windows code pages of SQL Server collations, 437, 850, 874
    and 1250 to 1258, plus UTF-8 (65001). `decode` never fails (undefined bytes
    map as Windows maps them, invalid UTF-8 becomes U+FFFD); `encode` throws
    `ClientException` for characters the page doesn't have, or substitutes a
    replacement byte. The tables were produced by SQL Server 2022 converting
    every byte through a column of each code page. Double-byte pages (932, 936,
    949, 950) come later.

## 0.2.0 — 2026-11-02

### Added

- TLS for protocols that run it inside their own messages, such as SQL
  Server's TDS 7.x (#9):
  - `TlsTransport` takes an optional `handshakeTransport`: the handshake goes
    through it (e.g. an adapter wrapping the records in PRELOGIN packets), the
    data afterwards through the raw transport;
  - `TlsTransport.detach()` ends TLS without a close_notify and returns the
    raw transport, for login-only encryption;
  - `TlsOptions.minVersion` and `maxVersion` (`TlsVersion.tls12`, `tls13`);
  - `TlsOptions.alpn` and `TlsTransport.alpnProtocol` (ALPN, e.g. `tds/8.0`).
  Checked against SQL Server 2022: PRELOGIN, then a TLS 1.2 handshake inside
  PRELOGIN packets.

## 0.1.1 — 2026-11-02

### Changed

- Faster when used from other packages (#20): the small hot methods of
  `BufferedReader`/`BufferedWriter` (`window`, `consume`, `readExactString`,
  `readExactBytes`, `reserve`, `commit`, `writeBytes`), `StringArena.take` and
  `resolveTimeZone` are now templates, so they are inlined into the calling
  package (LDC doesn't inline ordinary functions across separately compiled
  packages). Call syntax is unchanged. Found by clickhoused's benchmarks:
  decoding and encoding strings was about 5–8% slower than with its own buffer.

## 0.1.0 — 2026-11-02

First release: the building blocks extracted from clickhoused (`dbwire:types`,
`dbwire:io`, `dbwire:tls`, `dbwire:client`). `dbwire:crypto` and
`dbwire:charset` are still empty; they come with the SQL Server and Oracle
connectors.

### Added

- `dbwire:types` (#3):
  - exceptions: `DbException` and its subclasses `ClientException`,
    `ConnectionException`, `ProtocolException`;
  - `Int128`, `UInt128`, `Int256`, `UInt256` (from clickhoused);
  - `Decimal`: an exact decimal of up to 76 digits, from clickhoused, now with
    a signed scale (`-255` to `255`, for values such as Oracle `NUMBER`s with
    large exponents), `RoundingMode` (`towardZero`, `halfUp`, `halfEven`) for
    parsing, `fromDouble` and `rescaled`, an exact `fromDouble` (it rounds the
    binary value, not its 17-digit text), `toLong`, `fromLong`, `fromBigInt`,
    `precision` and `normalized`;
  - `MonthInterval`: intervals of years and months;
  - `resolveTimeZone`: time zones by name, cached per thread (from clickhoused).
- `dbwire:io` (#4), from clickhoused's I/O layer:
  - `Transport`, `TransportFactory`; `IoMode`, `IoBackend`, `IoLock`, `PoolSync`,
    `backendFor`, `inVibeTask`;
  - thread mode (`PhobosBackend`, `PhobosTransport`, `ThreadLock`,
    `ThreadPoolSync`) and fiber mode (`VibeBackend`, `VibeTransport`,
    `FiberLock`, `FiberPoolSync`; vibe-core 1.22+ and 2.x, optional);
  - `BufferedReader`/`BufferedWriter` without the ClickHouse encodings (they
    stay in clickhoused): raw bytes, little- and big-endian fixed-size values
    (`readFixedBE`/`writeFixedBE`, `fromBigEndian`/`toBigEndian` are new),
    strings of a known length (`readExactString`, `readExactBytes`), and buffer
    access for protocol decoders and encoders (`ensure`, `window`, `consume`,
    `reserve`, `commit`); `StringArena` is now public;
  - `MockTransport` for tests;
  - fiber-mode test runners `tests-vibe` (vibe-core 2.x) and `tests-vibe1`
    (vibe-core 1.22.6), run by CI.
  - fixed on the way: `VibeTransport.dataAvailable` lost received data on
    Windows (eventcore's WinAPI driver drops the data of an immediate read that
    completes at once); it now checks vibe's buffer and the socket without
    reading. clickhoused 0.6 and older have this bug in fiber mode on Windows.
- `dbwire:tls` (#5), from clickhoused: the run-time OpenSSL 1.1.1/3.x loader
  (`loadOpenSsl`, `openSslLibrary`), `TlsOptions`, `TlsContext` (cached client
  contexts, Windows ROOT store import) and `TlsTransport` (one decorator over
  memory BIOs for thread and fiber mode, concurrent reader and writer). New
  test certificates (`make-test-certs.sh`); the test switches are now
  `DBWIRE_REQUIRE_OPENSSL` and `DBWIRE_TLS_PUBLIC_HOST`. The vibe runners also
  check TLS in fiber mode against `DBWIRE_TLS_PUBLIC_HOST`.
- `dbwire:client` (#6), from clickhoused's connection options and pool,
  without the ClickHouse specifics:
  - `Dsn.parse`: URL-style connection strings (`scheme://user:password@h1:p1,h2/path?k=v`,
    percent-decoded, IPv6 in brackets), `parseQuery`, and the value parsers
    `parseSeconds`, `parseFlag`, `parseEnumValue`;
  - `HostPort`, `parseHostPort`, `HostSelection`, `orderHosts`, and
    `connectFirst`: the failover loop (network and protocol errors move on to
    the next host, other errors such as a rejected login stop);
  - `PoolCore`: the pool for thread mode (one shared set of connections) and
    fiber mode (one set per thread), with lazy expiry and health checks and no
    I/O under its lock, over connections implementing `Poolable`; `PoolLease`
    returns a connection when it goes out of scope; `PoolOptions` with
    `fromParams`/`fromDsn` (`pool_*` parameters). Unit tests with fake
    connections, and a fiber-mode test in the vibe runners.
- Repository scaffold (#2): the root package and the subpackages `dbwire:types`,
  `dbwire:io`, `dbwire:tls`, `dbwire:crypto`, `dbwire:charset` and
  `dbwire:client` (still empty), CI on Linux, Windows and macOS with DMD and
  LDC down to frontend 2.097, lint and documentation checks.
