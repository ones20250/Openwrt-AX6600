#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise patch integration against a real, unmodified OpenWrt source checkout.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$REPO_ROOT/.github/scripts/prepare-qca8081-clock-fix.sh"
SOURCE=${1:?Usage: test_qca8081_clock_fix.sh /path/to/unmodified/OpenWrt}
SOURCE=$(cd "$SOURCE" && pwd)
DRIVER=target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c
TARGET=target/linux/qualcommax/Makefile
test -f "$SOURCE/$DRIVER"
test -f "$SOURCE/$TARGET"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fresh_tree() {
    TREE="$TMP/$1"
    mkdir -p "$TREE/$(dirname "$DRIVER")"
    cp "$SOURCE/$DRIVER" "$TREE/$DRIVER"
    cp "$SOURCE/$TARGET" "$TREE/$TARGET"
    git -C "$TREE" init -q
}
run_helper() { (cd "$TREE" && bash "$HELPER"); }
snapshot() { (cd "$TREE" && find target -type f -print0 | sort -z | xargs -0 sha256sum); }

fresh_tree clean
run_helper
grep -q 'ret = clk_set_parent(rcg, parent);' "$TREE/$DRIVER"
grep -q 'ret = ppe_port_clk_parents(priv);' "$TREE/$DRIVER"
test -s "$TREE/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
test -s "$TREE/target/linux/qualcommax/patches-6.18/0919-clk-qcom-gcc-ipq8074-keep-port-5-on-uniphy1-at-SGMII-rates.patch"
snapshot > "$TMP/once"
run_helper
snapshot > "$TMP/twice"
cmp "$TMP/once" "$TMP/twice"
echo 'PASS: complete fix applies to real source and repeated application is unchanged'

fresh_tree drift
sed -i 's/ppe_scheduler_init(priv);/ppe_scheduler_init_changed(priv);/' "$TREE/$DRIVER"
snapshot > "$TMP/drift-before"
if run_helper > "$TMP/drift.log" 2>&1; then
    echo 'FAIL: incompatible source was accepted' >&2; exit 1
fi
snapshot > "$TMP/drift-after"
cmp "$TMP/drift-before" "$TMP/drift-after"
echo 'PASS: source drift fails without leaving partially applied patches'

fresh_tree partial
mkdir -p "$TREE/target/linux/qualcommax/patches-6.18"
cp "$TMP/clean/target/linux/qualcommax/patches-6.18/0918-clk-qcom-gcc-ipq6018-keep-port-5-on-uniphy1-at-SGMII-rates.patch" "$TREE/target/linux/qualcommax/patches-6.18/"
snapshot > "$TMP/partial-before"
if run_helper > "$TMP/partial.log" 2>&1; then
    echo 'FAIL: incomplete existing fix was accepted' >&2; exit 1
fi
snapshot > "$TMP/partial-after"
cmp "$TMP/partial-before" "$TMP/partial-after"
echo 'PASS: incomplete existing fix fails without modifying source'

fresh_tree kernel
sed -i 's/KERNEL_PATCHVER:=6.18/KERNEL_PATCHVER:=6.12/' "$TREE/$TARGET"
snapshot > "$TMP/kernel-before"
if run_helper > "$TMP/kernel.log" 2>&1; then
    echo 'FAIL: unsupported PPE kernel was accepted' >&2; exit 1
fi
snapshot > "$TMP/kernel-after"
cmp "$TMP/kernel-before" "$TMP/kernel-after"
echo 'PASS: unsupported kernel fails without modification'

TREE="$TMP/non-ppe"
mkdir -p "$TREE"
run_helper
test -z "$(find "$TREE" -type f -print -quit)"
echo 'PASS: non-PPE source is left unchanged'

python3 - "$REPO_ROOT/.github/workflows/WRT-CORE.yml" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
helper=s.index('.github/scripts/prepare-qca8081-clock-fix.sh')
assert s.index('- name: Clone Code') < helper < s.index('- name: Update Feeds')
assert s.rfind('- name:',0,helper) > s.index('- name: Clone Code')
print('PASS: shared workflow applies the fix before configuration for PURE and PLUS')
PY
