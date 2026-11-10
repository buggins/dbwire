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
types/   dbwire:types       source/dbwire/exception.d, source/dbwire/types/{decimal,wideint,interval,timezone,tzif,floattext,text}.d
                                                                                    no dependencies
io/      dbwire:io          source/dbwire/io/{transport,backend,phobos,vibecore,unixsocket,buffer,mock}.d
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
- Regenerate the test certificates with `sh make-test-certs.sh` in `tls/source/dbwire/tls/testdata` (test-only keys, committed on purpose). The CRL tests use a CA of their own (`crl-*.pem`, `crl.pem`, `crls/<hash>.r0`), regenerated with `sh make-test-crls.sh`.

Notes on `dbwire:io`:
- `BufferedReader`/`BufferedWriter` members must not use the names of connectors' protocol functions (clickhoused's `readString()`, `readBytes()`, `readUVarInt()`, `writeString()`, `writeUVarInt()`): connectors define those as free functions called with UFCS, and D ignores a UFCS function when a member of the same name exists. Hence `readExactString`/`readExactBytes`.
- `readByte`/`writeByte` are templates (`()()`) so that they are inlined into other packages' protocol code.
- On Windows, `VibeTransport.dataAvailable` must not call `dataAvailableForRead`: eventcore's WinAPI driver (0.9.x) loses the data of an immediate read that completes at once. It checks `peek()` and the socket with `select()` instead.
- Unix-domain sockets (`dbwire.io.unixsocket`): vibe-core's `connectTCP(NetworkAddress, ...)` always binds the client socket, to an all-zero `sockaddr_un` by default, so a second concurrent connection fails with `bindFailure` (1.x and 2.x). `VibeBackend.connectUnix` binds each connection to a unique name instead (abstract on Linux, else a temporary file removed after connecting). Don't build the `NetworkAddress` with `NetworkAddress(Address)` (it asserts the full structure length) and don't read `TCPConnection.remoteAddress` of a Unix socket on vibe-core 1.x (its buffer is too small: an eventcore assert); `VibeTransport` takes a `unixSocket` flag instead. Abstract sockets work only in thread mode (vibe-core passes the full structure length).
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

## D idioms and review lessons

Learned from the review of the MySQL 8 work in mysql-native (mysql-d/mysql-native#288, 2026-11). All of these work on the minimum frontend 2.097; checked with LDC 1.27.1.

- **`BigInt` and bytes: never go through hex or decimal strings.**
  - Bytes to `BigInt`: `BigInt(false, bytes)` takes any finite range of unsigned integers, most significant first.
  - `BigInt` to words or bytes: `value.getDigit!uint(i)` or `getDigit!ulong(i)` for `i` below `uintLength` or `ulongLength`, least significant first. dbwire's `WideInt.fromBigInt` does this.
  - Modular exponentiation: `std.bigint.powmod`.
  - `format("%x", bigint)` groups digits with `_` until Phobos 2.114 (dlang/phobos#11051).
- **Enums for protocol names.** For a fixed set of wire strings such as plugin names, use a `ubyte` enum whose members are spelled exactly like the wire names; the protocol's own spelling beats camelCase here.
  - `to!string` then gives the name to send. It returns the stored literal and doesn't allocate for a valid member, but it isn't `nothrow` or `@nogc`.
  - To parse untrusted input, loop over the members: `static foreach (m; __traits(allMembers, E)) if (name == m) return __traits(getMember, E, m);`. This is `nothrow @nogc` and compares the packet slice directly, with no `idup`. Don't use `to!E(name)`, which throws `ConvException` on unknown names.
  - Each name then appears once, instead of in a parse table and a format table that can drift apart.
  - With a `string`-based enum, `to!string` returns the member's identifier, not its value.
- **Small idioms:**
  - Test byte vectors: `cast(const(ubyte)[]) std.conv.hexString!"0a1b..."` instead of hand-written hex decoding.
  - Strip leading zero bytes with `find!(b => b != 0)`.
  - Copy (`idup`) a slice only where it must outlive the buffer; an error message built inside `enforce` is lazy, so copying there is fine.
- **Function attributes** (`@safe`, `@trusted`, `pure`, `nothrow`, `@nogc`, `scope`). Sources: the D spec (function.html, attribute.html), the D blog's memory-safety series, and the D forum consensus. Behaviour checked with LDC 1.27.1 and 1.36 (2026-11-08).
  - **Inference.** Templates, `auto` functions, nested functions and lambdas infer `@safe`, `pure`, `nothrow` and `@nogc`. Other functions infer nothing, even when their body is visible.
    - Write the attributes on ordinary functions, public API first.
    - Leave them off templates. An attribute written on a template binds every instantiation (an `@safe` template rejects a `T` whose copy is `@system`).
    - Lock in what a template infers with an attributed unittest that instantiates it with plain types, e.g. `@safe pure nothrow @nogc unittest`.
  - **`@safe:` at module scope** covers everything after it, templates included; they still infer the other attributes. `pure`, `nothrow` and `@nogc` don't propagate into struct and class bodies.
  - **`@trusted` promises a safe interface.** For every argument a `@safe` caller can pass, the function must not corrupt memory or create an unsafe value, such as a dangling pointer or a `bool` other than 0 or 1. The compiler doesn't check the body.
    - Keep the trusted part as small as possible: trust the one `@system` call, e.g. `(() @trusted => v.get!T)()`, with a comment saying why it is safe.
    - A trusted lambda makes the enclosing function part of the review. Whatever the lambda relies on, such as a length checked a few lines earlier, must stay true when that function changes.
    - A `cast(ubyte[])` view of values without indirections is fine for reading. Writing arbitrary bytes into `bool` or enum values through such a view creates invalid values; normalize them before `@safe` code sees them.
  - **Never mark a template `@trusted` if its body copies, constructs or destroys a `T`.** The attribute hides `T`'s `@system` postblit, copy constructor or destructor. Checked: `V wrap(T)(ref T v) @trusted { T copy = v; ... }` compiles in `@safe` code for a struct with a `@system` postblit. Trust only the `@system` call inside, which lets inference catch `T`, or constrain `T` (`!hasIndirections!T`, `!hasElaborateCopyConstructor!T`).
  - **`nothrow`**: only `Error`s may escape.
    - Wrap calls that can't actually throw in `std.exception.assumeWontThrow`, or in `try ... catch (Exception e) assert(0, e.msg);`.
    - Never catch `Error` or `Throwable` to make code `nothrow`.
  - **`@nogc`** forbids `new`, array appending and concatenation, closures that escape, and `throw new`. Use it for leaf hot paths (codecs, parsers); error paths that throw stay outside it.
  - **`debug` statements** may break `pure`, `nothrow` and `@nogc`, which helps temporary logging. They compile only with `-debug`; don't leave them in committed code.
  - **`scope` and `return scope`** are checked only in `@safe` code compiled with `-preview=dip1000`, which is still not the default (D 2.113, August 2026).
    - Without that switch, `scope` is an unchecked promise. With it, callers may pass stack memory to a `scope` parameter, so a `@trusted` or `@system` function that keeps such a parameter has a memory bug.
    - dbwire and the four connectors are dip1000-clean on current compilers: CI runs their unit tests with `-preview=dip1000` on dmd-latest and ldc-latest (dbwire#50, clickhoused#71, postgresql-native#37, oracle-native#47, mssql-native#42). Older Phobos isn't: 2.097's `std.socket` has no `scope` annotations. Don't add `scope` speculatively.
- **Changes to someone else's code: keep the diff small.** Keep the existing structure, and change the input instead of the cases. For example, when MySQL 8.4 inserted a `Language` column after `Type` in `SHOW PROCEDURE STATUS` (5.7, 8.0 and MariaDB don't have it; the manual doesn't list it), the fix kept the old switch on column numbers: skip column 3 when there are 12 columns, and shift the later indexes down by one.
- **Check facts before writing them down.** Verify server behaviour on the real servers, since manuals lag behind. Take CI failure reasons from the job logs, not from memory. A wrong reason in a commit message had to be corrected during that review.
- **CI facts (November 2026):**
  - GitHub retired the `ubuntu-20.04` runners. When a matrix tests old compilers, pin a concrete image instead of `ubuntu-latest`, and prefer the oldest one still offered: `ubuntu-22.04` today (likely until mid-2027). The mysql-native reviewers asked for that as the most conservative choice, and old compilers down to dmd 2.097 / ldc 1.27 pass on it.
  - `macos-latest` is macOS 26 on arm64. There:
    - `setup-dlang` installs no DMD;
    - `setup-dlang@v1` requests `ldc2-1.28.1-osx-aarch64.tar.xz`, while LDC names the file `osx-arm64`, so the download fails with a 404.
  - `macos-15-intel` runs dmd-latest, dmd 2.098.1 and LDC 1.28.1. On macOS 15, even Intel, the dmd 2.101.2 binary doesn't run and LDC 1.31.0's dub crashes (SIGSEGV).
  - With `setup-dlang@v2.0.0`, programs built by LDC 1.30, 1.35 or 1.40.1 crash (segfault, even hello world) on `macos-latest`, `macos-15` and `macos-15-intel`. LDC 1.41.0 is the oldest that works there, so our CI tests ldc-latest and 1.41.0 on macOS, and the older LDCs on Linux.
  - `WebFreak001/dub-upgrade@v0.1.1` uses GitHub's retired cache service ("getCacheEntry failed"); v0.2.0 works.
