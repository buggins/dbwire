/++
Year-month intervals: the `MonthInterval` value type.

Intervals of years and months (Oracle `INTERVAL YEAR TO MONTH`) can't be
expressed as a fixed duration, since months have different lengths. Intervals
of days, hours, minutes and seconds use `core.time.Duration`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.interval;

import dbwire.exception : ClientException;

/++
An interval of whole months, e.g. `MonthInterval(27)` is 2 years and 3 months.
Negative values are negative intervals.
+/
struct MonthInterval
{
    /// The total number of months.
    int months;

    /++
    Creates an interval of `years` years and `monthsPart` months, e.g.
    `fromYearsMonths(2, 3)` or, for a negative interval, `fromYearsMonths(-2, -3)`.

    Throws: `ClientException` if the total does not fit in an `int`.
    +/
    static MonthInterval fromYearsMonths(int years, int monthsPart) @safe pure
    {
        const total = years * 12L + monthsPart;
        if (total < int.min || total > int.max)
            throw new ClientException(
                    "Interval out of range: " ~ toText(years) ~ " years " ~ toText(
                    monthsPart) ~ " months");
        return MonthInterval(cast(int) total);
    }

    /// Whole years (rounded towards zero), e.g. 2 for 27 months and -2 for -27 months.
    @property int years() const @safe pure nothrow @nogc
    {
        return months / 12;
    }

    /// The months beyond `years`, with the sign of the interval: 3 for 27 months, -3 for -27.
    @property int monthsPart() const @safe pure nothrow @nogc
    {
        return months % 12;
    }

    /// Compares two intervals.
    int opCmp(const MonthInterval other) const @safe pure nothrow @nogc
    {
        return months < other.months ? -1 : months > other.months ? 1 : 0;
    }

    /// The interval as SQL writes it in `INTERVAL '...' YEAR TO MONTH`: `"2-3"`, `"-2-3"`.
    string toString() const @safe pure nothrow
    {
        const negative = months < 0;
        const total = negative ? -cast(long) months : months;
        return (negative ? "-" : "") ~ toText(total / 12) ~ "-" ~ toText(total % 12);
    }

    /++
    Parses `[+|-]years-months`, with months from 0 to 11, e.g. `"2-3"` or `"-0-6"`.

    Throws: `ClientException` if the text is not such an interval or out of range.
    +/
    static MonthInterval fromString(scope const(char)[] text) @safe pure
    {
        import std.conv : ConvException, to;
        import std.string : indexOf;

        ClientException error()
        {
            return new ClientException("Cannot parse '" ~ text.idup ~ "' as a year-month interval");
        }

        size_t pos;
        const negative = text.length && text[0] == '-';
        if (text.length && (text[0] == '-' || text[0] == '+'))
            pos = 1;
        const dash = text[pos .. $].indexOf('-');
        if (dash <= 0)
            throw error();
        const yearText = text[pos .. pos + dash];
        const monthText = text[pos + dash + 1 .. $];
        foreach (part; [yearText, monthText])
            foreach (c; part)
                if (c < '0' || c > '9')
                    throw error();
        if (monthText.length == 0 || yearText.length > 10 || monthText.length > 2)
            throw error();
        long years, monthsPart;
        try
        {
            years = yearText.to!long;
            monthsPart = monthText.to!long;
        }
        catch (ConvException)
            throw error();
        if (monthsPart > 11)
            throw error();
        auto total = years * 12 + monthsPart;
        if (negative)
            total = -total;
        if (total < int.min || total > int.max)
            throw error();
        return MonthInterval(cast(int) total);
    }
}

///
@safe unittest
{
    const i = MonthInterval.fromYearsMonths(2, 3);
    assert(i.months == 27 && i.years == 2 && i.monthsPart == 3);
    assert(i.toString() == "2-3" && MonthInterval.fromString("2-3") == i);
    assert(MonthInterval(-6).toString() == "-0-6");
}

@safe unittest
{
    import std.exception : assertThrown;

    assert(MonthInterval(-27).years == -2 && MonthInterval(-27).monthsPart == -3);
    assert(MonthInterval.fromYearsMonths(-2, -3) == MonthInterval(-27));
    assert(MonthInterval.init.toString() == "0-0" && MonthInterval(12).toString() == "1-0");
    assert(MonthInterval(int.min).toString() == "-178956970-8");
    assert(MonthInterval.fromString(MonthInterval(int.min).toString()) == MonthInterval(int.min));
    assert(MonthInterval.fromString("+1-11") == MonthInterval(23) && MonthInterval.fromString("-0-6").months == -6);
    assert(MonthInterval(1) > MonthInterval(-1) && MonthInterval(5) < MonthInterval(12));
    foreach (bad; [
        "", "-", "1", "1-", "-1", "1-12", "a-1", "1-b", "1--1", " 1-1", "1-1 ", "99999999999-0"
    ])
        assertThrown!ClientException(MonthInterval.fromString(bad), bad);
    assertThrown!ClientException(MonthInterval.fromYearsMonths(int.max, 0));
}

private string toText(T)(T value) @safe pure nothrow
{
    import std.conv : to;

    try
        return value.to!string;
    catch (Exception)
        assert(false, "integer formatting does not fail");
}
