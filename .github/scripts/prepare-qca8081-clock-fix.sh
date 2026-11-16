#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIX="$PROJECT_ROOT/Patches/qualcommax-qca8081-clock-fix.patch"
DRIVER=target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c

# The SSDK/NSS trees have a different clock driver and must not receive this
# PPE-specific backport. Both PURE and PLUS use this same preparation step.
if [[ ! -f "$DRIVER" ]]; then
    if [[ "${GITHUB_ACTIONS:-false}" == "true" || "${CI:-false}" == "true" ]]; then
        echo 'QCA8081 clock fix: missing Qualcomm PPE driver in CI environment; refusing build.' >&2
        exit 1
    else
        echo 'QCA8081 clock fix: no Qualcomm PPE driver; skipping.'
        exit 0
    fi
fi
if ! grep -Eq '^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*6\.18[[:space:]]*$' target/linux/qualcommax/Makefile; then
    echo 'QCA8081 clock fix: unsupported PPE kernel; review the backport before building.' >&2
    exit 1
fi

# Check if the complete backport is already present (either via upstream native integration or previously applied patch)
HAS_PPE_FIX=false
HAS_CLK_FIX=false

if grep -q 'ppe_port_clk_parents' "$DRIVER" 2>/dev/null; then
    HAS_PPE_FIX=true
fi

if grep -rq 'C(P_UNIPHY1_RX, 1, 0, 0)' target/linux/qualcommax/patches-6.18/ 2>/dev/null; then
    HAS_CLK_FIX=true
fi

if [[ "$HAS_PPE_FIX" == "true" && "$HAS_CLK_FIX" == "true" ]]; then
    echo 'QCA8081 clock fix: complete backport already present.'
    exit 0
elif [[ "$HAS_PPE_FIX" == "true" || "$HAS_CLK_FIX" == "true" ]]; then
    echo 'QCA8081 clock fix: source drift or partial backport; refusing an unverified build.' >&2
    exit 1
elif git apply --check "$FIX" 2>/dev/null; then
    # Preserve whitespace in the embedded GCC patch context verbatim.
    git apply --whitespace=nowarn "$FIX"
    echo 'QCA8081 clock fix: applied PPE parent selection and GCC frequency tables.'
    exit 0
else
    echo 'QCA8081 clock fix: source drift or partial backport; refusing an unverified build.' >&2
    git apply --check "$FIX" >&2
    exit 1
fi
