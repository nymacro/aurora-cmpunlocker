#!/usr/bin/env bash
#
# Generate a Machine Owner Key (MOK) for signing the patched NVIDIA modules.
#
# Usage: ./build_files/generate-mok.sh [output-dir]
#
# Then store the base64 encoding of keys/mok.key in the MOK_KEY secret and the
# base64 encoding of keys/mok.der in the MOK_CERT secret.  Enroll the public
# certificate on the installed system with:
#
#   sudo mokutil --import /usr/share/aurora-cmpunlocker/mok.der
#   sudo reboot
#
set -euo pipefail

OUT_DIR="${1:-keys}"
umask 077
mkdir -p "${OUT_DIR}"

if [[ -e "${OUT_DIR}/mok.key" || -e "${OUT_DIR}/mok.crt" ]]; then
    echo "Refusing to overwrite existing ${OUT_DIR}/mok.key or ${OUT_DIR}/mok.crt" >&2
    exit 1
fi

openssl req -new -x509 -newkey rsa:4096 -nodes -days 36500 \
    -keyout "${OUT_DIR}/mok.key" \
    -out "${OUT_DIR}/mok.crt" \
    -subj "/CN=Aurora CMP Unlocker Module Signing/" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"

openssl x509 -in "${OUT_DIR}/mok.crt" -outform DER -out "${OUT_DIR}/mok.der"
base64 -w0 "${OUT_DIR}/mok.key" > "${OUT_DIR}/mok.key.b64"
base64 -w0 "${OUT_DIR}/mok.der" > "${OUT_DIR}/mok.der.b64"
chmod 0600 "${OUT_DIR}/mok.key"

cat <<EOF
Generated:
  ${OUT_DIR}/mok.key      (private key; add base64 to secret MOK_KEY, never commit)
  ${OUT_DIR}/mok.der      (DER certificate; add base64 to secret MOK_CERT)
  ${OUT_DIR}/mok.key.b64
  ${OUT_DIR}/mok.der.b64

Enroll on the target system after switching images:
  sudo mokutil --import /usr/share/aurora-cmpunlocker/mok.der
  sudo reboot
EOF
