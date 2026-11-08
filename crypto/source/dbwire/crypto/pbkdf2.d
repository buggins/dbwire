/++
PBKDF2 (RFC 8018 §5.2) over HMAC with any Phobos digest: Oracle derives its
12c password keys with PBKDF2-HMAC-SHA512.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module dbwire.crypto.pbkdf2;

import std.digest : digestLength, isDigest;
import std.digest.hmac : HMAC;

import dbwire.exception : ClientException;

/++
Derives `length` bytes from `password` and `salt` with `iterations` rounds of
HMAC-`H` (e.g. `pbkdf2!SHA512(...)`).

The iteration count often comes from the server: connectors should also
reject counts too high to compute in reasonable time.

Throws: `ClientException` if `iterations` is 0.
+/
ubyte[] pbkdf2(H)(scope const(ubyte)[] password, scope const(ubyte)[] salt, uint iterations, size_t length)
        if (isDigest!H)
{
    if (iterations == 0)
        throw new ClientException("PBKDF2 needs at least one iteration");
    enum size_t hLen = digestLength!H;
    auto mac = HMAC!H(password);
    auto result = new ubyte[length];
    size_t done;
    for (uint block = 1; done < length; block++)
    {
        const ubyte[4] index = [
            cast(ubyte)(block >> 24), cast(ubyte)(block >> 16), cast(ubyte)(block >> 8),
            cast(ubyte) block
        ];
        mac.put(salt);
        mac.put(index[]);
        ubyte[hLen] u = mac.finish(); // finish resets the HMAC to its keyed state
        ubyte[hLen] t = u;
        foreach (_; 1 .. iterations)
        {
            mac.put(u[]);
            u = mac.finish();
            t[] ^= u[];
        }
        const n = length - done < hLen ? length - done : hLen;
        result[done .. done + n] = t[0 .. n];
        done += n;
    }
    return result;
}

///
@safe pure unittest
{
    import std.conv : hexString;
    import std.digest.sha : SHA1, SHA256, SHA512;
    import std.string : representation;

    alias b = (string s) => s.representation;
    // RFC 6070 (PBKDF2-HMAC-SHA1)
    assert(pbkdf2!SHA1(b("password"), b("salt"), 1, 20) == b(hexString!"0c60c80f961f0e71f3a9b524af6012062fe037a6"));
    assert(pbkdf2!SHA1(b("password"), b("salt"), 2, 20) == b(hexString!"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"));
    assert(pbkdf2!SHA1(b("password"), b("salt"), 4096, 20) == b(hexString!"4b007901b765489abead49d926f721d065a429c1"));
    assert(pbkdf2!SHA1(b("pass\0word"), b("sa\0lt"), 4096, 16) == b(hexString!"56fa6aa75548099dcc37d7f03425e0c3"));
    // RFC 7914 §11 (PBKDF2-HMAC-SHA256), two blocks
    enum sha256 = hexString!("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                ~ "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783");
    assert(pbkdf2!SHA256(b("passwd"), b("salt"), 1, 64) == b(sha256));
    // PBKDF2-HMAC-SHA512 (values from Python's hashlib.pbkdf2_hmac)
    enum sha512 = hexString!("867f70cf1ade02cff3752599a3a53dc4af34c7a669815ae5d513554e1c8cf252"
                ~ "c02d470a285a0501bad999bfe943c08f050235d7d68b1da55e63f73b60a57fce");
    assert(pbkdf2!SHA512(b("password"), b("salt"), 1, 64) == b(sha512));
    enum sha512Long = hexString!("8c0511f4c6e597c6ac6315d8f0362e225f3c501495ba23b868c005174dc4ee71"
                ~ "115b59f9e60cd9532fa33e0f75aefe30225c583a186cd82bd4daea9724a3d3b8");
    assert(pbkdf2!SHA512(b("passwordPASSWORDpassword"), b("saltSALTsaltSALTsaltSALTsaltSALTsalt"), 4096, 64) == b(
            sha512Long));
}

@safe unittest
{
    import std.digest.sha : SHA512;
    import std.exception : assertThrown;

    // a server-supplied count of 0 is an error, not an assertion failure
    assertThrown!ClientException(pbkdf2!SHA512([1], [2], 0, 64));
}
