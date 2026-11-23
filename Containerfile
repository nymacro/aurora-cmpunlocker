# syntax=docker/dockerfile:1.7
#
# Aurora nvidia-open + cmpunlocker
# ================================
#
# This is a bootc/OCI variant of Aurora's nvidia-open image.  The NVIDIA
# userspace, firmware and desktop come from the pinned Aurora base image; the
# kernel modules are rebuilt from the matching NVIDIA open-gpu-kernel-modules
# release with cmpunlocker's CMP 170HX patches applied.
#
# The build is intentionally split in two stages:
#   * "akmods" supplies the exact kernel-devel RPM for the kernel in the base
#     image (Aurora builds its images against these pinned akmods layers).
#   * "builder" installs those headers, downloads the matching NVIDIA source,
#     applies cmpunlocker, builds/signs the modules and stages all runtime
#     files.
# The final stage only receives the staged files, installs the modules into
# /usr/lib/modules/<kver>/updates/cmpunlocker, runs depmod and rebuilds the
# initramfs.
#
# See README.md for the compatibility matrix.  The defaults below are the
# newest Aurora *stable* nvidia-open image that ships an NVIDIA release
# supported by cmpunlocker v0.5 (615.71.09).

ARG BASE_IMAGE="ghcr.io/ublue-os/aurora-nvidia-open"
ARG BASE_TAG="stable-44.20260922.1"
ARG AKMODS_IMAGE="ghcr.io/ublue-os/akmods-nvidia-open"
ARG AKMODS_TAG="coreos-testing-44-7.1.10-200.fc44.x86_64"

# ---------------------------------------------------------------------------
# Exact kernel-devel / kernel RPMs for the base image's kernel
# ---------------------------------------------------------------------------
FROM ${AKMODS_IMAGE}:${AKMODS_TAG} AS akmods

# ---------------------------------------------------------------------------
# Build the patched modules
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${BASE_TAG} AS builder

ARG BASE_IMAGE
ARG BASE_TAG
ARG AKMODS_TAG
ARG CMPUNLOCKER_REPO="https://github.com/amoghmunikote/cmpunlocker.git"
ARG CMPUNLOCKER_REF="v0.5"
ARG CMPUNLOCKER_PROFILE="mixed"
ARG NVIDIA_VERSION=""
ARG EXPECTED_NVIDIA_VERSION="615.71.09"
ARG ENABLE_GEN2_SERVICE="1"
ARG ENABLE_PASSTHROUGH="1"
ARG ENABLE_IOMMU_KARGS="1"

COPY build_files/ /tmp/build_files/

RUN --mount=type=bind,from=akmods,source=/kernel-rpms,target=/tmp/kernel-rpms \
    --mount=type=secret,id=mok_key \
    --mount=type=secret,id=mok_cert \
    BASE_IMAGE="${BASE_IMAGE}" \
    BASE_TAG="${BASE_TAG}" \
    AKMODS_TAG="${AKMODS_TAG}" \
    CMPUNLOCKER_REPO="${CMPUNLOCKER_REPO}" \
    CMPUNLOCKER_REF="${CMPUNLOCKER_REF}" \
    CMPUNLOCKER_PROFILE="${CMPUNLOCKER_PROFILE}" \
    NVIDIA_VERSION="${NVIDIA_VERSION}" \
    EXPECTED_NVIDIA_VERSION="${EXPECTED_NVIDIA_VERSION}" \
    ENABLE_GEN2_SERVICE="${ENABLE_GEN2_SERVICE}" \
    ENABLE_PASSTHROUGH="${ENABLE_PASSTHROUGH}" \
    ENABLE_IOMMU_KARGS="${ENABLE_IOMMU_KARGS}" \
    /bin/bash /tmp/build_files/build-modules.sh

# ---------------------------------------------------------------------------
# Final bootc image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG BASE_IMAGE
ARG BASE_TAG
ARG CMPUNLOCKER_REF="v0.5"
ARG SOURCE_URL=""
ARG SOURCE_REVISION=""
ARG REBUILD_INITRAMFS="1"

LABEL org.opencontainers.image.title="aurora-cmpunlocker" \
      org.opencontainers.image.description="Aurora nvidia-open with cmpunlocker-patched NVIDIA open kernel modules for the CMP 170HX" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND GPL-2.0-only" \
      org.opencontainers.image.base.name="${BASE_IMAGE}:${BASE_TAG}" \
      io.github.aurora-cmpunlocker.base-image="${BASE_IMAGE}:${BASE_TAG}" \
      io.github.aurora-cmpunlocker.cmpunlocker-ref="${CMPUNLOCKER_REF}"

COPY --from=builder /out/rootfs/ /
COPY --from=builder /out/modules /tmp/cmpunlocker-modules
COPY build_files/install-modules.sh /tmp/install-modules.sh

# /boot and /var are mounted as tmpfs for dracut, matching Aurora's own
# initramfs build.  /var is runtime-only and must stay empty in the image.
RUN --network=none \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/var \
    REBUILD_INITRAMFS="${REBUILD_INITRAMFS}" \
    /bin/bash /tmp/install-modules.sh && \
    rm -rf /tmp/install-modules.sh /tmp/cmpunlocker-modules

# Keep this in the image build so regressions are caught before publishing.
RUN --network=none bootc container lint --fatal-warnings --no-truncate

CMD ["/sbin/init"]
