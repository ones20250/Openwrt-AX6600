#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIX="$PROJECT_ROOT/Patches/qualcommax-qca8081-clock-fix.patch"
DRIVER=target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c

# The SSDK/NSS trees have a different clock driver and must not receive this
# PPE-specific backport. Both PURE and PLUS use this same preparation step.
if [[ ! -f "$DRIVER" ]]; then
    echo 'QCA8081 clock fix: no Qualcomm PPE driver; skipping.'
    exit 0
fi
if ! grep -Eq '^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*6\.18[[:space:]]*$' target/linux/qualcommax/Makefile; then
    echo 'QCA8081 clock fix: unsupported PPE kernel; review the backport before building.' >&2
    exit 1
fi

# Check the whole series first: a conflict must not leave just the clock
# tables or just the parent selection applied to a changing upstream tree.
if git apply --check "$FIX" 2>/dev/null; then
    # Preserve whitespace in the embedded GCC patch context verbatim.
    git apply --whitespace=nowarn "$FIX"
    echo 'QCA8081 clock fix: applied PPE parent selection and GCC frequency tables.'
elif git apply --reverse --check "$FIX" 2>/dev/null; then
    echo 'QCA8081 clock fix: complete backport already present.'
else
    echo 'QCA8081 clock fix: source drift or partial backport; refusing an unverified build.' >&2
    git apply --check "$FIX" >&2
    exit 1
fi
