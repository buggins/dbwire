#!/bin/sh
# Regenerates the TLS test certificates used by the unit tests in dbwire.tls.transport.
# Test-only material: the keys are public and must never be trusted anywhere else.
# Run from this directory: sh make-test-certs.sh
set -eu
days=36500
ext=$(mktemp)
trap 'rm -f "$ext" ca.key other-ca.key ./*.csr ./*.srl' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days $days -subj "/CN=dbwire test CA" -out ca.pem

openssl ecparam -name prime256v1 -genkey -noout -out other-ca.key
openssl req -x509 -new -key other-ca.key -sha256 -days $days -subj "/CN=dbwire untrusted test CA" -out other-ca.pem

# Server certificate for localhost and 127.0.0.1
openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key -subj "/CN=localhost" -out server.csr
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > "$ext"
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -sha256 -days $days -extfile "$ext" -out server.pem

# Client certificate, for mutual TLS
openssl ecparam -name prime256v1 -genkey -noout -out client.key
openssl req -new -key client.key -subj "/CN=dbwire-client" -out client.csr
printf 'extendedKeyUsage=clientAuth\n' > "$ext"
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -sha256 -days $days -extfile "$ext" -out client.pem

# Test servers in containers may read the keys as another user
chmod 644 server.key client.key

# The client key encrypted (PKCS#8, as in an Oracle ewallet.pem), password "dbwire-test"
openssl pkcs8 -topk8 -in client.key -out client-encrypted.key -v2 aes-256-cbc -passout pass:dbwire-test
chmod 644 client-encrypted.key
