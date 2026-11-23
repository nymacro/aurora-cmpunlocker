base_tag := env("BASE_TAG", "stable-44.20260922.1")
akmods_tag := env("AKMODS_TAG", "coreos-testing-44-7.1.10-200.fc44.x86_64")
cmpunlocker_ref := env("CMPUNLOCKER_REF", "v0.5")
expected_nvidia_version := env("EXPECTED_NVIDIA_VERSION", "615.71.09")
image_tag := env("IMAGE_TAG", "stable")
image := env("IMAGE", "localhost/aurora-cmpunlocker:" + image_tag)

default:
    @just --list

# Check shell syntax of the build helpers.
check:
    #!/usr/bin/env bash
    set -euo pipefail
    find build_files -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
    echo "shell syntax OK"

# Build the image locally; unsigned if MOK_KEY/MOK_CERT are unset.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .cache/mok
    if [[ -n "${MOK_KEY:-}" && -n "${MOK_CERT:-}" ]]; then
        install -m 0600 "${MOK_KEY}" .cache/mok/mok.key
        install -m 0644 "${MOK_CERT}" .cache/mok/mok.crt
    else
        : > .cache/mok/mok.key
        : > .cache/mok/mok.crt
        echo "MOK_KEY/MOK_CERT not set: building with unsigned modules"
    fi
    podman build \
        --pull=always \
        --network=host \
        --platform linux/amd64 \
        --build-arg BASE_TAG="{{ base_tag }}" \
        --build-arg AKMODS_TAG="{{ akmods_tag }}" \
        --build-arg CMPUNLOCKER_REF="{{ cmpunlocker_ref }}" \
        --build-arg EXPECTED_NVIDIA_VERSION="{{ expected_nvidia_version }}" \
        --build-arg SOURCE_URL="https://github.com/${GITHUB_REPOSITORY:-local/aurora-cmpunlocker}" \
        --build-arg SOURCE_REVISION="${GITHUB_SHA:-local}" \
        --secret id=mok_key,src=.cache/mok/mok.key \
        --secret id=mok_cert,src=.cache/mok/mok.crt \
        --tag "{{ image }}" \
        .

# Run the same lint the CI runs.
lint:
    podman run --rm "{{ image }}" bootc container lint --fatal-warnings --no-truncate

# Verify the modules from inside the built image.
verify:
    podman run --rm "{{ image }}" bash -lc 'KVER=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}.%{ARCH}" kernel-core); modinfo -k "$KVER" -n nvidia; cat /usr/share/aurora-cmpunlocker/build-info'

# Generate a MOK key/cert pair for optional Secure Boot signing.
generate-mok:
    ./build_files/generate-mok.sh keys
