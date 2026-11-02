# Changelog

All notable changes to dbwire are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

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
- Repository scaffold (#2): the root package and the subpackages `dbwire:types`,
  `dbwire:io`, `dbwire:tls`, `dbwire:crypto`, `dbwire:charset` and
  `dbwire:client` (still empty), CI on Linux, Windows and macOS with DMD and
  LDC down to frontend 2.097, lint and documentation checks.
