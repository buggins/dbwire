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

Zones come from the system's tz database (`TZDIR`, else `/usr/share/zoneinfo`
and the other usual directories), read as RFC 8536 says (`TzifTimeZone`: local
mean time before a zone's first transition, the rules of its footer after the
last one), with Phobos's `PosixTimeZone` as the fallback. Windows has no tz
database (unless `TZDIR` names one): there every name resolves to UTC, so
points in time stay correct and only their presentation (the local time)
differs.
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
    if (auto zone = loadTzif(name))
        return zone;
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

/// The zone's TZif file from the tz database, read by `TzifTimeZone`; null if not found or malformed.
private immutable(TimeZone) loadTzif(string name) @safe
{
    import std.file : exists, FileException, isFile, read;
    import std.path : buildPath;
    import std.process : environment;
    import dbwire.types.tzif : TzifTimeZone;

    if (!isZoneName(name))
        return null;
    string[] directories;
    const tzdir = environment.get("TZDIR");
    if (tzdir.length)
        directories ~= tzdir;
    version (Posix)
        directories ~= [
        "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo"
    ];
    foreach (directory; directories)
    {
        const path = buildPath(directory, name);
        try
        {
            if (!exists(path) || !isFile(path))
                continue;
            return TzifTimeZone.parse(name, cast(const(ubyte)[]) read(path));
        }
        catch (Exception)
            return null; // unreadable or malformed: PosixTimeZone decides
    }
    return null;
}

/// Whether `name` looks like a tz database name (`Europe/Lisbon`, `Etc/GMT+5`): no path tricks.
private bool isZoneName(string name) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    if (name.length == 0 || name[0] == '/' || name[0] == '.' || name.canFind(".."))
        return false;
    foreach (c; name)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '_'
                || c == '-' || c == '+' || c == '.'))
            return false;
    return true;
}

@safe unittest
{
    assert(isZoneName("Europe/Lisbon") && isZoneName("Etc/GMT+5") && isZoneName("America/Port-au-Prince"));
    assert(!isZoneName("../etc/passwd") && !isZoneName("/etc/localtime") && !isZoneName("a b"));
}

// RFC 8536 at both ends of the transitions (values from Python's zoneinfo)
@safe unittest
{
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;

    version (Posix)
    {
        import std.file : exists;

        if (!exists("/usr/share/zoneinfo/Asia/Kathmandu"))
            return; // no tz database
        static struct Case
        {
            string zone;
            long unixTime;
            int offset;
        }

        static immutable Case[] cases = [
            Case("Asia/Kathmandu", -1_893_456_000, 20_476), // 1910: LMT +05:41:16
            Case("America/St_Johns", 3_960_316_800, -9000), // July 2095: NDT, from the footer
            Case("America/St_Johns", 3_944_678_400, -12_600), // January 2095: NST
            Case("America/St_Johns", -2_840_140_800, -12_652), // 1880: LMT
            Case("Australia/Sydney", 3_788_121_600, 39_600), // January 2090: AEDT
            Case("Australia/Sydney", 3_803_760_000, 36_000), // July 2090: AEST
            Case("Europe/Lisbon", -2_208_988_800, -2205), // 1900: LMT
            Case("Europe/Lisbon", 4_118_083_200, 3600), // July 2100: WEST
            Case("America/New_York", 7_274_016_000, -14_400), // July 2200: EDT
            Case("Europe/Dublin", 2_841_350_400, 0), // January 2060: GMT (negative DST)
            Case("Europe/Dublin", 2_857_075_200, 3600), // July 2060: IST
            Case("America/Nuuk", 3_802_550_400, -3600), // July 2090
            Case("Asia/Tehran", 2_537_654_400, 12_600), // June 2050
        ];
        foreach (c; cases)
        {
            const zone = resolveTimeZone(c.zone);
            const t = SysTime.fromUnixTime(c.unixTime, UTC());
            assert(zone.utcOffsetAt(t.stdTime).total!"seconds" == c.offset, c.zone);
            // and back: the local time converts to the same instant
            assert(zone.tzToUTC(zone.utcToTZ(t.stdTime)) == t.stdTime, c.zone);
        }
    }
}

// Where Phobos's PosixTimeZone is right (between the first and the last transition, 1972 to 2036),
// TzifTimeZone gives the same offsets for every zone of the system's tz database
@system unittest
{
    version (Posix)
    {
        import std.datetime.timezone : PosixTimeZone;
        import std.file : exists;
        import std.random : Random, uniform;
        import dbwire.types.tzif : TzifTimeZone;

        if (!exists("/usr/share/zoneinfo/Europe/Lisbon"))
            return;
        auto random = Random(2026);
        size_t zones;
        foreach (name; PosixTimeZone.getInstalledTZNames())
        {
            import std.typecons : Rebindable;

            Rebindable!(immutable PosixTimeZone) phobos;
            try
                phobos = PosixTimeZone.getTimeZone(name);
            catch (Exception)
                continue;
            const mine = cast(immutable TzifTimeZone) loadTzif(name);
            assert(mine !is null, name);
            if (mine.lastTransition <= mine.firstTransition)
                continue; // fixed offset
            zones++;
            // between the transitions, and within 1972 to 2037 (Phobos reads the 32-bit data)
            import std.algorithm.comparison : max, min;

            const from = max(63_072_000L, mine.firstTransition), to = min(2_114_380_800L, mine.lastTransition);
            if (to <= from)
                continue;
            foreach (i; 0 .. 50)
            {
                const unixTime = uniform(from, to, random);
                const stdTime = 621_355_968_000_000_000L + unixTime * 10_000_000L;
                assert(mine.utcOffsetAt(stdTime) == phobos.utcOffsetAt(stdTime), name);
            }
        }
        assert(zones > 300, "few zones");
    }
}
