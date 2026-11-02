/++
TLS over any transport (subpackage `dbwire:tls`).

$(UL
    $(LI `dbwire.tls.transport`: `TlsOptions`, `TlsContext` and `TlsTransport`,
        a decorator that encrypts any `Transport` in thread and fiber mode.)
    $(LI `dbwire.tls.openssl`: the run-time loader of OpenSSL 1.1.1 or 3.x
        (`loadOpenSsl`), with its own minimal declarations: no build-time
        dependency, and only secure connections fail if OpenSSL is missing.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.tls;

public import dbwire.tls.openssl;
public import dbwire.tls.transport;
