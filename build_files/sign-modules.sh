#!/usr/bin/env bash
#
# Sign staged kernel modules with a MOK key supplied through BuildKit secrets.
# The caller decides whether signing is requested; this script exits 0 without
# doing anything when the secrets are absent.
#
set -euo pipefail

MODDIR="${1:-}"
[[ -n "${MODDIR}" && -d "${MODDIR}" ]] || {
    echo "usage: $0 <module-directory>" >&2
    exit 2
}

KEY="/run/secrets/mok_key"
CERT="/run/secrets/mok_cert"
if [[ ! -s "${KEY}" || ! -s "${CERT}" ]]; then
    echo "No MOK secrets supplied; leaving modules unsigned." >&2
    exit 0
fi

command -v openssl >/dev/null 2>&1 || {
    echo "openssl is required for module signing" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

install -m 0600 "${KEY}" "${WORK}/mok.key"
if grep -q -- 'BEGIN CERTIFICATE' "${CERT}"; then
    openssl x509 -in "${CERT}" -outform DER -out "${WORK}/mok.der"
    cp "${CERT}" "${WORK}/mok.pem"
else
    install -m 0644 "${CERT}" "${WORK}/mok.der"
    openssl x509 -inform DER -in "${WORK}/mok.der" -out "${WORK}/mok.pem"
fi

SIGNTOOL=""
SIGN_CERT="${WORK}/mok.der"
KVER="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1)"
KERNEL_SIGN_FILE="/usr/src/kernels/${KVER}/scripts/sign-file"

# kernel-devel ships scripts/sign-file and is a hard build dependency.  Prefer
# it over kmodsign so signing does not depend on the optional kmod-tools
# subpackage or on cert-format differences between distributions.
if [[ -x "${KERNEL_SIGN_FILE}" ]]; then
    SIGNTOOL="${KERNEL_SIGN_FILE}"
    SIGN_CERT="${WORK}/mok.pem"
elif command -v kmodsign >/dev/null 2>&1; then
    SIGNTOOL="kmodsign"
fi
[[ -n "${SIGNTOOL}" ]] || {
    echo "Neither kernel-devel scripts/sign-file nor kmodsign is available" >&2
    exit 1
}

shopt -s nullglob
modules=("${MODDIR}"/*.ko)
(( ${#modules[@]} > 0 )) || {
    echo "No .ko files to sign in ${MODDIR}" >&2
    exit 1
}

for module in "${modules[@]}"; do
    if [[ "${SIGNTOOL}" == "kmodsign" ]]; then
        kmodsign sha512 "${WORK}/mok.key" "${SIGN_CERT}" "${module}" "${module}.signed"
    else
        "${SIGNTOOL}" sha512 "${WORK}/mok.key" "${SIGN_CERT}" "${module}" "${module}.signed"
    fi
    mv -f "${module}.signed" "${module}"
    echo "Signed $(basename "${module}") with ${SIGNTOOL##*/}"
done

install -m 0644 "${WORK}/mok.der" "${MODDIR}/mok.der"
