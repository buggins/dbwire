# AGENTS.md

Guidance for AI coding agents working on **dbwire**, the shared building blocks for native D database connectors.

## Project at a glance

- **What:** value types, transports (threads and vibe.d fibers), TLS, cryptography, character sets and connection plumbing shared by native D database connectors. Users:
  - **clickhoused** (`../clickhoused`): the native ClickHouse client; dbwire is extracted from it.
  - the planned **SQL Server** and **Oracle** connectors (`../mssql-native`, `../oracle-native`; final names still open);
  - **ddbc** and **hibernated**, through `dbwire:types` (e.g. `ResultSet.getDecimal`).
- **Repo:** `git@github.com:buggins/dbwire.git`, default branch `main`. Author Vadim Lopatin (GitHub `buggins`). dub package `dbwire`.
- **License:** BSL-1.0.
- **Status:** under development; roadmap issue #13 lists the stages W0–W8 (one issue each).
- **`PLAN.md` (local and optional):** the design plan is a local, untracked file, excluded through `.git/info/exclude`. If present, read it before design-level changes and keep it up to date; never `git add` it. If absent, this file and the issues are the reference.

## Workflow

- **Every change goes through an issue and a pull request. Never push to `main` directly.** One feature branch per issue; the PR says `Closes #N`, the commit message mentions the issue. The author merges.
- Commit, push and open PRs only when the user asks. Releases and tags only on request: update the version constants in `source/dbwire/package.d` and `CHANGELOG.md`; the author pushes the `vX.Y.Z` tag.

## Key design rules

1. **Pure D, zero C dependencies by default.** C libraries only as optional extras **loaded at run time** with our own minimal declarations (OpenSSL today; GSSAPI/SSPI later). A missing library fails only the feature that needs it, with a clear `ClientException`.
2. **Dual I/O.** Anything that can block (connect/DNS, socket I/O, timeouts, locks, sleep) goes through `IoBackend`/`Transport` (`dbwire:io`). Never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs from code meant for connectors. vibe-core is an **optional** dependency of `dbwire:io` only; vibe code sits under `version (Have_vibe_core)` (dub defines it when vibe-core is anywhere in the application's dependency graph). `IoMode.auto_` selects vibe only inside a vibe task.
3. **Runtime interfaces, not templates**, for anything a connector's `Connection` holds (transports, locks, pool hooks): the connectors keep one non-templated `Connection` class each, which ddbc needs.
4. **`dbwire:types` has no dependencies at all.** ddbc's core depends on it.
5. **Robust decoding:** malformed or truncated input throws, never crashes, never allocates from an unchecked length.
6. **No protocol code here.** Packet formats, column/row codecs, type mappings, compression and connector-specific connection-string formats stay in the connectors. No query API (that is ddbc).
7. **Performance:** clickhoused's benchmark suite (`dub run :bench -b release` in `../clickhoused`) must not regress when code moves here.

## Licensing rules (important)

dbwire must remain pure BSL-1.0 code written for this project.

- **Other database clients, drivers and libraries are reference only. Never copy or translate their code** (line-by-line translation counts as copying), whatever their license. Wire-format facts are fine to reproduce. For SQL Server, don't use FreeTDS or jTDS at all (LGPL).
- **Algorithms are written from their specifications** (FIPS-197, RFC 8018, RFC 1320, ...), with the specification's known-answer test vectors.
- If any third-party code or data ever seems necessary, **stop and ask the user first**.
- Crypto (`crypto/`): every algorithm is written from its specification (FIPS-197, SP 800-38A, RFC 8018, RFC 1320) and tested with the published vectors; extra reference values come from OpenSSL's command line and Python's `hashlib`, never from another library's code. AES is byte-oriented and not constant-time (login handshakes only); bulk encryption should go through OpenSSL when it exists.
- Code page tables (`charset/source/dbwire/charset/tables.d`, and the double-byte ones in `charset/tables/*.bin`, see its README) are produced by SQL Server itself (each byte stored in a `varchar(1)` column of a collation with that code page, then converted to `nvarchar`), i.e. Windows' own conversion; approved by the author. Add new pages the same way.

## Layout

```
dub.json                    root package "dbwire": source/dbwire/package.d (public imports, version constants);
                            depends on every subpackage; buildType "docs"
types/   dbwire:types       source/dbwire/exception.d, source/dbwire/types/{decimal,wideint,interval,timezone}.d
                                                                                    no dependencies
io/      dbwire:io          source/dbwire/io/{transport,backend,phobos,vibecore,buffer,mock}.d
                                                                                    types, vibe-core (optional)
tls/     dbwire:tls         source/dbwire/tls/{openssl,transport}.d, testdata/ (certificates, make-test-certs.sh)
                                                                                    io; libs-windows: crypt32
crypto/  dbwire:crypto      source/dbwire/crypto/                                   types
charset/ dbwire:charset     source/dbwire/charset/                                  types
client/  dbwire:client      source/dbwire/client/{dsn,hosts,pool}.d                 io
tests-vibe/                 fiber-mode tests (vibe-core 2.x): a standalone package, run with --root
tests-vibe1/                the same sources against vibe-core 1.22.6
```

Notes on `dbwire:client`:
- Connectors keep their own options types and typed wrappers; dbwire has no `ConnectionOptions`, `ConnectionPool` or `PooledConnection` (those names stay with the connectors, e.g. clickhoused). A connector's `Connection` implements `Poolable` (`isOpen`, `isBusy`, `ping`, `close`); its pool wraps `PoolCore` and its pooled handle wraps a `PoolLease` (non-copyable: move it into the wrapper).
- dscanner treats reading a property as "never modified" but a call with parentheses as a use: write `lease.connection()` in tests where a lease would otherwise be flagged, or use a temporary (`pool.acquire();` returns the connection at once).

Notes on `dbwire:tls`:
- OpenSSL is loaded at run time (`dbwire.tls.openssl`, our own declarations of the few functions used); `TlsContext.client` fails with a `ClientException` when it can't be loaded or a certificate file is unusable, handshake and verification failures are `ConnectionException`s.
- Server-side TLS (`TlsTransport.accept`, server contexts) is `package`: only the unit tests use it.
- Test switches: `DBWIRE_REQUIRE_OPENSSL=1` turns "OpenSSL not found" from a skip into a failure; `DBWIRE_TLS_PUBLIC_HOST=github.com:443` verifies a public server with the system trust store (unit tests and the vibe runners; needs the internet). CI sets both on every OS.
- Trusted CAs without `caFile`: OpenSSL's default paths, plus the Windows `ROOT` store imported through crypt32. macOS needs Homebrew's `openssl@3` (the system LibreSSL is not used). On Windows, closing a socket with unread data resets the connection, which can discard data in transit (a close_notify included).
- Protocols that frame the TLS handshake (SQL Server TDS 7.x: records inside PRELOGIN packets, type 0x12, with 8-byte TDS headers; afterwards TLS records directly over TCP) pass a `handshakeTransport`; `detach()` serves login-only encryption. Use TLS 1.2 (`maxVersion`) for framed handshakes: a TLS 1.3 server sends session tickets right after the handshake, which would still go through the adapter. Checked against SQL Server 2022, which negotiates TLS 1.2 there anyway.
- Regenerate the test certificates with `sh make-test-certs.sh` in `tls/source/dbwire/tls/testdata` (test-only keys, committed on purpose).

Notes on `dbwire:io`:
- `BufferedReader`/`BufferedWriter` members must not use the names of connectors' protocol functions (clickhoused's `readString()`, `readBytes()`, `readUVarInt()`, `writeString()`, `writeUVarInt()`): connectors define those as free functions called with UFCS, and D ignores a UFCS function when a member of the same name exists. Hence `readExactString`/`readExactBytes`.
- `readByte`/`writeByte` are templates (`()()`) so that they are inlined into other packages' protocol code.
- On Windows, `VibeTransport.dataAvailable` must not call `dataAvailableForRead`: eventcore's WinAPI driver (0.9.x) loses the data of an immediate read that completes at once. It checks `peek()` and the socket with `select()` instead.
- The vibe runners test `vibecore.d`, which unit tests can't reach (vibe-core isn't a dependency of `dub test :io`). Their test servers run on a plain thread with blocking sockets, so they don't depend on vibe's listen API (different in 1.x and 2.x). vibe-core 2.x starts a new task immediately (`runTask` runs it until its first yield).

Each subpackage has its own `dub.json` in its directory, listed in the root `subPackages` array; sibling dependencies are written `"dbwire:types": "*"`. Module names `dbwire.<area>.<name>`, each area with a `package.d` of public imports.

## Commands

The recipe format is **`dub.json`** (never `dub.sdl` or `package.json`).

```sh
dub build                         # everything
dub test                          # root package unit tests
dub test :types                   # one subpackage (types, io, tls, crypto, charset, client)
dub run --root=tests-vibe         # fiber-mode tests, vibe-core 2.x (downloads vibe-core on first run)
DBWIRE_REQUIRE_OPENSSL=1 DBWIRE_TLS_PUBLIC_HOST=github.com:443 dub test :tls   # TLS tests as CI runs them
dub run --root=tests-vibe1        # the same with vibe-core 1.22.6
dub run dscanner@0.15.2 -- --styleCheck .                 # lint (CI fails on any warning)
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')    # format (CI fails if this changes files)
dub build -b docs                                         # docs into /docs/ (git-ignored)
```

Run lint and format before committing D code. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` becomes `() nothrow{`): use named nested functions. It merges `@safe return` into `@safereturn`: avoid the `return` attribute. Run dfmt twice when it changes files.

`dub.selections.json` files are git-ignored: a root one listing vibe-core would silently enable vibe support. The vibe runners are standalone packages run with `--root`, so their selections stay in their own directories.

## Local environment

- WSL2 Linux. **LDC 1.36.0** (`ldc2`, frontend 2.106); DMD is not installed. DUB 1.36.0.
- **Minimum D frontend 2.097** (ddbc's minimum; dub enforces the compiler requirements of all dependencies). Don't use newer language or Phobos features without the user's agreement (e.g. `std.logger` is 2.101+: fall back to `std.experimental.logger`). Old frontends warn about things newer compilers accept, and dub turns warnings into errors.
- Before pushing, build and test with LDC 1.27.1: download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad and run dub with `--compiler=<path>/bin/ldc2`.
- Docker is available (e.g. `debian:trixie` for OpenSSL 3.5 checks; database server images for the connectors).

## Conventions

- `@safe` by default, small `@trusted` blocks only in I/O, FFI and reinterpret-cast hot paths, each with a comment explaining why it is safe.
- **Every public symbol gets a Ddoc comment.** Docs are generated on dpldocs.info, and dscanner flags undocumented public declarations. Use `Params:`, `Returns:`, `Throws:`, `See_Also:` where useful.
- **Unit tests inside modules**, next to the code. A `///` unittest after a public symbol becomes its usage example; prefer that for public API.
- When code moves from clickhoused, keep its tests and behaviour; note renamed symbols in `CHANGELOG.md`.

## Related local repositories (read-only unless the user asks)

- `../clickhoused`: the source of the extracted code (`source/clickhoused/io/`, `types/wideint.d`, `types/decimal.d`, `types/datetime.d` `resolveTimeZone`, `exception.d`, `settings.d`, `pool.d`) and the model for project conventions (its `AGENTS.md`).
- `../ddbc`, `../hibernated`: consumers of `dbwire:types`.
- `../mysql-native`: the original model for dual Phobos/vibe I/O.
- `/home/lve/git/ClickHouse`: used by another agent; never modify, check out or build anything there (read with `git show origin/master:<path>`).
