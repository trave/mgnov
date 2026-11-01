#!/bin/bash
# Creates a self-signed code-signing identity "mgnov-dev" in the login keychain.
# With it, the app's code-signing identity stays the same across rebuilds, so the
# Accessibility grant you give Mgnov.app once keeps working. Ad-hoc signatures change
# with every build and macOS forgets the grant each time.
set -euo pipefail
NAME="mgnov-dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already exists"; exit 0
fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/key.pem" -out "$T/cert.pem" -config "$T/cfg" >/dev/null 2>&1
openssl pkcs12 -export -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:mgnov -legacy 2>/dev/null \
  || openssl pkcs12 -export -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:mgnov
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/id.p12" -k "$KC" -P mgnov -T /usr/bin/codesign -T /usr/bin/security
echo "→ trusting '$NAME' for code signing (macOS may ask for your password)"
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem"
# let codesign use the key without a prompt on every build
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null 2>&1 || true
echo "→ done. Rebuild with: make"
