#!/usr/bin/env bash
# Create a stable local self signed identity for development builds.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY_CN="TerminalDB Self-Signed"
LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d '"')"

if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY_CN}"; then
  echo "Signing identity '${IDENTITY_CN}' already exists."
  exit 0
fi

OPENSSL_BIN="/usr/bin/openssl"
if [[ ! -x "${OPENSSL_BIN}" ]]; then
  OPENSSL_BIN="openssl"
fi

TEMP_DIR="$(mktemp -d)"
trap '/bin/rm -r "${TEMP_DIR}"' EXIT

cat > "${TEMP_DIR}/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = TerminalDB Self-Signed
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

"${OPENSSL_BIN}" req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -keyout "${TEMP_DIR}/key.pem" \
  -out "${TEMP_DIR}/cert.pem" \
  -days 3650 \
  -config "${TEMP_DIR}/openssl.cnf" \
  >/dev/null 2>&1

TRANSPORT_PASSWORD="terminaldb-transport"
"${OPENSSL_BIN}" pkcs12 \
  -export \
  -out "${TEMP_DIR}/identity.p12" \
  -inkey "${TEMP_DIR}/key.pem" \
  -in "${TEMP_DIR}/cert.pem" \
  -passout "pass:${TRANSPORT_PASSWORD}" \
  -certpbe PBE-SHA1-3DES \
  -keypbe PBE-SHA1-3DES

security import "${TEMP_DIR}/identity.p12" \
  -k "${LOGIN_KEYCHAIN}" \
  -P "${TRANSPORT_PASSWORD}" \
  -A \
  >/dev/null

echo "Created signing identity '${IDENTITY_CN}'."
