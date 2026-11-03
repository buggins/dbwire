# dbwire

Shared building blocks for native D database connectors: value types, transports
for threads and vibe.d fibers, TLS, cryptography, character sets and connection
plumbing.

dbwire is extracted from [clickhoused](https://github.com/buggins/clickhoused),
the native ClickHouse client, so that native connectors for other databases can
share the parts that are not protocol-specific. Its value types (exact decimals,
128/256-bit integers) are also meant for [ddbc](https://github.com/buggins/ddbc)
and [hibernated](https://github.com/buggins/hibernated).

> **Status: 0.5.1.** All subpackages are in place: `dbwire:types`,
> `dbwire:io`, `dbwire:tls`, `dbwire:crypto`, `dbwire:charset` and
> `dbwire:client`. The API may change until 1.0, which is planned together with
> clickhoused 1.0. The plan is tracked in the
> [roadmap issue](https://github.com/buggins/dbwire/issues/13); changes are
> listed in the [changelog](CHANGELOG.md).

## Subpackages

Depend only on what you need:

| Subpackage       | Contents                                                                      | Dependencies              |
|------------------|-------------------------------------------------------------------------------|---------------------------|
| `dbwire:types`   | exceptions, exact decimals, 128/256-bit integers, intervals, time zones       | none                      |
| `dbwire:io`      | transports and I/O backends: blocking Phobos sockets and vibe.d fibers        | vibe-core (optional)      |
| `dbwire:tls`     | TLS over any transport, with OpenSSL loaded at run time                       | none at build time        |
| `dbwire:crypto`  | pure-D AES (CBC), PBKDF2, MD4, secure random for authentication               | none                      |
| `dbwire:charset` | UTF-16 and the code pages of SQL Server collations (single/double-byte, UTF-8)| none                      |
| `dbwire:client`  | connection strings, host failover, connection pool core                       | none                      |
| `dbwire`         | all of the above                                                              |                           |

For example, in `dub.json`:

```json
"dependencies": {
    "dbwire:types": "~>0.5.0"
}
```

```d
import dbwire.types;

auto price = Decimal.fromString("19.995", 2, RoundingMode.halfUp);
assert(price.toString() == "20" && price.toFixedString() == "20.00");
assert(Decimal(Int256(5), -3).toString() == "5000"); // negative scales, for Oracle NUMBER
```

Principles:

- **Pure D, zero C dependencies by default.** C libraries are optional extras
  loaded at run time (OpenSSL for TLS); when one is missing, only the feature
  that needs it fails, with a clear exception.
- **Threads and fibers.** Everything that can block goes through one I/O
  interface with two implementations: blocking Phobos sockets, and vibe-core
  sockets for vibe.d tasks. vibe-core is optional: it is used only when your
  application depends on it.
- **D frontend 2.097 or newer**: DMD 2.097+, LDC 1.27+, GDC 12+.

## License

[Boost Software License 1.0](LICENSE).
