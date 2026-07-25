#!/usr/bin/env bash
# Provision the stable self signed identity used for TerminalDB GitHub releases.
set -euo pipefail

OPENSSL_BIN="/usr/bin/openssl"
if [[ ! -x "${OPENSSL_BIN}" ]]; then
  OPENSSL_BIN="openssl"
fi

command -v gh >/dev/null || {
  echo "GitHub CLI is required." >&2
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "Authenticate GitHub CLI first." >&2
  exit 1
}

REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repository: ${REPOSITORY}"

if gh secret list --repo "${REPOSITORY}" | grep -q '^TERMINALDB_SIGNING_P12'; then
  echo "TERMINALDB_SIGNING_P12 already exists."
  echo "Rotating it changes the release signing identity."
  read -r -p "Rotate the signing identity? [y/N] " RESPONSE
  if [[ ! "${RESPONSE}" =~ ^[Yy]$ ]]; then
    echo "No changes made."
    exit 0
  fi
fi

TRANSPORT_PASSWORD="$("${OPENSSL_BIN}" rand -base64 18)"
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

"${OPENSSL_BIN}" pkcs12 \
  -export \
  -out "${TEMP_DIR}/identity.p12" \
  -inkey "${TEMP_DIR}/key.pem" \
  -in "${TEMP_DIR}/cert.pem" \
  -passout "pass:${TRANSPORT_PASSWORD}" \
  -certpbe PBE-SHA1-3DES \
  -keypbe PBE-SHA1-3DES

base64 -i "${TEMP_DIR}/identity.p12" |
  gh secret set TERMINALDB_SIGNING_P12 --repo "${REPOSITORY}"
printf '%s' "${TRANSPORT_PASSWORD}" |
  gh secret set TERMINALDB_SIGNING_PASSWORD --repo "${REPOSITORY}"

echo "Configured stable release signing for ${REPOSITORY}."
