#!/usr/bin/env bash
# One-time: creates a self-signed "VoiceMode Dev" code-signing certificate in
# the login keychain so TCC permission grants survive rebuilds.
# Run this in your own Terminal (sandboxed shells cannot write to the keychain).
set -euo pipefail

if security find-identity -v -p codesigning | grep -q "VoiceMode Dev"; then
	echo "VoiceMode Dev identity already exists."
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.conf <<'EOF'
[ req ]
distinguished_name = req_name
x509_extensions = ext
prompt = no
[ req_name ]
CN = VoiceMode Dev
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config cert.conf
openssl pkcs12 -export -legacy -out cert.p12 -inkey key.pem -in cert.pem -passout pass:temp 2>/dev/null \
	|| openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:temp

security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign

# Trust the cert for code signing (admin password dialog will appear).
security add-trusted-cert -d -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem \
	|| sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain cert.pem

echo
security find-identity -v -p codesigning | grep "VoiceMode Dev" \
	&& echo "Done. Rebuild with Scripts/bundle.sh — grants will now persist." \
	|| { echo "Identity not valid yet — open Keychain Access, find 'VoiceMode Dev', set Trust > Code Signing to Always Trust."; exit 1; }
