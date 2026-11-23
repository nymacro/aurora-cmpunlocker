#!/bin/bash
#
# Bootc-friendly subset of cmpunlocker's tools/service.sh.
#
# The unit file and gen2-hammer are shipped in the immutable image, so only
# verify/status make sense at runtime.  The upstream install/remove actions are
# intentionally not exposed: use bootc switch to change or remove this variant.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_NAME="gen2.service"
LOG_FILE="/var/log/gen2.log"

# Provided by cmpunlocker at /usr/share/cmpunlocker/common/lib.sh at runtime.
# shellcheck source=/dev/null
source "${PROJECT_DIR}/common/lib.sh"

usage() {
    cat <<EOF
Usage:
  sudo $0 verify    Verify negotiated PCIe link speed and show the boot log
  $0 status         Show whether gen2.service is enabled/running

The service and /usr/libexec/cmpunlocker/gen2-hammer are part of the image.
This bootc variant has no install/remove action; rebase to change the image.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this action as root"
}

supported_gpus() {
    local id
    for id in 20c2 2082; do
        lspci -D -d "10de:${id}" 2>/dev/null | awk '{print $1}'
    done
}

link_generation() {
    local status
    status="$(setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true)"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

show_status() {
    if [[ -f "/usr/lib/systemd/system/${SERVICE_NAME}" ]]; then
        ok "Service file installed: /usr/lib/systemd/system/${SERVICE_NAME}"
    else
        warn "Service file is not installed"
    fi
    systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true
    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
    if [[ -f "${LOG_FILE}" ]]; then
        info "Last early-retrain log:"
        tail -n 30 "${LOG_FILE}"
    else
        warn "No ${LOG_FILE}; the early service has not run yet"
    fi
}

verify_links() {
    local gpu bridge status generation speed width max_speed result
    local failures=0
    local -a gpus=()

    require_root
    command -v lspci >/dev/null || die "lspci not found (install pciutils)"
    command -v setpci >/dev/null || die "setpci not found (install pciutils)"

    mapfile -t gpus < <(supported_gpus)
    [[ ${#gpus[@]} -gt 0 ]] || die "No supported CMP 170HX found (10de:20c2 / 10de:2082)"

    printf '%-16s %-16s %-8s %-14s %-8s %s\n' \
        "GPU" "Upstream" "LnkSta" "Current speed" "Width" "Result"
    for gpu in "${gpus[@]}"; do
        bridge="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
        status="$(setpci -s "${gpu}" CAP_EXP+12.w 2>/dev/null || echo unreadable)"
        generation="$(link_generation "${gpu}")"
        speed="$(cat "/sys/bus/pci/devices/${gpu}/current_link_speed" 2>/dev/null || echo unknown)"
        width="$(cat "/sys/bus/pci/devices/${gpu}/current_link_width" 2>/dev/null || echo unknown)"
        max_speed="$(cat "/sys/bus/pci/devices/${gpu}/max_link_speed" 2>/dev/null || echo unknown)"
        if [[ "${generation}" =~ ^[0-9]+$ ]] && (( generation >= 2 )); then
            result="GEN2 OK"
        else
            result="GEN1"
            failures=$((failures + 1))
        fi
        printf '%-16s %-16s %-8s %-14s x%-7s %s\n' \
            "${gpu}" "${bridge}" "0x${status}" "${speed}" "${width}" "${result}"
        info "${gpu}: sysfs max=${max_speed}; negotiated generation is authoritative"
    done

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo
        nvidia-smi \
            --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max \
            --format=csv 2>/dev/null || true
    fi

    echo
    if [[ -f "${LOG_FILE}" ]]; then
        info "Last early-retrain log:"
        tail -n 30 "${LOG_FILE}"
    else
        warn "No ${LOG_FILE}; the early service has not run yet"
    fi

    if (( failures > 0 )); then
        die "${failures} GPU(s) are still negotiated at Gen1"
    fi
    ok "All supported GPUs are negotiated at Gen2 or better"
}

case "${1:-}" in
    verify) verify_links ;;
    status) show_status ;;
    install|remove)
        die "gen2.service is baked into this bootc image; use bootc switch to change it"
        ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 1 ;;
esac
