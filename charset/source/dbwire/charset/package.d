/++
Character set conversions for database protocols (subpackage `dbwire:charset`):
UTF-16 in either byte order (`dbwire.charset.utf16`), and the Windows code
pages used by SQL Server collations (`dbwire.charset.codepage`). Unstable
until the connectors that use it reach 1.0.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.charset;

public import dbwire.charset.codepage;
public import dbwire.charset.utf16;
