#!/usr/bin/env bash
#
# Install the staged cmpunlocker modules into the final bootc image and rebuild
# the initramfs.  Runs in the final stage with /boot and /var on tmpfs.
#
set -euo pipefail
export LC_ALL=C

# Make unattended CI failures diagnosable from the build log.
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: install-modules.sh failed at line %s (exit %s): %s\n" "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2' ERR

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

KVER="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1)"
[[ -n "${KVER}" && -d "/usr/lib/modules/${KVER}" ]] || die "Cannot determine the image kernel."

MODDEST="/usr/lib/modules/${KVER}/updates/cmpunlocker"
STAGE="/tmp/cmpunlocker-modules"
[[ -d "${STAGE}" ]] || die "Staged modules not found at ${STAGE}"

log "Installing patched modules for ${KVER} into ${MODDEST}"
rm -rf "${MODDEST}"
install -d -m 0755 "${MODDEST}"

shopt -s nullglob
modules=("${STAGE}"/*.ko)
(( ${#modules[@]} > 0 )) || die "No .ko files staged"
install -m 0644 "${modules[@]}" "${MODDEST}/"

for f in driver_version card_profile unlock_geometry gpu_inventory; do
    if [[ -f "${STAGE}/${f}" ]]; then
        install -m 0644 "${STAGE}/${f}" "${MODDEST}/${f}"
    fi
done
if [[ -f "${STAGE}/SHA256SUMS" ]]; then
    install -D -m 0644 "${STAGE}/SHA256SUMS" \
        "/usr/share/aurora-cmpunlocker/modules.sha256"
fi

depmod -a "${KVER}"

log "Verifying module resolution"
# modinfo honours kmod's module search order (updates before extra), so this is
# a direct check that the running system will pick the patched modules.
for module in nvidia nvidia_drm nvidia_modeset nvidia_uvm; do
    resolved="$(modinfo -k "${KVER}" -n "${module}" 2>/dev/null || true)"
    if [[ "${resolved}" != *"/updates/cmpunlocker/"* ]]; then
        echo "modules.dep entries for nvidia:" >&2
        grep -E '(^|/)nvidia(-[a-z]+)?\.ko' "/usr/lib/modules/${KVER}/modules.dep" >&2 || true
        die "${module} resolves to '${resolved:-<none>}', not updates/cmpunlocker. Refusing to ship a stock module."
    fi
    log "  ${module} -> ${resolved}"
done

if [[ -e "${MODDEST}/nvidia-peermem.ko" ]]; then
    resolved="$(modinfo -k "${KVER}" -n nvidia_peermem 2>/dev/null || true)"
    [[ "${resolved}" == *"/updates/cmpunlocker/"* ]] \
        || die "nvidia_peermem resolves to '${resolved:-<none>}'"
fi

# Correct SELinux labels for files we added.  The policy may not be loaded in
# the container, so a failure here is not fatal; bootc relabels on install.
restorecon -RF "${MODDEST}" "/usr/libexec/cmpunlocker" "/usr/share/cmpunlocker" \
    "/usr/share/aurora-cmpunlocker" "/usr/lib/systemd/system" \
    "/usr/lib/udev/rules.d" "/etc/modprobe.d" "/usr/lib/bootc/kargs.d" \
    "/etc/systemd/system" "/etc/pki/akmods/certs" \
    "/usr/bin/cmpunlocker-verify" "/usr/bin/cmpunlocker-passthrough" \
    2>/dev/null || true

if [[ "${REBUILD_INITRAMFS:-1}" != "1" ]]; then
    warn "REBUILD_INITRAMFS=${REBUILD_INITRAMFS}; leaving the base initramfs untouched."
    warn "The patched modules may not be loaded early unless the initramfs is rebuilt."
    exit 0
fi

INITRAMFS="/usr/lib/modules/${KVER}/initramfs.img"
if ! command -v dracut >/dev/null 2>&1; then
    die "dracut is missing; cannot rebuild ${INITRAMFS}"
fi
if [[ ! -f "${INITRAMFS}" ]]; then
    die "Initramfs not found at ${INITRAMFS}"
fi

log "Rebuilding initramfs for ${KVER}"
# /var is an empty tmpfs in this build step.  Create the directories dracut
# needs: /var/tmp is its default tmpdir (a missing one is fatal), /var/log is
# used for its log, and /root is a symlink to /var/roothome on bootc images.
mkdir -p /var/tmp /var/log /var/roothome
DRACUT_REMOVE=()
if rpm -q kmod-v4l2loopback >/dev/null 2>&1; then
    mapfile -t DRACUT_REMOVE < <(rpm -ql kmod-v4l2loopback)
fi

# Aurora strips volatile os-release fields while generating the initramfs so
# that two builds of the same inputs produce the same file.
TMP_OS_RELEASE="$(mktemp --tmpdir 'os-release-XXXXXXXXXX')"
cp /usr/lib/os-release "${TMP_OS_RELEASE}"
sed -Ei -e '/^((OSTREE_)?(IMAGE_)?VERSION|PRETTY_NAME|BUILD_ID)=/d' /usr/lib/os-release

DRACUT_ARGS=(
    --kver "${KVER}"
    --reproducible
    --force
)
if (( ${#DRACUT_REMOVE[@]} > 0 )); then
    DRACUT_ARGS+=(--remove "${DRACUT_REMOVE[@]}")
fi

DRACUT_NO_XATTR=1 dracut "${DRACUT_ARGS[@]}" "${INITRAMFS}"

cp "${TMP_OS_RELEASE}" /usr/lib/os-release
rm -f "${TMP_OS_RELEASE}"
chmod 0600 "${INITRAMFS}"

log "Initramfs rebuilt: $(sha256sum "${INITRAMFS}")"
log "Final module: $(modinfo -k "${KVER}" -n nvidia)"
