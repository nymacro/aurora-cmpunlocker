#!/usr/bin/env bash
#
# Builder for the cmpunlocker-patched NVIDIA open kernel modules.
#
# This script runs inside the Aurora base image.  It deliberately does NOT run
# cmpunlocker's install.sh: that script detects a GPU on the running host and
# mutates the live root filesystem.  Instead we drive cmpunlocker's
# driver/build.sh with a fake `uname -r` (the image kernel, not the build
# container's host kernel) and stage every file for the final image.
#
set -euo pipefail
export LC_ALL=C

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_enabled() {
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

: "${CMPUNLOCKER_REPO:=https://github.com/amoghmunikote/cmpunlocker.git}"
: "${CMPUNLOCKER_REF:=v0.5}"
: "${CMPUNLOCKER_PROFILE:=mixed}"
: "${NVIDIA_VERSION:=}"
: "${EXPECTED_NVIDIA_VERSION:=}"
: "${ENABLE_GEN2_SERVICE:=1}"
: "${ENABLE_PASSTHROUGH:=1}"
: "${ENABLE_IOMMU_KARGS:=1}"
: "${BASE_IMAGE:=unknown}"
: "${BASE_TAG:=unknown}"
: "${AKMODS_TAG:=unknown}"

# Build assets are bind-mounted from the Containerfile's `ctx` stage, matching
# the upstream image-template layout.  Overridable for manual testing.
BUILD_FILES="${BUILD_FILES:-/ctx/build_files}"
SYSTEM_FILES="${SYSTEM_FILES:-/ctx/system_files}"
CMP_DIR="/tmp/cmpunlocker"
OUT_DIR="/out"
ROOTFS="${OUT_DIR}/rootfs"
MODOUT="${OUT_DIR}/modules"

###############################################################################
# 1. Resolve the image kernel and install exact build dependencies
###############################################################################
KVER="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1)"
[[ -n "${KVER}" && -d "/usr/lib/modules/${KVER}" ]] || die "Cannot determine the image kernel (kernel-core RPM)."
log "Image kernel: ${KVER}"

if command -v dnf5 >/dev/null 2>&1; then
    DNF=dnf5
else
    DNF=dnf
fi

if [[ "${SKIP_DNF_INSTALL:-0}" == "1" ]]; then
    warn "SKIP_DNF_INSTALL=1: assuming build dependencies and kernel-devel are already installed"
else
    log "Installing build dependencies"
    "${DNF}" install -y --setopt=install_weak_deps=False \
        gcc make git tar xz curl patch kmod bc \
        python3 python3-pyyaml \
        elfutils-libelf-devel openssl openssl-devel \
        pciutils

    # The matching akmods image is bind-mounted at /tmp/kernel-rpms.  Using its
    # exact kernel-devel RPM avoids accidentally building against a newer Fedora
    # kernel than the one shipped in the Aurora base.
    mapfile -t KDEVEL_RPMS < <(find /tmp/kernel-rpms -maxdepth 1 -type f -name 'kernel-devel-*.rpm' 2>/dev/null | sort -V)
    if (( ${#KDEVEL_RPMS[@]} > 0 )); then
        log "Installing kernel-devel from akmods: ${KDEVEL_RPMS[*]}"
        "${DNF}" install -y --setopt=install_weak_deps=False "${KDEVEL_RPMS[@]}"
    else
        KDEVEL_VER="${KVER%.*}"
        warn "No kernel-devel RPM bind-mounted; trying the Fedora repositories for ${KDEVEL_VER}"
        "${DNF}" install -y --setopt=install_weak_deps=False "kernel-devel-${KDEVEL_VER}" \
            || "${DNF}" install -y --setopt=install_weak_deps=False kernel-devel-matched
    fi
fi

[[ -d "/usr/src/kernels/${KVER}" ]] \
    || die "kernel-devel for ${KVER} was not installed. Check AKMODS_TAG (${AKMODS_TAG})."
command -v patch >/dev/null 2>&1 \
    || die "GNU patch is required to apply cmpunlocker patches; install the 'patch' package."
if [[ ! -e "/usr/lib/modules/${KVER}/build" ]]; then
    ln -sfn "/usr/src/kernels/${KVER}" "/usr/lib/modules/${KVER}/build"
fi
[[ -d "/usr/lib/modules/${KVER}/build" ]] || die "Kernel build tree missing: /usr/lib/modules/${KVER}/build"

###############################################################################
# 2. Clone cmpunlocker and validate driver support
###############################################################################
log "Cloning cmpunlocker (${CMPUNLOCKER_REF})"
rm -rf "${CMP_DIR}"
git clone --quiet "${CMPUNLOCKER_REPO}" "${CMP_DIR}"
if [[ -n "${CMPUNLOCKER_REF}" ]]; then
    if ! git -C "${CMP_DIR}" checkout --quiet --detach "${CMPUNLOCKER_REF}" 2>/dev/null; then
        git -C "${CMP_DIR}" fetch --quiet origin "${CMPUNLOCKER_REF}"
        git -C "${CMP_DIR}" checkout --quiet --detach FETCH_HEAD
    fi
fi
CMP_COMMIT="$(git -C "${CMP_DIR}" rev-parse HEAD)"
log "cmpunlocker commit: ${CMP_COMMIT}"

SUPPORTED_VERSIONS=()
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${CMP_DIR}/driver/VERSION" || true)
(( ${#SUPPORTED_VERSIONS[@]} > 0 )) || die "cmpunlocker has no supported driver list at driver/VERSION"
log "cmpunlocker supports NVIDIA: ${SUPPORTED_VERSIONS[*]}"

detect_nvidia_version() {
    local v=""
    v="$(rpm -q --queryformat '%{VERSION}\n' nvidia-kmod-common 2>/dev/null | head -n1 || true)"
    if [[ -z "${v}" ]]; then
        v="$(rpm -q --queryformat '%{VERSION}\n' nvidia-driver 2>/dev/null | head -n1 || true)"
    fi
    if [[ -z "${v}" ]]; then
        v="$(find /usr/lib/firmware/nvidia -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true)"
    fi
    if [[ -z "${v}" ]]; then
        v="$(readlink -f /usr/lib64/libnvidia-ml.so.1 2>/dev/null | sed -n 's/.*libnvidia-ml\.so\.\([0-9.]*\)$/\1/p' || true)"
    fi
    printf '%s\n' "${v}"
}

INSTALLED_NVIDIA_VERSION="$(detect_nvidia_version)"
[[ -n "${INSTALLED_NVIDIA_VERSION}" ]] \
    || die "Could not detect NVIDIA userspace in the base image. Start from aurora-nvidia-open."
if [[ -n "${NVIDIA_VERSION}" && "${NVIDIA_VERSION}" != "${INSTALLED_NVIDIA_VERSION}" ]]; then
    die "NVIDIA_VERSION=${NVIDIA_VERSION} does not match the base image (${INSTALLED_NVIDIA_VERSION})."
fi
NVIDIA_VERSION="${INSTALLED_NVIDIA_VERSION}"
log "Base image NVIDIA: ${NVIDIA_VERSION}"

if [[ -n "${EXPECTED_NVIDIA_VERSION}" && "${NVIDIA_VERSION}" != "${EXPECTED_NVIDIA_VERSION}" ]]; then
    die "Base image has NVIDIA ${NVIDIA_VERSION}, but EXPECTED_NVIDIA_VERSION=${EXPECTED_NVIDIA_VERSION}. Use the matching BASE_TAG/AKMODS_TAG or override EXPECTED_NVIDIA_VERSION explicitly."
fi

# The module version must match the userspace driver exactly.  Do not silently
# patch an unsupported release: layout changes in newer 620.x drivers already
# break two cmpunlocker hunks, and runtime behaviour is not validated upstream.
if ! printf '%s\n' "${SUPPORTED_VERSIONS[@]}" | grep -qx "${NVIDIA_VERSION}"; then
    die "NVIDIA ${NVIDIA_VERSION} is not supported by cmpunlocker ${CMPUNLOCKER_REF} (supported: ${SUPPORTED_VERSIONS[*]}). Pick a compatible BASE_TAG or CMPUNLOCKER_REF. See README.md."
fi

if [[ ! -e "/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz" && ! -e "/usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko" ]]; then
    warn "No stock extra/nvidia module found; this may not be an Aurora nvidia-open base."
fi

###############################################################################
# 3. Build the patched modules with cmpunlocker's own driver/build.sh
###############################################################################
# cmpunlocker's build script uses `uname -r` for the target kernel and calls
# host-only tools (dracut/modprobe/systemctl).  The wrapper directory makes the
# target kernel explicit and makes those host operations no-ops.  The real
# initramfs is rebuilt later in the final image stage.
FAKEBIN="/tmp/cmp-fakebin"
REAL_UNAME="$(command -v uname)"
rm -rf "${FAKEBIN}"
mkdir -p "${FAKEBIN}"

cat > "${FAKEBIN}/uname" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-r" ]; then
    printf '%s\n' "${KVER}"
else
    exec "${REAL_UNAME}" "\$@"
fi
EOF

for cmd in dracut update-initramfs mkinitcpio modprobe systemctl rmmod killall; do
    cat > "${FAKEBIN}/${cmd}" <<EOF
#!/bin/sh
echo "[aurora-cmpunlocker] skipping ${cmd} in builder: \$*" >&2
exit 0
EOF
done

chmod 0755 "${FAKEBIN}"/*

log "Building patched NVIDIA ${NVIDIA_VERSION} modules (profile: ${CMPUNLOCKER_PROFILE})"
(
    cd "${CMP_DIR}"
    PATH="${FAKEBIN}:${PATH}" \
    CMPUNLOCKER_KVER="${KVER}" \
    CMPUNLOCKER_DRIVER_VERSION="${NVIDIA_VERSION}" \
    CMPUNLOCKER_CARD_PROFILE="${CMPUNLOCKER_PROFILE}" \
    CMPUNLOCKER_BUILD_DIR=/tmp/cmp-build \
        /bin/bash ./driver/build.sh
)

MODDEST="/usr/lib/modules/${KVER}/updates/cmpunlocker"
[[ -d "${MODDEST}" ]] || die "cmpunlocker build did not install modules to ${MODDEST}"
[[ -f "${MODDEST}/nvidia.ko" ]] || die "Patched nvidia.ko not found in ${MODDEST}"

# The mixed profile keeps the 8 GB / 10 GB geometry selection at runtime from
# the PCI device ID, so one image works for both card variants (and mixed
# multi-GPU systems).  Fixed profiles 8gb/10gb are available via build arg.

if is_enabled "${ENABLE_PASSTHROUGH}"; then
    log "Building cmp_no_bus_reset.ko (VFIO passthrough helper)"
    make -C "${CMP_DIR}/driver/passthrough" KVER="${KVER}" clean >/dev/null 2>&1 || true
    if make -C "${CMP_DIR}/driver/passthrough" KVER="${KVER}"; then
        install -m 0644 "${CMP_DIR}/driver/passthrough/cmp_no_bus_reset.ko" "${MODDEST}/"
    else
        warn "cmp_no_bus_reset.ko failed to build; disabling VFIO passthrough helpers (the host unlock is unaffected)"
        ENABLE_PASSTHROUGH=0
    fi
fi

depmod -a "${KVER}"

###############################################################################
# 4. Stage modules (signed if MOK secrets are available)
###############################################################################
log "Staging modules"
rm -rf "${OUT_DIR:?}"/*
install -d -m 0755 "${ROOTFS}" "${MODOUT}"

find "${MODDEST}" -maxdepth 1 -type f -name '*.ko' -print0 \
    | xargs -0 -r install -m 0644 -t "${MODOUT}/"
for f in driver_version card_profile unlock_geometry gpu_inventory; do
    if [[ -f "${MODDEST}/${f}" ]]; then
        install -m 0644 "${MODDEST}/${f}" "${MODOUT}/${f}"
    fi
done
[[ -f "${MODOUT}/nvidia.ko" ]] || die "No built nvidia.ko staged"

SIGNED=0
if [[ -s /run/secrets/mok_key && -s /run/secrets/mok_cert ]]; then
    log "Signing modules with the supplied MOK key"
    /bin/bash "${BUILD_FILES}/sign-modules.sh" "${MODOUT}"
    if [[ -f "${MODOUT}/mok.der" ]]; then
        SIGNED=1
        install -D -m 0644 "${MODOUT}/mok.der" \
            "${ROOTFS}/usr/share/aurora-cmpunlocker/mok.der"
        install -D -m 0644 "${MODOUT}/mok.der" \
            "${ROOTFS}/etc/pki/akmods/certs/aurora-cmpunlocker.der"
    else
        die "Signing was requested but no mok.der was produced"
    fi
else
    warn "No MOK key/cert supplied; patched modules are unsigned. Disable Secure Boot or supply secrets (see README.md)."
fi

(
    cd "${MODOUT}"
    sha256sum ./*.ko > SHA256SUMS
)

###############################################################################
# 5. Stage runtime integration files under /usr (never /usr/local)
###############################################################################
# /usr/local is a symlink to /var/usrlocal on bootc images.  Files placed there
# would live in /var (which must remain empty in the image) and would not be
# part of the immutable image.  Everything below uses /usr paths.
log "Staging runtime files"
HELPER_DIR="${ROOTFS}/usr/libexec/cmpunlocker"
DOC_DIR="${ROOTFS}/usr/share/cmpunlocker"
SYSTEMD_DIR="${ROOTFS}/usr/lib/systemd/system"
UDEV_DIR="${ROOTFS}/usr/lib/udev/rules.d"
MODPROBE_DIR="${ROOTFS}/etc/modprobe.d"
KARGS_DIR="${ROOTFS}/usr/lib/bootc/kargs.d"

install -d -m 0755 "${HELPER_DIR}" "${DOC_DIR}" "${SYSTEMD_DIR}" "${UDEV_DIR}" \
    "${MODPROBE_DIR}" "${KARGS_DIR}" "${ROOTFS}/usr/bin"

# system_files/ mirrors the final image layout (the image-template convention).
# Copy the whole tree, then drop the pieces disabled through build args.
[[ -d "${SYSTEM_FILES}" ]] || die "system_files directory not found at ${SYSTEM_FILES}"
cp -a "${SYSTEM_FILES}/." "${ROOTFS}/"

install -m 0644 "${CMP_DIR}/README.md" "${DOC_DIR}/README.md"
install -m 0644 "${CMP_DIR}/LICENSE" "${DOC_DIR}/LICENSE"
install -m 0644 "${CMP_DIR}/CREDITS.md" "${DOC_DIR}/CREDITS.md"
install -d -m 0755 "${DOC_DIR}/common" "${DOC_DIR}/tools" "${DOC_DIR}/driver"
install -m 0644 "${CMP_DIR}/common/lib.sh" "${DOC_DIR}/common/lib.sh"
install -m 0644 "${CMP_DIR}/driver/VERSION" "${DOC_DIR}/driver/VERSION"
install -m 0755 "${CMP_DIR}/verify.sh" "${DOC_DIR}/verify.sh"

# Upstream tools expect to live in the cmpunlocker tree; keep that layout at
# /usr/share/cmpunlocker and use small /usr/bin wrappers.
install -m 0755 "${BUILD_FILES}/service.sh" "${DOC_DIR}/tools/service.sh"
install -m 0755 "${CMP_DIR}/tools/passthrough.sh" "${DOC_DIR}/tools/passthrough.sh"
sed -i 's#^LIB="/usr/local/lib/cmpunlocker"#LIB="/usr/libexec/cmpunlocker"#' \
    "${DOC_DIR}/tools/passthrough.sh"
grep -q '^LIB="/usr/libexec/cmpunlocker"' "${DOC_DIR}/tools/passthrough.sh" \
    || die "Upstream passthrough.sh layout changed; update build.sh LIB rewrite"

cat > "${ROOTFS}/usr/bin/cmpunlocker-verify" <<'EOF'
#!/bin/sh
exec /usr/share/cmpunlocker/verify.sh "$@"
EOF
chmod 0755 "${ROOTFS}/usr/bin/cmpunlocker-verify"

if is_enabled "${ENABLE_PASSTHROUGH}"; then
    cat > "${ROOTFS}/usr/bin/cmpunlocker-passthrough" <<'EOF'
#!/bin/sh
exec /usr/share/cmpunlocker/tools/passthrough.sh "$@"
EOF
    chmod 0755 "${ROOTFS}/usr/bin/cmpunlocker-passthrough"

    log "Staging VFIO passthrough helpers"
    install -m 0755 "${CMP_DIR}/tools/gsp-restore.py" "${HELPER_DIR}/gsp-restore"
    install -m 0755 "${CMP_DIR}/tools/passthrough-arm.sh" "${HELPER_DIR}/passthrough-arm"

    python3 - "${CMP_DIR}/common/constants.yaml" "${HELPER_DIR}/gsp-regs.conf" <<'PY'
import io
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required to generate gsp-regs.conf")

constants_path, output_path = sys.argv[1:3]
with io.open(constants_path, encoding="utf-8") as handle:
    constants = yaml.safe_load(handle) or {}
regs = ((constants.get("passthrough") or {}).get("gsp_boot_state") or {})
if not regs:
    sys.exit("constants.yaml has no passthrough.gsp_boot_state")

lines = [
    "# generated from cmpunlocker common/constants.yaml",
    "# <addr> <value> <name>",
]
for name in sorted(regs):
    reg = regs[name]
    lines.append("%s %s %s" % (reg["addr"], reg["value"], name))
io.open(output_path, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
PY

    install -d -m 0755 "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/cmpunlocker-passthrough.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/cmpunlocker-passthrough.service"
else
    rm -f "${SYSTEMD_DIR}/cmpunlocker-passthrough.service" \
        "${UDEV_DIR}/99-cmpunlocker-passthrough.rules" \
        "${MODPROBE_DIR}/zz-cmpunlocker-vfio.conf"
fi

if is_enabled "${ENABLE_GEN2_SERVICE}"; then
    log "Staging early-boot PCIe Gen2 retrain service"
    install -m 0755 "${CMP_DIR}/tools/hammer.sh" "${HELPER_DIR}/gen2-hammer"

    install -d -m 0755 "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
    ln -sfn /usr/lib/systemd/system/gen2.service \
        "${ROOTFS}/etc/systemd/system/sysinit.target.wants/gen2.service"
else
    rm -f "${SYSTEMD_DIR}/gen2.service" \
        "${MODPROBE_DIR}/zz-cmpunlocker-gen2.conf"
fi

if ! is_enabled "${ENABLE_IOMMU_KARGS}"; then
    rm -f "${KARGS_DIR}/60-cmpunlocker-iommu.toml"
fi

###############################################################################
# 6. Build metadata
###############################################################################
install -d -m 0755 "${ROOTFS}/usr/share/aurora-cmpunlocker"
cat > "${ROOTFS}/usr/share/aurora-cmpunlocker/build-info" <<EOF
base_image=${BASE_IMAGE}
base_tag=${BASE_TAG}
akmods_tag=${AKMODS_TAG}
kernel=${KVER}
nvidia_version=${NVIDIA_VERSION}
cmpunlocker_repo=${CMPUNLOCKER_REPO}
cmpunlocker_ref=${CMPUNLOCKER_REF}
cmpunlocker_commit=${CMP_COMMIT}
cmpunlocker_profile=${CMPUNLOCKER_PROFILE}
gen2_service=$(is_enabled "${ENABLE_GEN2_SERVICE}" && echo true || echo false)
passthrough=$(is_enabled "${ENABLE_PASSTHROUGH}" && echo true || echo false)
iommu_kargs=$(is_enabled "${ENABLE_IOMMU_KARGS}" && echo true || echo false)
signed=$( (( SIGNED == 1 )) && echo true || echo false )
EOF

log "Done. Staged ${NVIDIA_VERSION} modules for ${KVER} (signed=${SIGNED})"
