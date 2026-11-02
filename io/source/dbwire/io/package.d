/++
Byte-stream transports and I/O backends (subpackage `dbwire:io`).

Planned (#4): the `Transport` interface, I/O backends for blocking Phobos
sockets (threads) and vibe-core sockets (vibe.d fibers), locks, buffered readers
and writers, and an in-memory transport for tests.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io;
