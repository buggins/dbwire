/++
Byte-stream transports and I/O backends (subpackage `dbwire:io`).

$(UL
    $(LI `dbwire.io.transport`: `Transport`, one open byte stream to a server.)
    $(LI `dbwire.io.backend`: `IoMode`, `IoBackend` (connect, yield, locks) and
        `backendFor`, which picks thread or fiber mode.)
    $(LI `dbwire.io.phobos`: thread mode, blocking Phobos sockets.)
    $(LI `dbwire.io.vibecore`: fiber mode, vibe-core sockets (only when vibe-core
        is in the application's dependency graph).)
    $(LI `dbwire.io.buffer`: `BufferedReader`, `BufferedWriter`, `StringArena`.)
    $(LI `dbwire.io.mock`: `MockTransport`, an in-memory transport for tests.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.io;

public import dbwire.io.backend;
public import dbwire.io.buffer;
public import dbwire.io.mock;
public import dbwire.io.phobos;
public import dbwire.io.transport;

version (Have_vibe_core) public import dbwire.io.vibecore : FiberLock, FiberPoolSync, VibeBackend, VibeTransport;
