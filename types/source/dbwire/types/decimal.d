/++
An exact decimal number: the `Decimal` value type.

`Decimal` holds `unscaled × 10^-scale` exactly, with up to 76 significant
digits, and converts it to and from text, `double`, `long` and
`std.bigint.BigInt`. The scale may be negative, for values such as Oracle
`NUMBER`s with large exponents. Databases with fixed-point decimals (ClickHouse
`Decimal(P, S)`, SQL Server `decimal(p, s)`) store the unscaled integer and use
a fixed scale.

There is no arithmetic yet: use `unscaled.toBigInt()` and `scale` to compute.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.decimal;

import std.bigint : BigInt;

import dbwire.exception : ClientException;
import dbwire.types.wideint : Int256;

/// Most significant digits a `Decimal` holds (in its unscaled value).
enum uint maxDecimalDigits = 76;

/// Largest absolute value of `Decimal.scale`.
enum int maxDecimalScale = 255;

/// How a value is rounded when digits are dropped.
enum RoundingMode
{
    /// Drop the digits (truncate): 1.29 → 1.2, -1.29 → -1.2. ClickHouse does this.
    towardZero,
    /// Round to the nearest value, ties away from zero: 1.25 → 1.3, -1.25 → -1.3.
    /// SQL Server and Oracle round this way.
    halfUp,
    /// Round to the nearest value, ties to an even last digit: 1.25 → 1.2,
    /// 1.35 → 1.4 (banker's rounding).
    halfEven,
}

/++
An exact decimal number: `unscaled × 10^-scale`, e.g. `Decimal(Int256(-150), 2)`
is -1.50 and `Decimal(Int256(5), -3)` is 5000.

Comparison and equality are numeric (1.5 equals 1.50). Functions that drop
digits take a `RoundingMode`; the default, `RoundingMode.towardZero`, truncates.
+/
struct Decimal
{
    /// The value times 10^`scale`: at most 76 digits.
    Int256 unscaled;

    /++
    Position of the decimal point: the number of digits after it when positive;
    a negative scale multiplies the unscaled value by a power of ten. Between
    `-maxDecimalScale` and `maxDecimalScale`.
    +/
    int scale;

    /++
    Creates a value.

    Throws: `ClientException` if `unscaled` has more than 76 digits or `scale`
    is out of range.
    +/
    this(Int256 unscaled, int scale) @safe pure
    {
        checkScale(scale);
        if (unscaled > maxUnscaled || unscaled < minUnscaled)
            throw new ClientException("Decimal value has more than 76 digits: " ~ unscaled.toString());
        this.unscaled = unscaled;
        this.scale = scale;
    }

    /++
    Parses decimal text such as `"-12.345"`, exactly. The scale is the number
    of digits after the point.

    Throws: `ClientException` if the text is not a decimal number, has more
    than 76 significant digits, or more than `maxDecimalScale` digits after the point.
    +/
    static Decimal fromString(scope const(char)[] text) @safe
    {
        const parts = splitNumber(text);
        if (parts.fraction.length > maxDecimalScale)
            throw new ClientException("Decimal scale out of range: '" ~ text.idup ~ "'");
        return fromParts(text, parts, cast(int) parts.fraction.length, RoundingMode.towardZero);
    }

    /++
    Parses decimal text at the given scale. Digits beyond the scale are
    dropped according to `mode`; missing ones are zeros.

    Throws: `ClientException` if the text is not a decimal number, the scale is
    out of range, or the result has more than 76 digits.
    +/
    static Decimal fromString(scope const(char)[] text, int scale,
            RoundingMode mode = RoundingMode.towardZero) @safe
    {
        return fromParts(text, splitNumber(text), scale, mode);
    }

    /++
    Converts a `double` exactly (its binary value, e.g. 0.1 is
    0.1000000000000000055511151231257827…), then drops the digits beyond
    `scale` according to `mode`.

    Throws: `ClientException` if `value` is not finite, the scale is out of
    range, or the result has more than 76 digits.
    +/
    static Decimal fromDouble(double value, int scale, RoundingMode mode = RoundingMode.towardZero) @safe
    {
        import std.math : frexp, isFinite, ldexp;

        if (!isFinite(value))
            throw new ClientException("Cannot convert " ~ toText(value) ~ " to a decimal");
        checkScale(scale);
        // value = mantissa × 2^exponent with an integer mantissa (exact steps)
        int exponent;
        const mantissa = cast(long) ldexp(frexp(value, exponent), 53);
        exponent -= 53;
        BigInt exact = mantissa;
        int exactScale = 0;
        if (exponent >= 0)
            exact <<= exponent;
        else
        {
            // m / 2^k = m × 5^k / 10^k
            exact *= BigInt(5) ^^ (-exponent);
            exactScale = -exponent;
        }
        return Decimal(toUnscaled(shiftScale(exact, exactScale, scale, mode)), scale);
    }

    /// Converts a `long` (scale 0).
    static Decimal fromLong(long value) @safe pure
    {
        return Decimal(Int256(value), 0);
    }

    /++
    Creates a value from an unscaled `std.bigint.BigInt`, e.g. the result of
    arithmetic on `unscaled.toBigInt()`.

    Throws: `ClientException` if `unscaled` has more than 76 digits or `scale`
    is out of range.
    +/
    static Decimal fromBigInt(const BigInt unscaled, int scale) @safe
    {
        checkScale(scale);
        return Decimal(toUnscaled(unscaled), scale);
    }

    /++
    The value in plain notation without trailing zeros after the point, e.g.
    `"1.5"` for 1.50, `"100"` for 100.00 and `"5000"` for 5 with scale -3.
    This is how ClickHouse prints decimals.
    +/
    string toString() const @safe pure nothrow
    {
        Text text;
        return text.buffer[0 .. format(false, text)].idup;
    }

    /// The value with exactly `scale` digits after the point (none if the scale
    /// is not positive), e.g. `"1.50"`.
    string toFixedString() const @safe pure nothrow
    {
        Text text;
        return text.buffer[0 .. format(true, text)].idup;
    }

    /// The value as a `double`, correctly rounded (to the nearest, ties to even);
    /// infinite beyond the range of `double`.
    double toDouble() const @safe pure
    {
        import core.bitop : bsr;
        import std.math : ldexp;

        auto n = unscaled.toBigInt();
        if (n == 0)
            return 0.0;
        const negative = n < 0;
        if (negative)
            n = -n;
        // value = n / d, both integers
        auto d = BigInt(1);
        if (scale > 0)
            d = BigInt(10) ^^ scale;
        else
            n *= BigInt(10) ^^ -scale;
        // Scale by 2^k so that the quotient has 56 or 57 bits: 53 for the result, the
        // rest and the remainder decide the rounding
        const k = 56 - cast(long) bitLength(n) + cast(long) bitLength(d);
        if (k >= 0)
            n <<= k;
        else
            d <<= -k;
        const q = (n / d).getDigit!ulong(0); // below 2^57
        const sticky = n % d != 0;
        const drop = bsr(q) + 1 - 53; // 3 or 4
        ulong mantissa = q >> drop;
        const rest = q & ((1UL << drop) - 1);
        const half = 1UL << (drop - 1);
        if (rest > half || (rest == half && (sticky || (mantissa & 1))))
            mantissa++;
        const result = ldexp(cast(double) mantissa, cast(int)(drop - k));
        return negative ? -result : result;
    }

    /++
    The value as a `long`, rounded to an integer according to `mode`.

    Throws: `ClientException` if the result does not fit.
    +/
    long toLong(RoundingMode mode = RoundingMode.towardZero) const @safe
    {
        const whole = shiftScale(unscaled.toBigInt(), scale, 0, mode);
        if (whole < long.min || whole > long.max)
            throw new ClientException("Decimal value " ~ toString() ~ " does not fit in long");
        return whole.toLong();
    }

    /// Number of significant digits of the unscaled value (1 for zero).
    @property uint precision() const @safe pure nothrow
    {
        const digits = unscaled.toString();
        return cast(uint)(digits[0] == '-' ? digits[1 .. $].length : digits.length);
    }

    /++
    The same value with trailing zeros of the unscaled value removed (the
    scale decreases, down to `-maxDecimalScale`), e.g. 1.500 → 1.5 and
    1200 → 12 with scale -2. Zero becomes zero with scale 0.
    +/
    Decimal normalized() const @safe pure
    {
        const digits = unscaled.toString();
        if (digits == "0")
            return Decimal.init;
        size_t zeros;
        // digits != "0", so its first digit is not a zero
        while (digits[$ - 1 - zeros] == '0' && scale - cast(long) zeros > -maxDecimalScale)
            zeros++;
        return Decimal(Int256.fromString(digits[0 .. $ - zeros]), scale - cast(int) zeros);
    }

    /++
    The value at another scale. Digits beyond it are dropped according to `mode`.

    Throws: `ClientException` if the scale is out of range or the result has
    more than 76 digits.
    +/
    Decimal rescaled(int newScale, RoundingMode mode = RoundingMode.towardZero) const @safe
    {
        if (newScale == scale)
            return this;
        checkScale(newScale);
        return Decimal(toUnscaled(shiftScale(unscaled.toBigInt(), scale, newScale, mode)), newScale);
    }

    /// Numeric comparison, also across scales.
    int opCmp(const Decimal other) const @safe
    {
        if (scale == other.scale)
            return unscaled.opCmp(other.unscaled);
        auto a = unscaled.toBigInt();
        auto b = other.unscaled.toBigInt();
        if (scale < other.scale)
            a *= BigInt(10) ^^ (other.scale - scale);
        else
            b *= BigInt(10) ^^ (scale - other.scale);
        return a < b ? -1 : a > b ? 1 : 0;
    }

    /// Numeric equality: 1.5 equals 1.50.
    bool opEquals(const Decimal other) const @safe
    {
        return opCmp(other) == 0;
    }

    /// Hash consistent with numeric equality.
    size_t toHash() const @safe nothrow
    {
        Text text;
        return hashOf(text.buffer[0 .. format(false, text)]);
    }

    // Room for the longest text: a sign, "0.", the zeros a scale adds and all digits
    private static struct Text
    {
        char[1 + 2 + maxDecimalScale + maxDecimalDigits] buffer;
    }

    /// Writes the text into `text` and returns its length.
    private size_t format(bool fixed, ref Text text) const @safe pure nothrow @nogc
    {
        char[Int256.maxChars] digitBuffer;
        const(char)[] digits = digitBuffer[unscaled.formatTo(digitBuffer) .. $];
        if (digits == "0" && (scale <= 0 || !fixed))
        {
            text.buffer[0] = '0';
            return 1;
        }
        size_t pos;
        void put(scope const(char)[] part) @safe pure nothrow @nogc
        {
            text.buffer[pos .. pos + part.length] = part;
            pos += part.length;
        }

        void putZeros(size_t count) @safe pure nothrow @nogc
        {
            text.buffer[pos .. pos + count] = '0';
            pos += count;
        }

        if (digits[0] == '-')
        {
            put("-");
            digits = digits[1 .. $];
        }
        if (scale <= 0)
        {
            put(digits);
            putZeros(-scale);
            return pos;
        }
        const fractionDigits = cast(size_t) scale;
        if (digits.length > fractionDigits)
            put(digits[0 .. $ - fractionDigits]);
        else
            put("0");
        const dot = pos;
        put(".");
        if (digits.length < fractionDigits)
            putZeros(fractionDigits - digits.length);
        put(digits.length > fractionDigits ? digits[$ - fractionDigits .. $] : digits);
        if (!fixed)
            while (text.buffer[pos - 1] == '0')
                pos--;
        return text.buffer[pos - 1] == '.' ? dot : pos;
    }

    private static Decimal fromParts(scope const(char)[] text, scope const NumberParts parts, int scale,
            RoundingMode mode) @safe
    {
        checkScale(scale);
        // Split the digits into those kept at `scale` and those dropped
        scope const(char)[] kept, dropped;
        if (scale >= 0)
        {
            if (parts.fraction.length > scale)
            {
                kept = parts.integer ~ parts.fraction[0 .. scale];
                dropped = parts.fraction[scale .. $];
            }
            else
                kept = parts.integer ~ parts.fraction ~ zeros(scale - parts.fraction.length);
        }
        else
        {
            const k = -scale;
            kept = parts.integer.length < k ? zeros(k - parts.integer.length) ~ parts.integer : parts.integer;
            dropped = kept[$ - k .. $] ~ parts.fraction;
            kept = kept[0 .. $ - k];
        }
        const up = roundsUp(kept, dropped, mode);
        size_t first;
        while (first < kept.length && kept[first] == '0')
            first++;
        kept = kept[first .. $];
        if (kept.length > maxDecimalDigits)
            throw new ClientException("Decimal value has more than 76 digits: '" ~ text.idup ~ "'");
        if (kept.length == 0)
            kept = "0";
        if (!up)
            return Decimal(Int256.fromString((parts.negative ? "-" : "") ~ kept), scale);
        auto value = Int256.fromString(kept).toBigInt() + 1; // may reach 77 digits: checked by toUnscaled
        return Decimal(toUnscaled(parts.negative ? -value : value), scale);
    }
}

///
@safe unittest
{
    const price = Decimal.fromString("19.90");
    assert(price.scale == 2 && price.unscaled == Int256(1990));
    assert(price.toString() == "19.9" && price.toFixedString() == "19.90");
    assert(price == Decimal.fromString("19.9")); // numeric equality

    // Dropping digits: truncation by default, or rounding
    assert(Decimal.fromString("1.555", 2).toString() == "1.55");
    assert(Decimal.fromString("1.555", 2, RoundingMode.halfUp).toString() == "1.56");
    assert(price.rescaled(0, RoundingMode.halfEven).toString() == "20");

    // A negative scale: 12 × 10^3
    assert(Decimal(Int256(12), -3).toString() == "12000");
}

/// Whether dropping `dropped` (the digits after `kept`) rounds the magnitude up.
private bool roundsUp(scope const(char)[] kept, scope const(char)[] dropped, RoundingMode mode) @safe pure nothrow
{
    if (mode == RoundingMode.towardZero || dropped.length == 0)
        return false;
    if (dropped[0] != '5')
        return dropped[0] > '5';
    foreach (c; dropped[1 .. $])
        if (c != '0')
            return true;
    // Exactly half way
    if (mode == RoundingMode.halfUp)
        return true;
    const last = kept.length ? kept[$ - 1] : '0';
    return (last - '0') % 2 == 1;
}

/// `value × 10^-fromScale` expressed at `toScale`, rounded according to `mode`.
private BigInt shiftScale(const BigInt value, long fromScale, long toScale, RoundingMode mode) @safe
{
    if (toScale >= fromScale)
        return value * BigInt(10) ^^ (toScale - fromScale);
    const divisor = BigInt(10) ^^ (fromScale - toScale);
    auto quotient = value / divisor; // truncates towards zero
    if (mode == RoundingMode.towardZero)
        return quotient;
    auto remainder = value % divisor; // has the sign of value
    if (remainder < 0)
        remainder = -remainder;
    const twice = remainder * 2;
    const up = twice > divisor || (twice == divisor && (mode == RoundingMode.halfUp || (quotient % 2) != 0));
    if (up)
        quotient += value < 0 ? -1 : 1;
    return quotient;
}

/// The parts of decimal text: sign, digits before and after the point.
private struct NumberParts
{
    bool negative;
    const(char)[] integer;
    const(char)[] fraction;
}

private NumberParts splitNumber(scope return const(char)[] text) @safe
{
    ClientException error()
    {
        return new ClientException("Cannot parse '" ~ text.idup ~ "' as a decimal number");
    }

    NumberParts parts;
    size_t pos;
    if (text.length && (text[0] == '-' || text[0] == '+'))
    {
        parts.negative = text[0] == '-';
        pos = 1;
    }
    const start = pos;
    while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
        pos++;
    parts.integer = text[start .. pos];
    if (pos < text.length && text[pos] == '.')
    {
        const fractionStart = ++pos;
        while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
            pos++;
        parts.fraction = text[fractionStart .. pos];
    }
    if (pos != text.length || parts.integer.length + parts.fraction.length == 0)
        throw error();
    if (parts.integer.length == 0)
        parts.integer = "0";
    return parts;
}

/// Number of significant bits of `value`, which is not negative.
private size_t bitLength(const BigInt value) @safe pure nothrow
{
    import core.bitop : bsr;

    const words = value.ulongLength;
    const top = value.getDigit!ulong(words - 1);
    return top == 0 ? 0 : (words - 1) * 64 + bsr(top) + 1;
}

private void checkScale(long scale) @safe pure
{
    if (scale > maxDecimalScale || scale < -maxDecimalScale)
        throw new ClientException("Decimal scale out of range: " ~ toText(scale));
}

/// Converts an unscaled `BigInt` to `Int256`, checking the 76-digit limit.
private Int256 toUnscaled(const BigInt value) @safe
{
    import std.bigint : toDecimalString;

    ClientException tooLong()
    {
        return new ClientException("Decimal value has more than 76 digits: " ~ value.toDecimalString());
    }

    Int256 result;
    try
        result = Int256.fromBigInt(value);
    catch (ClientException)
        throw tooLong(); // beyond 256 bits
    if (result > maxUnscaled || result < minUnscaled)
        throw tooLong();
    return result;
}

/// The largest and smallest unscaled values: ±(10^76 - 1).
private enum Int256 maxUnscaled = Int256.fromString(nines(maxDecimalDigits));
/// ditto
private enum Int256 minUnscaled = Int256.fromString("-" ~ nines(maxDecimalDigits));

private string nines(size_t count) @safe pure nothrow
{
    import std.array : replicate;

    return "9".replicate(count);
}

private string zeros(size_t count) @safe pure nothrow
{
    import std.array : replicate;

    return "0".replicate(count);
}

private string toText(T)(T value) @safe
{
    import std.conv : to;

    return value.to!string;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Formatting (as ClickHouse prints decimals, checked on 23.8 and 26.11)
    assert(Decimal.fromString("-0.05").toString() == "-0.05");
    assert(Decimal(Int256(0), 4).toString() == "0" && Decimal(Int256(100), 0).toString() == "100");
    assert(Decimal(Int256(1_000_000_000), 9).toString() == "1");
    assert(Decimal.fromString("-12345678901234567890.123456789").toString() == "-12345678901234567890.123456789");
    assert(Decimal(Int256(-5), 3).toFixedString() == "-0.005");

    // Parsing
    assert(Decimal.fromString("+.5").toString() == "0.5" && Decimal.fromString("7.").toString() == "7");
    assert(Decimal.fromString("-1.555", 2).toString() == "-1.55");
    assert(Decimal.fromString("1.5", 4).unscaled == Int256(15_000));
    assert(Decimal.fromString("-0.001", 2).unscaled == Int256(0));
    foreach (bad; ["", "-", ".", "1e5", " 1", "1.2.3", "abc", "1,5"])
        assertThrown!ClientException(Decimal.fromString(bad), bad);
    char[77] tooLong = '9';
    assertThrown!ClientException(Decimal.fromString(tooLong[]));
    assert(Decimal.fromString(tooLong[0 .. 76]).toString().length == 76);
    assert(Decimal.fromString("000" ~ tooLong[0 .. 76]).precision == 76); // leading zeros don't count

    // Rescaling, comparison, doubles
    assert(Decimal.fromString("1.999").rescaled(1).toString() == "1.9");
    assert(Decimal.fromString("-1.999").rescaled(0).toString() == "-1");
    assert(Decimal.fromString("2.5").rescaled(3).unscaled == Int256(2500));
    assert(Decimal.fromString("1.5") < Decimal.fromString("1.51"));
    assert(Decimal.fromString("-2") < Decimal.fromString("1"));
    assert(Decimal.fromString("1.50").toHash() == Decimal.fromString("1.5").toHash());
    assert(Decimal.fromDouble(0.1, 2).toString() == "0.1" && Decimal.fromDouble(-2.675, 2).toString() == "-2.67");
    assert(Decimal.fromString("-2.25").toDouble() == -2.25);
    assert(Decimal.fromString("0").toDouble() == 0 && Decimal.fromString("0.1").toDouble() == 0.1);
    // Correctly rounded where parsing the text went 1 ulp off (to!double, and the compiler for the
    // decimal literal: both give 0x1.dec0290b0075ep+112)
    assert(Decimal.fromString("9710216299933997739814797659952605.8").toDouble() == 0x1.dec0290b0075dp+112);
    // Ties go to even: 2^53 + 1 and 2^53 + 3 lie halfway between doubles
    assert(Decimal.fromString("9007199254740993").toDouble() == 9_007_199_254_740_992.0);
    assert(Decimal.fromString("9007199254740995").toDouble() == 9_007_199_254_740_996.0);
    assert(Decimal.fromString("9007199254740993.000001").toDouble() == 9_007_199_254_740_994.0);
    // The extremes: 10^330 is beyond double, 10^-255 within
    assert(Decimal.fromBigInt(-BigInt(10) ^^ 75, -maxDecimalScale).toDouble() == -double.infinity);
    const tiny = Decimal(Int256(1), maxDecimalScale).toDouble();
    assert(tiny > 0.99e-255 && tiny < 1.01e-255);
    assertThrown!ClientException(Decimal.fromDouble(double.nan, 2));
    assertThrown!ClientException(Decimal.fromDouble(-double.infinity, 2));
}

@safe unittest
{
    // Rounding modes when parsing
    alias M = RoundingMode;
    string round(string text, int scale, M mode)
    {
        return Decimal.fromString(text, scale, mode).toString();
    }

    assert(round("1.25", 1, M.towardZero) == "1.2" && round("1.25", 1, M.halfUp) == "1.3");
    assert(round("1.25", 1, M.halfEven) == "1.2" && round("1.35", 1, M.halfEven) == "1.4");
    assert(round("-1.25", 1, M.halfUp) == "-1.3" && round("-1.25", 1, M.halfEven) == "-1.2");
    assert(round("1.2500001", 1, M.halfEven) == "1.3" && round("1.2499999", 1, M.halfUp) == "1.2");
    assert(round("0.05", 1, M.halfEven) == "0" && round("0.15", 1, M.halfEven) == "0.2");
    assert(round("0.05", 1, M.halfUp) == "0.1" && round("-0.05", 1, M.halfUp) == "-0.1");
    assert(round("9.99", 1, M.halfUp) == "10" && round("2", 3, M.halfUp) == "2");

    // Negative scales: rounding to tens, hundreds, ...
    assert(Decimal.fromString("12345", -2) == Decimal(Int256(123), -2));
    assert(round("12345", -2, M.towardZero) == "12300" && round("12350", -2, M.halfUp) == "12400");
    assert(round("12350", -2, M.halfEven) == "12400" && round("12250", -2, M.halfEven) == "12200");
    assert(round("12250", -2, M.halfUp) == "12300" && round("12249.9", -2, M.halfUp) == "12200");
    assert(round("5", -1, M.halfUp) == "10" && round("-5", -1, M.halfUp) == "-10");
    assert(round("4", -1, M.halfUp) == "0" && round("0.7", -3, M.halfUp) == "0");

    // Rounding up may need a 77th digit
    char[76] nines = '9';
    assert(Decimal.fromString(nines[] ~ ".9", 0).precision == 76);
    import std.exception : assertThrown;

    assertThrown!ClientException(Decimal.fromString(nines[] ~ ".9", 0, M.halfUp));
}

@safe unittest
{
    import std.exception : assertThrown;

    alias M = RoundingMode;

    // Negative scales
    const thousands = Decimal(Int256(5), -3);
    assert(thousands.toString() == "5000" && thousands.toFixedString() == "5000");
    assert(thousands == Decimal.fromString("5000") && thousands.toHash() == Decimal.fromString("5000.0").toHash());
    assert(Decimal(Int256(-12), -2).toString() == "-1200" && Decimal(Int256(0), -5).toString() == "0");
    assert(Decimal(Int256(1), -1) > Decimal.fromString("9.99"));
    assert(thousands.toDouble() == 5000.0 && thousands.toLong() == 5000);

    // Scale and digit limits
    assert(Decimal(Int256(1), maxDecimalScale).toString().length == maxDecimalScale + 2);
    assert(Decimal(Int256(1), -maxDecimalScale).toString().length == maxDecimalScale + 1);
    assertThrown!ClientException(Decimal(Int256(1), maxDecimalScale + 1));
    assertThrown!ClientException(Decimal(Int256(1), -maxDecimalScale - 1));
    assertThrown!ClientException(Decimal(Int256.max, 0)); // 77 digits
    char[256] longFraction = '0';
    assertThrown!ClientException(Decimal.fromString("0." ~ longFraction[]));
    assert(Decimal.fromString("0." ~ longFraction[0 .. 255]).scale == 255);
    assertThrown!ClientException(Decimal.fromString("1", 256));

    // precision, normalized
    assert(Decimal.fromString("-123.45").precision == 5 && Decimal.init.precision == 1);
    auto n = Decimal.fromString("1.500").normalized();
    assert(n.unscaled == Int256(15) && n.scale == 1);
    n = Decimal(Int256(1200), 0).normalized();
    assert(n.unscaled == Int256(12) && n.scale == -2);
    n = Decimal(Int256(0), 5).normalized();
    assert(n.unscaled == Int256(0) && n.scale == 0);
    n = Decimal(Int256(100), 1 - maxDecimalScale).normalized(); // stops at the smallest scale
    assert(n.unscaled == Int256(10) && n.scale == -maxDecimalScale);

    // rescaled with rounding
    assert(Decimal.fromString("2.345").rescaled(2, M.halfEven).toString() == "2.34");
    assert(Decimal.fromString("2.345").rescaled(2, M.halfUp).toString() == "2.35");
    assert(Decimal.fromString("-2.345").rescaled(2, M.halfUp).toString() == "-2.35");
    assert(Decimal.fromString("15").rescaled(-1, M.halfUp) == Decimal(Int256(2), -1));
    assert(Decimal(Int256(5), -3).rescaled(2).unscaled == Int256(500_000));
    assertThrown!ClientException(Decimal(Int256(1), -80).rescaled(0)); // 81 digits

    // toLong, fromLong, fromBigInt
    assert(Decimal.fromString("2.5").toLong() == 2 && Decimal.fromString("2.5").toLong(M.halfUp) == 3);
    assert(Decimal.fromString("2.5").toLong(M.halfEven) == 2 && Decimal.fromString("-2.5").toLong(M.halfUp) == -3);
    assert(Decimal(Int256(1), 30).toLong() == 0);
    assert(Decimal.fromString("9223372036854775807.9").toLong() == long.max);
    assertThrown!ClientException(Decimal.fromString("9223372036854775808").toLong());
    assertThrown!ClientException(Decimal(Int256(1), -30).toLong());
    assert(Decimal.fromLong(long.min).toString() == "-9223372036854775808");
    assert(Decimal.fromBigInt(BigInt("-123456"), 3).toString() == "-123.456");
    assertThrown!ClientException(Decimal.fromBigInt(BigInt(10) ^^ 76, 0));
}

@safe unittest
{
    alias M = RoundingMode;

    // fromDouble works on the exact binary value
    assert(Decimal.fromDouble(0.1, 20).toString() == "0.10000000000000000555"); // truncated
    assert(Decimal.fromDouble(0.125, 2, M.halfEven).toString() == "0.12"); // an exact tie
    assert(Decimal.fromDouble(0.125, 2, M.halfUp).toString() == "0.13");
    assert(Decimal.fromDouble(-2.675, 2, M.halfUp).toString() == "-2.67"); // just below the tie
    assert(Decimal.fromDouble(2.5, 0, M.halfEven).toString() == "2");
    assert(Decimal.fromDouble(2.5, 0, M.halfUp).toString() == "3");
    assert(Decimal.fromDouble(1e20, -18) == Decimal(Int256(100), -18));
    assert(Decimal.fromDouble(double.min_normal * double.epsilon, 2).toString() == "0" && Decimal.fromDouble(-0.0, 3)
            .toString() == "0");
    assert(Decimal.fromDouble(123_456.75, 1, M.halfEven).toString() == "123456.8");
    assert(Decimal.fromDouble(double.max, -maxDecimalScale).precision == 54);
}

// toDouble against glibc's strtod, which rounds correctly
version (CRuntime_Glibc) @safe unittest
{
    import core.stdc.stdlib : strtod;
    import std.random : Mt19937, uniform;
    import std.string : toStringz;

    auto rng = Mt19937(42);
    foreach (_; 0 .. 20_000)
    {
        char[] digits;
        foreach (i; 0 .. uniform(1, maxDecimalDigits + 1, rng))
            digits ~= cast(char)('0' + uniform(0, 10, rng));
        const d = Decimal.fromBigInt(BigInt(digits.idup), uniform(-40, 80, rng));
        const text = d.toString();
        const expected = (() @trusted => strtod(text.toStringz, null))();
        assert(d.toDouble() == expected, text);
    }
}
