# Changelog

All notable changes to dbwire are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

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
