/++
Time zones read from TZif files (the tz database's binary format, RFC 8536):
`TzifTimeZone`.

Unlike Phobos's `PosixTimeZone`, the offsets follow RFC 8536 at both ends of
the file's transitions: before the first transition, time type 0 (usually
the local mean time, e.g. +05:41:16 for Asia/Kathmandu before 1920); after
the last one, the rules of the POSIX TZ string in the footer of version 2+
files (so daylight saving time goes on after 2037).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.tzif;

import core.time : Duration, seconds;
import std.datetime.timezone : TimeZone;

import dbwire.exception : ClientException;

@safe:

/// A local time type: the offset from UTC, whether it is daylight saving time, and its abbreviation.
struct LocalTimeType
{
    /// Seconds to add to UTC to get the local time.
    int utcOffset;
    /// Whether it is daylight saving time.
    bool isDst;
    /// The abbreviation, e.g. `CEST` or `+0545`.
    string abbreviation;
}

/++
A time zone of the tz database, from the contents of its TZif file.
+/
final class TzifTimeZone : TimeZone
{
    private immutable long[] transitions; // Unix seconds, ascending
    private immutable ubyte[] transitionTypes; // the type index of each transition
    private immutable LocalTimeType[] types;
    private immutable PosixRule footer; // the rules after the last transition (valid if the file has them)
    private immutable bool anyDst;

    private this(string name, immutable long[] transitions, immutable ubyte[] transitionTypes,
            immutable LocalTimeType[] types, immutable PosixRule footer, string stdName, string dstName) immutable pure
    {
        super(name, stdName, dstName);
        this.transitions = transitions;
        this.transitionTypes = transitionTypes;
        this.types = types;
        this.footer = footer;
        bool dst = footer.valid && footer.hasDst;
        foreach (t; types)
            dst = dst || t.isDst;
        anyDst = dst;
    }

    /++
    Reads a TZif file (versions 1 to 4; the 64-bit data and the footer of
    version 2+). Files with leap seconds (the tz database's `right/` zones)
    are not supported: `resolveTimeZone` leaves them to `PosixTimeZone`.

    Params:
        name = the zone's name, e.g. `Europe/Lisbon`.
        data = the file's contents.
    Throws: `ClientException` for malformed data.
    +/
    static immutable(TzifTimeZone) parse(string name, scope const(ubyte)[] data) pure
    {
        auto r = Reader(data);
        auto header = r.header();
        if (header.version_ == 0)
        {
            // version 1: 32-bit times, no footer
            auto block = r.block(header, 4);
            return build(name, block, PosixRule.init);
        }
        r.skipBlock(header, 4); // the version 1 data
        auto header2 = r.header();
        auto block = r.block(header2, 8);
        // the footer: "\n" TZ string "\n"
        PosixRule rules;
        if (r.remaining && r.peek == '\n')
        {
            r.at++;
            const start = r.at;
            while (r.at < data.length && data[r.at] != '\n')
                r.at++;
            if (r.at >= data.length)
                throw malformed("unterminated footer");
            const tz = cast(string) data[start .. r.at].idup;
            if (tz.length)
                rules = PosixRule.parse(tz);
        }
        return build(name, block, rules);
    }

    private static immutable(TzifTimeZone) build(string name, Block block, PosixRule footer) pure
    {
        if (block.types.length == 0)
            throw malformed("no local time types");
        foreach (t; block.transitionTypes)
            if (t >= block.types.length)
                throw malformed("invalid time type index");
        // names: the footer's if there is one, else the last standard and daylight types
        string stdName = footer.valid ? footer.stdAbbreviation : null;
        string dstName = footer.valid && footer.hasDst ? footer.dstAbbreviation : null;
        foreach_reverse (t; block.types)
        {
            if (stdName is null && !t.isDst)
                stdName = t.abbreviation;
            if (dstName is null && t.isDst)
                dstName = t.abbreviation;
        }
        if (stdName is null)
            stdName = block.types[0].abbreviation;
        if (dstName is null)
            dstName = stdName;
        return new immutable TzifTimeZone(name, block.transitions.idup, block.transitionTypes.idup,
                block.types.idup, cast(immutable) footer, stdName, dstName);
    }

    /// The Unix times of the first and the last transition (both 0 without transitions).
    package @property long firstTransition() const pure nothrow
    {
        return transitions.length ? transitions[0] : 0;
    }

    /// ditto
    package @property long lastTransition() const pure nothrow
    {
        return transitions.length ? transitions[$ - 1] : 0;
    }

    /// The local time type at the Unix time `t` (seconds).
    LocalTimeType typeAt(long t) const pure nothrow
    {
        if (transitions.length == 0)
            return footer.valid ? footer.typeAt(t) : types[0];
        if (t < transitions[0])
            return types[0]; // RFC 8536: time type 0 before the first transition
        if (t > transitions[$ - 1] && footer.valid)
            return footer.typeAt(t);
        // the last transition at or before t
        size_t lo = 0, hi = transitions.length;
        while (hi - lo > 1)
        {
            const mid = (lo + hi) / 2;
            if (transitions[mid] <= t)
                lo = mid;
            else
                hi = mid;
        }
        return types[transitionTypes[lo]];
    }

    override @property bool hasDST() const nothrow scope
    {
        return anyDst;
    }

    override bool dstInEffect(long stdTime) const nothrow scope
    {
        return typeAt(unixSeconds(stdTime)).isDst;
    }

    override long utcToTZ(long stdTime) const nothrow scope
    {
        return stdTime + typeAt(unixSeconds(stdTime)).utcOffset * hnsecsPerSecond;
    }

    override long tzToUTC(long adjTime) const nothrow scope
    {
        // the offset at the local time read as UTC, then at the result (right except in gaps and overlaps,
        // where either neighbouring offset is used)
        const guess = adjTime - typeAt(unixSeconds(adjTime)).utcOffset * hnsecsPerSecond;
        return adjTime - typeAt(unixSeconds(guess)).utcOffset * hnsecsPerSecond;
    }

    override Duration utcOffsetAt(long stdTime) const nothrow scope
    {
        return seconds(typeAt(unixSeconds(stdTime)).utcOffset);
    }
}

private enum long hnsecsPerSecond = 10_000_000;
private enum long unixEpochStdTime = 621_355_968_000_000_000; // 1970-01-01 in hnsecs since 0001-01-01

/// Unix seconds (rounded down) of a Phobos std time.
private long unixSeconds(long stdTime) pure nothrow @nogc
{
    const d = stdTime - unixEpochStdTime;
    return d >= 0 ? d / hnsecsPerSecond : -((-d + hnsecsPerSecond - 1) / hnsecsPerSecond);
}

private ClientException malformed(string what) pure
{
    return new ClientException("Malformed TZif data: " ~ what);
}

private struct Header
{
    int version_; // 0 for version 1, else 2, 3, 4
    uint isUtCount, isStdCount, leapCount, timeCount, typeCount, charCount;
}

private struct Block
{
    long[] transitions;
    ubyte[] transitionTypes;
    LocalTimeType[] types;
}

private struct Reader
{
    const(ubyte)[] data;
    size_t at;

    @property bool remaining() const pure nothrow
    {
        return at < data.length;
    }

    @property ubyte peek() const pure nothrow
    {
        return data[at];
    }

    const(ubyte)[] take(size_t n) pure
    {
        if (n > data.length - at)
            throw malformed("truncated");
        auto bytes = data[at .. at + n];
        at += n;
        return bytes;
    }

    long bigEndian(size_t n) pure
    {
        const bytes = take(n);
        ulong v;
        foreach (b; bytes)
            v = v << 8 | b;
        return n == 4 ? cast(long) cast(int) cast(uint) v : cast(long) v;
    }

    Header header() pure
    {
        const magic = take(4);
        if (magic != cast(const(ubyte)[]) "TZif")
            throw malformed("no TZif signature");
        Header h;
        const v = take(1)[0];
        if (v == 0)
            h.version_ = 0;
        else if (v >= '2' && v <= '9')
            h.version_ = v - '0';
        else
            throw malformed("unknown version");
        take(15);
        h.isUtCount = cast(uint) bigEndian(4);
        h.isStdCount = cast(uint) bigEndian(4);
        h.leapCount = cast(uint) bigEndian(4);
        h.timeCount = cast(uint) bigEndian(4);
        h.typeCount = cast(uint) bigEndian(4);
        h.charCount = cast(uint) bigEndian(4);
        if (h.typeCount == 0 || (h.isUtCount != 0 && h.isUtCount != h.typeCount)
                || (h.isStdCount != 0 && h.isStdCount != h.typeCount))
            throw malformed("invalid counts");
        if (h.leapCount != 0)
            throw new ClientException("TZif data with leap seconds (the right/ zones) is not supported");
        return h;
    }

    // the length of a data block with times of `timeSize` bytes
    static size_t blockLength(const Header h, size_t timeSize) pure nothrow
    {
        return h.timeCount * timeSize + h.timeCount + h.typeCount * 6 + h.charCount
            + h.leapCount * (
                    timeSize + 4) + h.isStdCount + h.isUtCount;
    }

    void skipBlock(const Header h, size_t timeSize) pure
    {
        take(blockLength(h, timeSize));
    }

    Block block(const Header h, size_t timeSize) pure
    {
        if (blockLength(h, timeSize) > data.length - at)
            throw malformed("truncated");
        Block b;
        b.transitions = new long[h.timeCount];
        foreach (ref t; b.transitions)
            t = bigEndian(timeSize);
        foreach (i; 1 .. b.transitions.length)
            if (b.transitions[i] <= b.transitions[i - 1])
                throw malformed("transitions out of order");
        b.transitionTypes = take(h.timeCount).dup;
        static struct RawType
        {
            int offset;
            bool isDst;
            ubyte abbreviationIndex;
        }

        auto raw = new RawType[h.typeCount];
        foreach (ref t; raw)
        {
            t.offset = cast(int) bigEndian(4);
            t.isDst = take(1)[0] != 0;
            t.abbreviationIndex = take(1)[0];
        }
        const chars = take(h.charCount);
        b.types = new LocalTimeType[h.typeCount];
        foreach (i, t; raw)
        {
            if (t.offset <= -25 * 3600 || t.offset >= 26 * 3600 || t.abbreviationIndex >= chars.length)
                throw malformed("invalid local time type");
            size_t end = t.abbreviationIndex;
            while (end < chars.length && chars[end] != 0)
                end++;
            b.types[i] = LocalTimeType(t.offset, t.isDst, cast(string) chars[t.abbreviationIndex .. end].idup);
        }
        take(h.leapCount * (timeSize + 4) + h.isStdCount + h.isUtCount); // leap seconds, indicators: unused
        return b;
    }
}

/// A date rule of a POSIX TZ string: `Jn` (1 to 365, no February 29), `n` (0 to 365), `Mm.w.d`.
private struct RuleDate
{
    char kind; // 'J', 'n' or 'M'
    int day; // Jn, n: the day; M: the weekday (0 = Sunday)
    int month, week;
}

/// The rules of a POSIX TZ string (`std offset [dst [offset] [,start[/time],end[/time]]]`).
private struct PosixRule
{
    bool valid;
    bool hasDst;
    int stdOffset, dstOffset; // seconds to add to UTC
    string stdAbbreviation, dstAbbreviation;
    RuleDate start, end;
    int startTime = 2 * 3600, endTime = 2 * 3600; // local time of day, seconds (may be negative or over 24 h)

    static PosixRule parse(string tz) pure
    {
        PosixRule r;
        size_t i;
        ClientException bad()
        {
            return new ClientException("Invalid TZ string '" ~ tz ~ "'");
        }

        string name()
        {
            if (i < tz.length && tz[i] == '<')
            {
                const start = ++i;
                while (i < tz.length && tz[i] != '>')
                    i++;
                if (i >= tz.length)
                    throw bad();
                return tz[start .. i++];
            }
            const start = i;
            while (i < tz.length && ((tz[i] >= 'A' && tz[i] <= 'Z') || (tz[i] >= 'a' && tz[i] <= 'z')))
                i++;
            if (i - start < 3)
                throw bad();
            return tz[start .. i];
        }

        // [+-]hh[:mm[:ss]] in seconds
        int duration(int maxHours)
        {
            int sign = 1;
            if (i < tz.length && (tz[i] == '+' || tz[i] == '-'))
                sign = tz[i++] == '-' ? -1 : 1;
            int part()
            {
                const start = i;
                int v;
                while (i < tz.length && tz[i] >= '0' && tz[i] <= '9' && i - start < 3)
                    v = v * 10 + (tz[i++] - '0');
                if (i == start)
                    throw bad();
                return v;
            }

            int total = part() * 3600;
            if (total > maxHours * 3600)
                throw bad();
            if (i < tz.length && tz[i] == ':')
            {
                i++;
                total += part() * 60;
                if (i < tz.length && tz[i] == ':')
                {
                    i++;
                    total += part();
                }
            }
            return sign * total;
        }

        RuleDate date()
        {
            RuleDate d;
            int number()
            {
                const start = i;
                int v;
                while (i < tz.length && tz[i] >= '0' && tz[i] <= '9')
                    v = v * 10 + (tz[i++] - '0');
                if (i == start || i - start > 3)
                    throw bad();
                return v;
            }

            if (i < tz.length && tz[i] == 'J')
            {
                i++;
                d.kind = 'J';
                d.day = number();
                if (d.day < 1 || d.day > 365)
                    throw bad();
            }
            else if (i < tz.length && tz[i] == 'M')
            {
                i++;
                d.kind = 'M';
                d.month = number();
                if (i >= tz.length || tz[i++] != '.')
                    throw bad();
                d.week = number();
                if (i >= tz.length || tz[i++] != '.')
                    throw bad();
                d.day = number();
                if (d.month < 1 || d.month > 12 || d.week < 1 || d.week > 5 || d.day > 6)
                    throw bad();
            }
            else
            {
                d.kind = 'n';
                d.day = number();
                if (d.day > 365)
                    throw bad();
            }
            return d;
        }

        r.stdAbbreviation = name();
        r.stdOffset = -duration(24); // POSIX offsets are west of Greenwich
        if (i < tz.length)
        {
            r.hasDst = true;
            r.dstAbbreviation = name();
            r.dstOffset = r.stdOffset + 3600;
            if (i < tz.length && tz[i] != ',')
                r.dstOffset = -duration(24);
            if (i < tz.length)
            {
                if (tz[i++] != ',')
                    throw bad();
                r.start = date();
                if (i < tz.length && tz[i] == '/')
                {
                    i++;
                    r.startTime = duration(167);
                }
                if (i >= tz.length || tz[i++] != ',')
                    throw bad();
                r.end = date();
                if (i < tz.length && tz[i] == '/')
                {
                    i++;
                    r.endTime = duration(167);
                }
            }
            else
            {
                // no rule: the default of most systems (US rules since 2007)
                r.start = RuleDate('M', 0, 3, 2);
                r.end = RuleDate('M', 0, 11, 1);
            }
        }
        if (i != tz.length)
            throw bad();
        r.valid = true;
        return r;
    }

    LocalTimeType typeAt(long t) const pure nothrow
    {
        const std = LocalTimeType(stdOffset, false, stdAbbreviation);
        if (!hasDst)
            return std;
        const dst = LocalTimeType(dstOffset, true, dstAbbreviation);
        const year = yearOf(t + stdOffset);
        const startUtc = dayOf(start, year) * 86_400L + startTime - stdOffset; // a local standard time
        const endUtc = dayOf(end, year) * 86_400L + endTime - dstOffset; // a local daylight time
        if (startUtc < endUtc)
            return t >= startUtc && t < endUtc ? dst : std; // northern hemisphere
        return t >= endUtc && t < startUtc ? std : dst; // southern: DST across the new year
    }
}

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
private long daysFromCivil(long y, int m, int d) pure nothrow @nogc
{
    y -= m <= 2;
    const era = (y >= 0 ? y : y - 399) / 400;
    const yoe = y - era * 400;
    const doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

/// The year of the Unix time `t` (seconds).
private long yearOf(long t) pure nothrow @nogc
{
    long days = t >= 0 ? t / 86_400 : -((-t + 86_399) / 86_400);
    days += 719_468;
    const era = (days >= 0 ? days : days - 146_096) / 146_097;
    const doe = days - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const month = mp < 10 ? mp + 3 : mp - 9;
    return yoe + era * 400 + (month <= 2);
}

private bool isLeap(long y) pure nothrow @nogc
{
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

/// Days since 1970-01-01 of a rule date in `year`.
private long dayOf(const RuleDate d, long year) pure nothrow @nogc
{
    switch (d.kind)
    {
    case 'J':
        return daysFromCivil(year, 1, 1) + d.day - 1 + (isLeap(year) && d.day >= 60 ? 1 : 0);
    case 'n':
        return daysFromCivil(year, 1, 1) + d.day;
    case 'M':
        const first = daysFromCivil(year, d.month, 1);
        const firstWeekday = cast(int)(((first % 7) + 11) % 7); // 1970-01-01 was a Thursday (4)
        long day = first + (d.day - firstWeekday + 7) % 7 + (d.week - 1) * 7;
        static immutable int[12] monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        const length = monthDays[d.month - 1] + (d.month == 2 && isLeap(year) ? 1 : 0);
        while (day >= first + length)
            day -= 7; // week 5: the last such weekday
        return day;
    default:
        return 0;
    }
}

unittest
{
    assert(daysFromCivil(1970, 1, 1) == 0 && daysFromCivil(2000, 3, 1) == 11_017 && daysFromCivil(1969, 12, 31) == -1);
    assert(yearOf(0) == 1970 && yearOf(-1) == 1969 && yearOf(951_782_400) == 2000 && yearOf(4_102_444_800) == 2100);
    // second Sunday of March 2026 = 8 March; last Sunday of October 2026 = 25 October
    assert(dayOf(RuleDate('M', 0, 3, 2), 2026) == daysFromCivil(2026, 3, 8));
    assert(dayOf(RuleDate('M', 0, 10, 5), 2026) == daysFromCivil(2026, 10, 25));
    assert(dayOf(RuleDate('J', 60, 0, 0), 2024) == daysFromCivil(2024, 3, 1)); // J60 skips February 29
    assert(dayOf(RuleDate('n', 59, 0, 0), 2024) == daysFromCivil(2024, 2, 29));
}

unittest
{
    import std.exception : assertThrown;

    auto r = PosixRule.parse("<-0330>3:30<-0230>,M3.2.0,M11.1.0");
    assert(r.valid && r.hasDst && r.stdOffset == -12_600 && r.dstOffset == -9000 && r.stdAbbreviation == "-0330");
    r = PosixRule.parse("CET-1CEST,M3.5.0,M10.5.0/3");
    assert(r.stdOffset == 3600 && r.dstOffset == 7200 && r.endTime == 3 * 3600);
    // Europe/Lisbon in 2095: WEST (+1) in summer, WET in winter
    r = PosixRule.parse("WET0WEST,M3.5.0/1,M10.5.0");
    assert(r.typeAt(daysFromCivil(2095, 7, 1) * 86_400).utcOffset == 3600);
    assert(r.typeAt(daysFromCivil(2095, 1, 1) * 86_400).utcOffset == 0);
    // southern hemisphere (Australia/Sydney): daylight time over the new year
    r = PosixRule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    assert(r.typeAt(daysFromCivil(2090, 1, 15) * 86_400).utcOffset == 11 * 3600);
    assert(r.typeAt(daysFromCivil(2090, 7, 15) * 86_400).utcOffset == 10 * 3600);
    // America/Godthab style: negative transition time (-2:00) and v3 hours over 24
    r = PosixRule.parse("<-02>2<-01>,M3.5.0/-1,M10.5.0/0");
    assert(r.startTime == -3600);
    r = PosixRule.parse("<+0545>-5:45");
    assert(!r.hasDst && r.stdOffset == 5 * 3600 + 45 * 60);
    assertThrown!ClientException(PosixRule.parse("X1"));
    assertThrown!ClientException(PosixRule.parse("EST5EDT,M3.2.0"));
    assertThrown!ClientException(PosixRule.parse("EST5EDT,M13.2.0,M11.1.0"));
}

// Malformed and truncated data throws
unittest
{
    import std.exception : assertThrown;

    assertThrown!ClientException(TzifTimeZone.parse("x", []));
    assertThrown!ClientException(TzifTimeZone.parse("x", cast(const(ubyte)[]) "TZif2"));
    ubyte[44] header = 0;
    header[0 .. 4] = cast(const(ubyte)[]) "TZif";
    assertThrown!ClientException(TzifTimeZone.parse("x", header[])); // no types
    header[39] = 1; // one type, but no data
    assertThrown!ClientException(TzifTimeZone.parse("x", header[]));
    header[31] = 1; // a leap second record: not supported
    assertThrown!ClientException(TzifTimeZone.parse("x", header[]));
}
