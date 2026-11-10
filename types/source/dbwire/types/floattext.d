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

The result is exact for every value, and nothing is allocated (`@nogc`):
moderate magnitudes (nearly every `float`, doubles from about 1e-20 to 1e35)
run on 128-bit integers, the others on fixed 1280-bit ones.
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
    const generated = generateDigits!U128(input, result) || generateDigits!Wide(input, result); // Wide always fits
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

@safe pure nothrow @nogc unittest
{
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

/++
How `formatDigits` lays out digits, in terms of the decimal exponent X
(the value is d.ddd × 10^X): plain notation (`0.0001`, `123.45`, `1500`)
when X is at least `minPlainExponent`, below `plainExponentLimit`, and, with
`limitByDigits`, below the number of digits; otherwise one digit, the others
after a point, and the exponent (`1.5e+300`). The defaults are C's `%g` with
as many significant digits as there are (`1e+02` for 100).
+/
struct FloatLayout
{
    /// The lowest exponent written in plain notation.
    int minPlainExponent = -4;
    /// Exponents from this one up use the exponent form.
    int plainExponentLimit = int.max;
    /// Whether exponents from the number of digits up use the exponent form too (`%g`).
    bool limitByDigits = true;
    /// Whether positive exponents get a `+` (`e+21` or `e21`).
    bool exponentPlus = true;
    /// The fewest exponent digits, padded with zeros (`e+05` with 2).
    ubyte exponentDigits = 2;
}

/++
`d` (from `shortestDigits`: the value is `0.digits × 10^pointPos`) as text,
`-` first when `negative`, laid out as `layout` says. NaN and infinities
have no digits, and give empty text: callers write them (and usually zero,
`0` here), since servers spell them differently.
+/
string formatDigits(const ShortestDigits d, bool negative, FloatLayout layout = FloatLayout.init) @safe pure nothrow
{
    import dbwire.types.text : TextBuffer;

    TextBuffer!400 t; // every double fits in any layout: at most "-0." ~ 323 zeros ~ 17 digits, or 309 digits
    putDigits(t, d.digits, d.pointPos, negative, layout);
    return t.text;
}

/// ditto, appended to `t`.
void putDigits(Buffer)(ref Buffer t, scope const(char)[] digits, int pointPos, bool negative,
        FloatLayout layout = FloatLayout.init)
{
    if (!digits.length)
        return; // NaN or an infinity
    const count = cast(int) digits.length;
    const exponent = pointPos - 1;
    if (negative)
        t.put('-');
    if (exponent < layout.minPlainExponent || exponent >= layout.plainExponentLimit
            || (layout.limitByDigits && exponent >= count))
    {
        t.put(digits[0]);
        if (count > 1)
        {
            t.put('.');
            t.put(digits[1 .. $]);
        }
        t.put('e');
        if (exponent < 0)
            t.put('-');
        else if (layout.exponentPlus)
            t.put('+');
        t.number(exponent < 0 ? -exponent : exponent, layout.exponentDigits);
    }
    else if (pointPos <= 0)
    {
        t.put("0.");
        t.fill('0', -pointPos);
        t.put(digits);
    }
    else if (pointPos >= count)
    {
        t.put(digits);
        t.fill('0', pointPos - count);
    }
    else
    {
        t.put(digits[0 .. pointPos]);
        t.put('.');
        t.put(digits[pointPos .. $]);
    }
}

///
@safe pure nothrow unittest
{
    const d = shortestDigits(1.5e300), h = shortestDigits(100.0), s = shortestDigits(0.00012);
    assert(formatDigits(d, true) == "-1.5e+300" && formatDigits(h, false) == "1e+02");
    assert(formatDigits(s, false) == "0.00012");
    // PostgreSQL's float8: a fixed limit instead of the number of digits
    const pg = FloatLayout(-4, 15, false);
    assert(formatDigits(h, false, pg) == "100" && formatDigits(shortestDigits(1e15), false, pg) == "1e+15");
    // ClickHouse: plain from 1e-6 to below 1e21, no '+', no padding
    const ch = FloatLayout(-6, 21, false, false, 1);
    assert(formatDigits(shortestDigits(1e-7), false, ch) == "1e-7" && formatDigits(shortestDigits(1e20), false, ch)
            == "100000000000000000000" && formatDigits(shortestDigits(1.5e21), false, ch) == "1.5e21");
    // zero is "0"; NaN and infinities give nothing
    assert(formatDigits(shortestDigits(0.0), false) == "0");
    assert(formatDigits(shortestDigits(-double.infinity), true) == "");
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
Generates the digits of `input` with integers of type `N` (`U128`, `Wide`,
or `BigInt`, the reference in the tests). Returns: false if `U128` overflowed
(`result` is undefined then; `Wide` holds every double).

This is the free-format digit generation of Steele and White, with exact
integer arithmetic: `r / s` is the value, `mPlus / s` and `mMinus / s` are
the distances to the midpoints between the value and its neighbours. The
midpoints themselves count as reading back when `input.acceptMidpoints` is
set (round half to even and an even mantissa). `U128` covers nearly every `float` and the
doubles from about 1e-20 to 1e35; both types give the same digits.
+/
private bool generateDigits(N)(const DigitInput input, out ShortestDigits result)
{
    enum checked = !is(N == BigInt); // U128 and Wide flag results that don't fit
    N r, s, mPlus, mMinus;
    bool failed()
    {
        static if (checked)
            return r.bad || s.bad || mPlus.bad || mMinus.bad;
        else
            return false;
    }

    // Scale by 2 (by 4 at a power of two) so that the half gaps are whole numbers
    const scale = input.narrowBelow ? 2 : 1;
    int k = input.k;
    if (input.e >= 0)
    {
        r = N(input.f);
        r <<= input.e + scale;
        s = N(1);
        s <<= scale;
        mPlus = N(1);
        mPlus <<= input.e + (input.narrowBelow ? 1 : 0);
        mMinus = N(1);
        mMinus <<= input.e;
    }
    else
    {
        s = N(1);
        s <<= scale - input.e;
        // r, mPlus and mMinus are small here: below 1 (k < 0) they all get the factor 10^-k, computed once
        const ulong rSmall = input.f << scale, mPlusSmall = input.narrowBelow ? 2 : 1;
        if (k < 0)
        {
            N p = N(1);
            multiplyByPow10(p, -k);
            r = p * rSmall;
            mPlus = p * mPlusSmall;
            mMinus = p;
        }
        else
        {
            r = N(rSmall);
            mPlus = N(mPlusSmall);
            mMinus = N(1);
        }
    }
    if (failed())
        return false; // with U128, most doubles beyond about 1e35 or below 1e-20 stop here
    if (k >= 0)
        multiplyByPow10(s, k);
    else if (input.e >= 0) // not reached: values from 1 up have k >= 0
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
        static if (checked)
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
        static if (checked)
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
            static if (checked)
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
private int takeDigit(N)(ref N r, const ref N s)
{
    static if (is(N == BigInt))
    {
        import std.bigint : divMod;

        BigInt q, remainder;
        divMod(r, s, q, remainder);
        r = remainder;
        return cast(int) q.toLong();
    }
    else static if (is(N == Wide))
    {
        if (r < s)
            return 0;
        // an estimate from the top three words of both (exact or one off), then the correction; a quotient
        // beyond 10 (or s too small to show in the top words) gives 10, which the caller rejects
        const base = r.used > 3 ? r.used - 3 : 0;
        const estimate = r.approximate(base) / s.approximate(base);
        int q = estimate < 10 ? cast(int) estimate : 10;
        auto t = s * q;
        while (q > 0 && t > r)
        {
            t -= s;
            q--;
        }
        r -= t;
        while (r >= s && q < 10)
        {
            r -= s;
            q++;
        }
        return q;
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
inherits; the caller then starts again with `Wide`.
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
An unsigned integer of up to 1280 bits with the operations of the digit
generation; `used` words are significant, the rest are zero. Every double
fits with room to spare (the largest numbers, near 2^1140, come from the
smallest subnormals), so `bad` (a result that didn't fit) is only a safety net.
+/
private struct Wide
{
    enum words = 20;
    ulong[words] w; /// little-endian words
    uint used; /// words in use
    bool bad; /// a result did not fit: the value is meaningless

    this(ulong value) @safe pure nothrow @nogc
    {
        w[0] = value;
        used = value != 0;
    }

    Wide opBinary(string op : "+")(const ref Wide b) const @safe pure nothrow @nogc
    {
        Wide sum;
        const n = used > b.used ? used : b.used;
        ulong carry;
        foreach (i; 0 .. n)
        {
            const x = w[i] + b.w[i];
            const y = x + carry;
            carry = (x < w[i]) | (y < x);
            sum.w[i] = y;
        }
        sum.used = n;
        sum.bad = bad || b.bad;
        if (carry)
            sum.append(1);
        return sum;
    }

    /// `this - b`, for `this >= b`.
    Wide opBinary(string op : "-")(const ref Wide b) const @safe pure nothrow @nogc
    {
        Wide difference = this;
        difference -= b;
        return difference;
    }

    /// ditto
    void opOpAssign(string op : "-")(const ref Wide b) @safe pure nothrow @nogc
    {
        ulong borrow;
        foreach (i; 0 .. used)
        {
            const x = w[i] - b.w[i];
            const y = x - borrow;
            borrow = (w[i] < b.w[i]) | (x < borrow);
            w[i] = y;
        }
        bad = bad || b.bad;
        trim();
    }

    Wide opBinary(string op : "*")(ulong m) const @safe pure nothrow @nogc
    {
        Wide product = this;
        product *= m;
        return product;
    }

    void opOpAssign(string op : "*")(ulong m) @safe pure nothrow @nogc
    {
        ulong carry;
        foreach (i; 0 .. used)
        {
            const p = U128.multiply(w[i], m);
            const low = p.low + carry;
            carry = p.high + (low < p.low);
            w[i] = low;
        }
        if (carry)
            append(carry);
        trim();
    }

    /// The value divided by 2^(64 × base), as a double (from the words at `base` and above).
    double approximate(size_t base) const @safe pure nothrow @nogc
    {
        double x = 0;
        foreach_reverse (i; base .. used)
            x = x * 18_446_744_073_709_551_616.0 + w[i];
        return x;
    }

    void opOpAssign(string op : "<<")(int n) @safe pure nothrow @nogc
    {
        if (n == 0 || used == 0)
            return;
        const wordShift = n / 64, bitShift = n % 64;
        // the words the result needs: one more when the top word's high bits move into a new word
        const needed = used + wordShift + (bitShift && (w[used - 1] >> (64 - bitShift)) != 0 ? 1 : 0);
        if (needed > words)
        {
            bad = true;
            return;
        }
        ulong[words] shifted;
        foreach (i; 0 .. used)
        {
            shifted[i + wordShift] |= w[i] << bitShift;
            if (bitShift && i + wordShift + 1 < needed)
                shifted[i + wordShift + 1] = w[i] >> (64 - bitShift);
        }
        w = shifted;
        used = cast(uint) needed;
    }

    int opCmp(const ref Wide b) const @safe pure nothrow @nogc
    {
        if (used != b.used)
            return used < b.used ? -1 : 1;
        foreach_reverse (i; 0 .. used)
            if (w[i] != b.w[i])
                return w[i] < b.w[i] ? -1 : 1;
        return 0;
    }

    bool opEquals(const ref Wide b) const @safe pure nothrow @nogc
    {
        return opCmp(b) == 0;
    }

    size_t toHash() const @safe pure nothrow @nogc
    {
        size_t h = used;
        foreach (i; 0 .. used)
            h = h * 31 + cast(size_t) w[i];
        return h;
    }

    private void append(ulong word) @safe pure nothrow @nogc
    {
        if (used == words)
            bad = true;
        else
            w[used++] = word;
    }

    private void trim() @safe pure nothrow @nogc
    {
        while (used > 0 && w[used - 1] == 0)
            used--;
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
version (unittest) private bool isMidpoint(T)(scope const(char)[] digits, int pointPos, T value)
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
        BigInt left = BigInt(digits.idup) * 2; // a copy: older BigInt constructors don't take scope slices
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

// Wide gives exactly the BigInt digits over the whole range of doubles and floats (subnormals and powers of two
// included) and never overflows
@safe unittest
{
    import std.math : ldexp;
    import std.random : Mt19937_64, uniform;

    auto rng = Mt19937_64(3);
    void compare(T)(T value)
    {
        foreach (ties; [Ties.toEven, Ties.avoid])
        {
            const input = digitInput(value, ties);
            ShortestDigits viaWide, viaBigInt;
            assert(generateDigits!Wide(input, viaWide));
            assert(generateDigits!BigInt(input, viaBigInt));
            assert(viaWide == viaBigInt);
        }
    }

    foreach (exponent; -1074 .. 1024)
    {
        compare(ldexp(1.0, exponent)); // powers of two, the smallest subnormal first
        compare(ldexp(uniform(1.0, 2.0, rng), exponent));
    }
    compare(double.max);
    compare(double.min_normal);
    compare(ldexp(0x1.fffffffffffffp0, -1023)); // the largest subnormal
    foreach (exponent; -149 .. 128)
    {
        compare(ldexp(1.0f, exponent));
        compare(ldexp(uniform(1.0f, 2.0f, rng), exponent));
    }
    compare(float.max);
}

// Wide arithmetic against BigInt
@safe unittest
{
    import std.bigint : BigInt;
    import std.random : Mt19937_64, uniform;

    static BigInt big(const Wide x)
    {
        BigInt b;
        foreach_reverse (i; 0 .. x.used)
            b = (b << 64) + BigInt(x.w[i]);
        return b;
    }

    auto rng = Mt19937_64(9);
    foreach (_; 0 .. 2000)
    {
        auto a = Wide(uniform!ulong(rng)), b = Wide(uniform!ulong(rng));
        a <<= uniform(0, 600, rng);
        b <<= uniform(0, 600, rng);
        const m = uniform!ulong(rng);
        const sum = a + b, product = a * m;
        assert(!sum.bad && big(sum) == big(a) + big(b));
        assert(!product.bad && big(product) == big(a) * BigInt(m));
        const larger = a >= b ? a : b, smaller = a >= b ? b : a;
        assert(big(larger - smaller) == big(larger) - big(smaller));
        assert((a < b) == (big(a) < big(b)) && (a == a) && (a * 0).used == 0);
    }
    // overflow is flagged
    auto x = Wide(1);
    x <<= Wide.words * 64 - 1;
    assert(!x.bad);
    x <<= 1;
    assert(x.bad);
    auto y = Wide(3);
    y <<= Wide.words * 64 - 2;
    assert(!y.bad && (y * 2).bad && (y + y).bad);
}
