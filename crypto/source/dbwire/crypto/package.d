/++
Cryptography for database authentication protocols (subpackage `dbwire:crypto`),
in pure D, each part written from its specification:

$(UL
$(LI `dbwire.crypto.aes`: AES-128/192/256, CBC mode, PKCS#7 padding;)
$(LI `dbwire.crypto.pbkdf2`: PBKDF2 over HMAC with any Phobos digest;)
$(LI `dbwire.crypto.md4`: MD4, for NTLM;)
$(LI `dbwire.crypto.random`: secure random bytes from the operating system.)
)

SHA-1, SHA-2, MD5 and HMAC come from Phobos (`std.digest`). Unstable until the
connectors that use it reach 1.0.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.crypto;

public import dbwire.crypto.aes;
public import dbwire.crypto.md4;
public import dbwire.crypto.pbkdf2;
public import dbwire.crypto.random;
