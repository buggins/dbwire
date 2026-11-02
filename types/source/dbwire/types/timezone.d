/++
Time zones by name: `resolveTimeZone`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.timezone;

import std.datetime.timezone : TimeZone, UTC;
import std.typecons : Rebindable;

/++
Returns the time zone named `name` (an IANA name such as `"Europe/Lisbon"`), or
UTC if `name` is empty or cannot be resolved. Results are cached per thread.
(A template, so that the cache check is inlined into callers in other packages,
which call it for every value of a date-time column.)

Zones come from the system's tz database (`PosixTimeZone`). Windows has none:
there every name resolves to UTC, so points in time stay correct and only their
presentation (the local time) differs.
+/
immutable(TimeZone) resolveTimeZone()(string name) @safe
{
    if (name.length == 0 || name == "UTC")
        return UTC();
    // Callers often pass the same string for many values: check it by identity before hashing
    if (name is lastZoneName)
        return lastZone;
    CachedZone entry;
    if (auto cached = name in timeZoneCache)
        entry = *cached;
    else
    {
        entry = new CachedZone(loadTimeZone(name));
        timeZoneCache[name] = entry;
    }
    lastZoneName = name;
    lastZone = entry.zone;
    return entry.zone;
}

///
@safe unittest
{
    import std.datetime.systime : SysTime;

    assert(resolveTimeZone("") is UTC() && resolveTimeZone("No/Such_Zone") is UTC());
    version (Posix)
    {
        const tokyo = resolveTimeZone("Asia/Tokyo");
        assert(SysTime.fromUnixTime(0, tokyo).hour == 9);
        assert(resolveTimeZone("Asia/Tokyo") is tokyo); // cached
    }
}

private final class CachedZone
{
    immutable TimeZone zone;

    this(immutable TimeZone zone) @safe pure nothrow
    {
        this.zone = zone;
    }
}

private CachedZone[string] timeZoneCache;
private string lastZoneName; // the last name `resolveTimeZone` looked up (per thread) and its zone
private Rebindable!(immutable TimeZone) lastZone;

private immutable(TimeZone) loadTimeZone(string name) @safe
{
    version (Posix)
    {
        import std.datetime.timezone : PosixTimeZone;

        try
            return PosixTimeZone.getTimeZone(name);
        catch (Exception)
            return UTC();
    }
    else
        return UTC();
}
