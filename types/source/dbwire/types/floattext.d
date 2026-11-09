/++
The shortest decimal digits of a `float` or `double`: the fewest significant
digits that read back as exactly the same value, the closest such digits if
there are several. Connectors build their servers' text of floating-point
values on them; the notation (plain or exponent, NaN, infinities, signs)
differs by server and stays in each connector.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.types.floattext;

import std.bigint : BigInt;

/++
The result of `shortestDigits`: significant digits and the position of the
decimal point, so that the value is `0.digits × 10^pointPos`. For example
`123.45` has the digits `12345` and `pointPos` 3, `0.001` the digits `1` and
`pointPos` -2.
+/
struct ShortestDigits
{
    /++
    The digits are `buffer[0 .. length]`; see `digits`. Neither the first nor
    the last one is `'0'`, except for zero itself. A `double` needs at most 17
    digits, a `float` 9. NaN and infinities have no digits.
    +/
    char[17] buffer;
    ubyte length; /// ditto
    int pointPos; /// The position of the decimal point: the value is `0.digits × 10^pointPos`.

    /// Compares the digits and the point position (not the unused part of `buffer`).
    bool opEquals(const ShortestDigits other) const @safe pure nothrow @nogc
    {
        return pointPos == other.pointPos && buffer[0 .. length] == other.buffer[0 .. other.length];
    }

    /// ditto
    size_t toHash() const @safe pure nothrow @nogc
    {
        return hashOf(buffer[0 .. length], pointPos);
    }
}

/++
The digits of `d`, `d.buffer[0 .. d.length]`, e.g. `d.digits` for a local
`d`. The slice points into `d`, so `d` must outlive it; `d` is taken by `ref`
so that the slice can't point into a temporary (`shortestDigits(x).digits`
doesn't compile).
+/
const(char)[] digits()(ref const ShortestDigits d)
{
    return d.buffer[0 .. d.length];
}

/++
How text exactly halfway between two neighbouring values reads back; see
`shortestDigits`.
+/
enum Ties : ubyte
{
    /++
    As the neighbour with the even mantissa (round half to even), as `strtod`
    reads it. The shortest digits may then be such a midpoint; ClickHouse
    writes them.
    +/
    toEven,
    /++
    Never as the value: the digits are never a midpoint, so they read back
    whatever rule the reader uses for ties. PostgreSQL writes these for
    `float4` and `float8` (Ryu with `acceptBounds = false` in its `f2s.c` and
    `d2s.c`; checked against PostgreSQL 13 and 18), e.g.
    `-3.6681927456064224e+16` rather than the shorter midpoint
    `-3.668192745606422e+16`.
    +/
    avoid,
}

/++
The shortest decimal digits that read back as `value`, with the position of
the decimal point. Reading text back means rounding to the nearest `T`;
`ties` says whether text exactly halfway between `value` and a neighbour
counts as reading back. Among several shortest digit strings that read back,
it takes the one closest to `value`, and the one with the even last digit if
two are equally close (in both modes).

The sign is ignored, zero gives the digit `0` with `pointPos` 1, and NaN and
infinities give no digits: callers write the sign, zero, NaN and infinities
themselves, since servers write them differently.

The result is exact for every value. Moderate magnitudes (nearly every
`float`, doubles from about 1e-20 to 1e35) run on 128-bit integers and don't
allocate; the others need `BigInt`, so the function isn't `@nogc`.
+/
ShortestDigits shortestDigits(T)(const T value, Ties ties = Ties.toEven)
        if (is(T == float) || is(T == double))
{
    import std.math : isFinite;

    ShortestDigits result;
    if (!isFinite(value))
        return result;
    if (value == 0)
    {
        result.buffer[0] = '0';
        result.length = 1;
        result.pointPos = 1;
        return result;
    }
    const input = digitInput(value < 0 ? -value : value, ties);
    const generated = generateDigits!U128(input, result) || generateDigits!BigInt(input, result);
    assert(generated, "the digit generation failed");
    return result;
}

///
@safe pure unittest
{
    const d = shortestDigits(123.45);
    assert(d.digits == "12345" && d.pointPos == 3);

    double sum = 0.1;
    sum += 0.2; // at run time: a constant expression would be folded with real precision
    const s = shortestDigits(sum);
    assert(s.digits == "30000000000000004" && s.pointPos == 0);

    // A float needs fewer digits than the same number as a double
    const f = shortestDigits(0.1f);
    assert(f.digits == "1" && f.pointPos == 0);
    const g = shortestDigits(0x1.99999ap-4); // 0.1f as a double
    assert(g.digits == "10000000149011612" && g.pointPos == 0);
}

@safe pure nothrow unittest
{
    import std.math : isNaN;

    // Locks in the inferred attributes
    assert(shortestDigits(1.5).pointPos == 1);
    const big = shortestDigits(1e300);
    assert(big.digits == "1" && big.pointPos == 301);

    // The sign is ignored; zero, NaN and infinities
    assert(shortestDigits(-1.5) == shortestDigits(1.5));
    const zero = shortestDigits(-0.0f);
    assert(zero.digits == "0" && zero.pointPos == 1);
    assert(shortestDigits(double.nan).length == 0 && shortestDigits(-float.infinity).length == 0);

    // Equality ignores the unused part of the buffer
    ShortestDigits expected;
    expected.buffer[] = '\0';
    expected.buffer[0 .. 2] = "15";
    expected.length = 2;
    expected.pointPos = 1;
    assert(expected == shortestDigits(1.5) && expected.toHash == shortestDigits(1.5f).toHash);

    // No slice of a temporary
    static assert(!__traits(compiles, shortestDigits(1.5).digits));
}

/// The value `f × 2^e` to generate digits for, and its properties; see `shortestDigits`.
private struct DigitInput
{
    ulong f; // mantissa, with the hidden bit
    int e; // binary exponent
    bool acceptMidpoints; // whether text halfway to a neighbour reads back as the value
    bool narrowBelow; // at a power of two: the gap to the next smaller value is half the one above
    int k; // estimated decimal exponent
}

/// The `DigitInput` of `value` (positive and finite).
private DigitInput digitInput(T)(const T value, Ties ties)
{
    import std.math : ceil, log10;

    static if (is(T == float))
    {
        import std.bitmanip : FloatRep;

        enum mantissaBits = 23, bias = 127;
        FloatRep rep;
    }
    else
    {
        import std.bitmanip : DoubleRep;

        enum mantissaBits = 52, bias = 1023;
        DoubleRep rep;
    }
    rep.value = value;
    DigitInput input;
    input.f = rep.fraction;
    if (rep.exponent == 0)
        input.e = 1 - bias - mantissaBits; // subnormal
    else
    {
        input.f |= 1UL << mantissaBits;
        input.e = rep.exponent - bias - mantissaBits;
    }
    // Round half to even: the midpoints read back as the value when its mantissa is even
    input.acceptMidpoints = ties == Ties.toEven && (input.f & 1) == 0;
    // At a power of two the neighbour below is closer: half the gap above
    input.narrowBelow = rep.fraction == 0 && rep.exponent > 1;
    // An estimate of the decimal exponent; the digit generation corrects it exactly
    input.k = cast(int) ceil(log10(cast(double) value) - 1e-10);
    return input;
}

/++
Generates the digits of `input` with integers of type `N` (`U128` or
`BigInt`). Returns: false if `U128` overflowed (`result` is undefined then).

This is the free-format digit generation of Steele and White, with exact
integer arithmetic: `r / s` is the value, `mPlus / s` and `mMinus / s` are
the distances to the midpoints between the value and its neighbours. The
midpoints themselves count as reading back when `input.acceptMidpoints` is
set (round half to even and an even mantissa). `U128` covers nearly every `float` and the
doubles from about 1e-20 to 1e35; both types give the same digits.
+/
private bool generateDigits(N)(const DigitInput input, out ShortestDigits result)
{
    N r = N(input.f), s = N(1), mPlus = N(1), mMinus = N(1);
    bool failed()
    {
        static if (is(N == U128))
            return r.bad || s.bad || mPlus.bad || mMinus.bad;
        else
            return false;
    }

    if (input.e >= 0)
    {
        r <<= input.e;
        mPlus <<= input.e;
        mMinus <<= input.e;
    }
    else
        s <<= -input.e;
    // Scale by 2 (by 4 at a power of two) so that the half gaps are whole numbers
    r <<= input.narrowBelow ? 2 : 1;
    s <<= input.narrowBelow ? 2 : 1;
    if (input.narrowBelow)
        mPlus <<= 1;
    if (failed())
        return false; // most doubles beyond about 1e35 or below 1e-20 stop here

    int k = input.k;
    if (k >= 0)
        multiplyByPow10(s, k);
    else
    {
        multiplyByPow10(r, -k);
        multiplyByPow10(mPlus, -k);
        multiplyByPow10(mMinus, -k);
    }
    if (failed())
        return false;
    // Whether `a` reaches the bound `b`: the midpoints count as reading back only with acceptMidpoints
    bool reaches(const N a, const N b)
    {
        return input.acceptMidpoints ? a >= b : a > b;
    }

    while (reaches(r + mPlus, s))
    {
        s *= 10;
        k++;
        if (failed())
            return false;
    }
    for (;;)
    {
        const top = (r + mPlus) * 10;
        static if (is(N == U128))
            if (top.bad)
                return false;
        if (reaches(top, s))
            break;
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        k--;
        if (failed())
            return false;
    }

    char[24] buffer = void; // at most 17 significant digits for a double, 9 for a float
    size_t count;
    for (;;)
    {
        if (count == buffer.length)
            return false; // cannot happen for shortest digits; never write past the buffer
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        int d = takeDigit(r, s);
        const top = r + mPlus;
        if (failed() || d > 9)
            return false;
        static if (is(N == U128))
            if (top.bad)
                return false;
        const low = reaches(mMinus, r);
        const high = reaches(top, s);
        if (!low && !high)
        {
            buffer[count++] = cast(char)('0' + d);
            continue;
        }
        if (high && !low)
            d++;
        else if (high && low)
        {
            // Both last digits read back: take the closer one, the even one on a tie
            const twice = r + r;
            static if (is(N == U128))
                if (twice.bad)
                    return false;
            if (twice > s || (twice == s && (d & 1) != 0))
                d++;
        }
        buffer[count++] = cast(char)('0' + d);
        break;
    }
    return carry(buffer[0 .. count], k, result);
}

/// `x × 10^n`.
private void multiplyByPow10(N)(ref N x, int n)
{
    static if (is(N == BigInt))
        x *= BigInt(10) ^^ n;
    else
    {
        for (; n >= 19; n -= 19)
            x *= 10_000_000_000_000_000_000UL;
        ulong p = 1;
        foreach (_; 0 .. n)
            p *= 10;
        x *= p;
    }
}

/// The digit `r / s` (below 10 when the digit generation is right), leaving the remainder in `r`.
private int takeDigit(N)(ref N r, N s)
{
    static if (is(N == BigInt))
    {
        import std.bigint : divMod;

        BigInt q, remainder;
        divMod(r, s, q, remainder);
        r = remainder;
        return cast(int) q.toLong();
    }
    else
    {
        int q;
        while (r >= s && q < 10)
        {
            r = r - s;
            q++;
        }
        return q;
    }
}

/++
An unsigned 128-bit integer with the operations of the digit generation.
An operation whose result does not fit sets `bad`, which every later result
inherits; the caller then starts again with `BigInt`.
+/
private struct U128
{
    ulong hi; ///
    ulong lo; ///
    bool bad; /// a result did not fit: the value is meaningless

    this(ulong value) @safe pure nothrow @nogc
    {
        lo = value;
    }

    U128 opBinary(string op : "+")(const U128 b) const @safe pure nothrow @nogc
    {
        U128 sum;
        sum.lo = lo + b.lo;
        const carry = sum.lo < lo ? 1 : 0;
        sum.hi = hi + b.hi + carry;
        sum.bad = bad || b.bad || sum.hi < hi || (sum.hi == hi && (b.hi != 0 || carry != 0));
        return sum;
    }

    /// `this - b`, for `this >= b`.
    U128 opBinary(string op : "-")(const U128 b) const @safe pure nothrow @nogc
    {
        U128 difference;
        difference.lo = lo - b.lo;
        difference.hi = hi - b.hi - (lo < b.lo ? 1 : 0);
        difference.bad = bad || b.bad;
        return difference;
    }

    U128 opBinary(string op : "*")(ulong m) const @safe pure nothrow @nogc
    {
        const low = multiply(lo, m);
        const high = multiply(hi, m);
        U128 product;
        product.lo = low.low;
        product.hi = high.low + low.high;
        product.bad = bad || high.high != 0 || product.hi < high.low;
        return product;
    }

    void opOpAssign(string op : "*")(ulong m) @safe pure nothrow @nogc
    {
        this = this * m;
    }

    void opOpAssign(string op : "<<")(int n) @safe pure nothrow @nogc
    {
        if (n == 0)
            return;
        if (n >= 128)
        {
            bad = bad || hi != 0 || lo != 0;
            hi = lo = 0;
            return;
        }
        if (n >= 64)
        {
            bad = bad || hi != 0 || (n > 64 && (lo >> (128 - n)) != 0);
            hi = lo << (n - 64);
            lo = 0;
            return;
        }
        bad = bad || (hi >> (64 - n)) != 0;
        hi = hi << n | lo >> (64 - n);
        lo <<= n;
    }

    int opCmp(const U128 b) const @safe pure nothrow @nogc
    {
        if (hi != b.hi)
            return hi < b.hi ? -1 : 1;
        return lo < b.lo ? -1 : lo > b.lo ? 1 : 0;
    }

    /// The two 64-bit halves of a 128-bit product.
    private static struct Product
    {
        ulong high;
        ulong low;
    }

    /// `a × b`.
    private static Product multiply(ulong a, ulong b) @safe pure nothrow @nogc
    {
        const aLow = a & 0xFFFF_FFFF, aHigh = a >> 32;
        const bLow = b & 0xFFFF_FFFF, bHigh = b >> 32;
        const ll = aLow * bLow, lh = aLow * bHigh, hl = aHigh * bLow, hh = aHigh * bHigh;
        const middle = (ll >> 32) + (lh & 0xFFFF_FFFF) + (hl & 0xFFFF_FFFF);
        return Product(hh + (lh >> 32) + (hl >> 32) + (middle >> 32), (middle << 32) | (ll & 0xFFFF_FFFF));
    }
}

/++
Propagates a last digit of 10 left (moving the point if a new digit appears),
drops trailing zeros and stores the digits in `result`. Returns: false if
there are more digits than `result` holds (never for shortest digits).
+/
private bool carry(char[] digits, int pointPos, ref ShortestDigits result) @safe pure nothrow @nogc
{
    size_t i = digits.length;
    while (i > 0 && digits[i - 1] > '9')
    {
        i--;
        if (i == 0)
        {
            digits[0] = '1';
            i = 1;
            pointPos++;
            break;
        }
        digits[i - 1]++;
    }
    while (i > 1 && digits[i - 1] == '0')
        i--;
    if (i > result.buffer.length)
        return false;
    result.buffer[0 .. i] = digits[0 .. i];
    result.length = cast(ubyte) i;
    result.pointPos = pointPos;
    return true;
}

@safe pure unittest
{
    // The exact digits at the edges, checked against ClickHouse's and PostgreSQL's text
    static void check(T)(T value, string digits, int pointPos)
    {
        const d = shortestDigits(value);
        assert(d.digits == digits && d.pointPos == pointPos);
    }

    check(1e20, "1", 21);
    check(1.23e21, "123", 22);
    check(1e-6, "1", -5);
    check(1.5e-6, "15", -5);
    check(12_345.678, "12345678", 5);
    check(1.2345678901234569e23, "12345678901234569", 24);
    check(double.max, "17976931348623157", 309);
    check(double.min_normal, "22250738585072014", -307);
    check(double.min_normal * double.epsilon, "5", -323); // smallest subnormal double
    check(float.min_normal * float.epsilon, "1", -44); // smallest subnormal float
    check(float.max, "34028235", 39);
    check(9.958967e-11f, "9958967", -10);
    check(0.33203125f, "33203125", 0);
    check(123_207_680.0f, "12320768", 9);
    check(16_777_216.0f, "16777216", 8);
    check(2.0 ^^ 63, "9223372036854776", 19);
    check(2.0f ^^ -10, "9765625", -3);
    check(9_999_220_736.0f, "9999221", 10);
    check(1.0, "1", 1);
    check(9.5, "95", 1);
}

@safe unittest
{
    import std.math : ldexp;

    // The 128-bit path, where it fits, gives exactly the digits of the BigInt path
    foreach (ties; [Ties.toEven, Ties.avoid])
    {
        size_t fast;
        foreach (exponent; -120 .. 130)
            foreach (j; 0 .. 40)
            {
                const value = ldexp(1.0 + j / 41.0, exponent); // j = 0: powers of two
                const input = digitInput(value, ties);
                ShortestDigits viaU128, viaBigInt;
                assert(generateDigits!BigInt(input, viaBigInt));
                if (generateDigits!U128(input, viaU128))
                {
                    fast++;
                    assert(viaU128 == viaBigInt);
                }
            }
        assert(fast > 5000); // most of these magnitudes take the fast path
    }

    // U128 arithmetic and overflow detection
    auto x = U128(ulong.max);
    x *= 10;
    assert(!x.bad && x.hi == 9 && x.lo == ulong.max - 9);
    auto y = x;
    y <<= 60;
    assert(!y.bad);
    y <<= 8;
    assert(y.bad);
    auto big = U128(1);
    big <<= 127;
    assert(!big.bad && (big + big).bad && !(big + U128(1)).bad);
    assert((big * 2).bad && (U128(5) - U128(3)) == U128(2) && U128(3) < U128(5));
}

@system unittest
{
    import core.stdc.stdio : snprintf;
    import core.stdc.stdlib : strtod, strtof;
    import std.random : Mt19937_64, uniform;

    // Random bit patterns: the digits read back exactly (C strtod/strtof round correctly), and
    // one digit fewer, correctly rounded by printf, doesn't
    static double readBack(const(char)[] digits, int pointPos, bool single)
    {
        char[48] text;
        const n = snprintf(text.ptr, text.length, "0.%.*se%d", cast(int) digits.length, digits.ptr, pointPos);
        assert(n > 0 && n < text.length);
        return single ? strtof(text.ptr, null) : strtod(text.ptr, null);
    }

    static bool shorterReadsBack(T)(T value, size_t length)
    {
        if (length == 1)
            return false;
        char[48] text;
        const n = snprintf(text.ptr, text.length, "%.*e", cast(int) length - 2, cast(double) value);
        assert(n > 0 && n < text.length);
        static if (is(T == float))
            return strtof(text.ptr, null) == value;
        else
            return strtod(text.ptr, null) == value;
    }

    static void check(T)(const T value)
    {
        const d = shortestDigits(value);
        assert(readBack(d.digits, d.pointPos, is(T == float)) == value);
        assert(!shorterReadsBack(value, d.length));
        if (value == T.max)
            return; // isMidpoint needs the neighbour above
        // Ties.avoid: never a midpoint, still reads back, and differs only where toEven gives a midpoint
        const a = shortestDigits(value, Ties.avoid);
        assert(readBack(a.digits, a.pointPos, is(T == float)) == value);
        assert(!isMidpoint(a.digits, a.pointPos, value));
        assert(a == d || (isMidpoint(d.digits, d.pointPos, value) && a.length > d.length));
    }

    auto rng = Mt19937_64(20_261_109);
    foreach (_; 0 .. 20_000)
    {
        const bits = uniform!ulong(rng);
        const value = *cast(const double*)&bits;
        if (value > 0 && value <= double.max)
            check(value);
    }
    foreach (_; 0 .. 20_000)
    {
        const bits = uniform!uint(rng);
        const value = *cast(const float*)&bits;
        if (value > 0 && value <= float.max)
            check(value);
    }
    foreach (value; [double.min_normal, double.max, double.min_normal * double.epsilon])
        check(value);
    foreach (value; [float.min_normal, float.max, float.min_normal * float.epsilon])
        check(value);

    // Few random values give a midpoint with toEven; a strided scan of the floats finds a few hundred
    size_t midpoints;
    for (ulong bits = 1; bits < 0x7F80_0000; bits += 16_411)
    {
        const uint word = cast(uint) bits;
        const value = *cast(const float*)&word;
        const d = shortestDigits(value);
        const a = shortestDigits(value, Ties.avoid);
        if (a == d)
            continue;
        midpoints++;
        assert(isMidpoint(d.digits, d.pointPos, value) && !isMidpoint(a.digits, a.pointPos, value));
        assert(a.length > d.length && readBack(a.digits, a.pointPos, true) == value);
    }
    assert(midpoints > 100);
}

// Whether `0.digits × 10^pointPos` is exactly halfway between `value` (positive and below `T.max`, subnormals
// included) and one of its neighbours.
version (unittest) private bool isMidpoint(T)(const(char)[] digits, int pointPos, T value)
{
    import std.math : nextDown, nextUp;

    assert(value > 0 && value < T.max, "isMidpoint needs a neighbour above");

    foreach (neighbour; [nextDown(value), nextUp(value)])
    {
        const x = digitInput(value, Ties.toEven);
        // Below the smallest subnormal is zero, which digitInput doesn't take
        const y = neighbour > 0 ? digitInput(neighbour, Ties.toEven) : DigitInput(0, x.e);
        const e = x.e < y.e ? x.e : y.e;
        // decimal × 2 against (value + neighbour) = sum × 2^e
        BigInt left = BigInt(digits) * 2;
        BigInt right = (BigInt(x.f) << (x.e - e)) + (BigInt(y.f) << (y.e - e));
        const exponent10 = pointPos - cast(int) digits.length;
        if (exponent10 >= 0)
            left *= BigInt(10) ^^ exponent10;
        else
            right *= BigInt(10) ^^ -exponent10;
        if (e >= 0)
            right <<= e;
        else
            left <<= -e;
        if (left == right)
            return true;
    }
    return false;
}

@safe unittest
{
    // PostgreSQL's example: toEven gives the 16-digit midpoint, avoid the 17 digits the server prints
    const value = 36_681_927_456_064_224.0;
    const d = shortestDigits(value);
    assert(d.digits == "3668192745606422" && d.pointPos == 17 && isMidpoint(d.digits, d.pointPos, value));
    const a = shortestDigits(-value, Ties.avoid);
    assert(a.digits == "36681927456064224" && a.pointPos == 17 && !isMidpoint(a.digits, a.pointPos, value));
    // Most values have the same digits either way
    assert(shortestDigits(0.1, Ties.avoid) == shortestDigits(0.1));
    assert(shortestDigits(2.0f ^^ -10, Ties.avoid) == shortestDigits(2.0f ^^ -10));
}
