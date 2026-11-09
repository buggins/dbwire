/++
Common value types for database connectors (subpackage `dbwire:types`).

$(UL
    $(LI `dbwire.exception`: `DbException` and its subclasses.)
    $(LI `dbwire.types.decimal`: `Decimal`, an exact decimal number, and `RoundingMode`.)
    $(LI `dbwire.types.wideint`: `Int128`, `UInt128`, `Int256`, `UInt256`.)
    $(LI `dbwire.types.interval`: `MonthInterval`, an interval of years and months.)
    $(LI `dbwire.types.timezone`: `resolveTimeZone`, time zones by name.)
    $(LI `dbwire.types.floattext`: `shortestDigits`, the shortest decimal digits of a `float` or `double`.)
)

This subpackage has no dependencies.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types;

public import dbwire.exception;
public import dbwire.types.decimal;
public import dbwire.types.floattext;
public import dbwire.types.interval;
public import dbwire.types.timezone;
public import dbwire.types.tzif;
public import dbwire.types.wideint;
