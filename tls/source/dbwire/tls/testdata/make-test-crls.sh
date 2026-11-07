#!/bin/sh
# Regenerates the certificate revocation list (CRL) test material used by the unit tests in
# dbwire.tls.transport. A CA of its own, so the certificates of make-test-certs.sh stay as they are.
# Test-only material: the keys are public and must never be trusted anywhere else.
# Run from this directory: sh make-test-crls.sh
set -eu
days=36500
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$work/ca.key"
openssl req -x509 -new -key "$work/ca.key" -sha256 -days $days -subj "/CN=dbwire CRL test CA" -out crl-ca.pem

# Two server certificates for localhost and 127.0.0.1; the second one gets revoked
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > "$work/ext"
for name in crl-good crl-revoked; do
    openssl ecparam -name prime256v1 -genkey -noout -out "$name.key"
    openssl req -new -key "$name.key" -subj "/CN=localhost" -out "$work/$name.csr"
    openssl x509 -req -in "$work/$name.csr" -CA crl-ca.pem -CAkey "$work/ca.key" -CAcreateserial \
        -CAserial "$work/serial" -sha256 -days $days -extfile "$work/ext" -out "$name.pem"
done
chmod 644 crl-good.key crl-revoked.key

# A minimal "openssl ca" setup, only for revoking and signing the CRL
: > "$work/index.txt"
cat > "$work/ca.cnf" <<EOF
[ca]
default_ca = test
[test]
database = $work/index.txt
default_md = sha256
default_crl_days = $days
EOF
openssl ca -config "$work/ca.cnf" -cert crl-ca.pem -keyfile "$work/ca.key" -revoke crl-revoked.pem
openssl ca -config "$work/ca.cnf" -cert crl-ca.pem -keyfile "$work/ca.key" -gencrl -out crl.pem

# The same CRL in a directory, named by the issuer's hash as "openssl rehash" names it
rm -rf crls
mkdir crls
cp crl.pem "crls/$(openssl crl -in crl.pem -hash -noout).r0"
