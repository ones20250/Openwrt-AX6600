# QCA8081 port clock backport

`qualcommax-qca8081-clock-fix.patch` backports OpenWrt
[PR #24566](https://github.com/openwrt/openwrt/pull/24566), commits
`6985f61db8aeb2911a7e79515bace5690d35cd1b` and
`d21c9d3b1b936ae392489ead075fda5719095e30`.
Original authorship and Signed-off-by trailers are retained. Only the
include hunk's context was reduced for this fork's extra QCA PPE header;
the added C code and GCC patches are unchanged.

The series selects each PPE port's PCS RX/TX clock parents before setting
rates and keeps port 5 on UNIPHY1 at SGMII rates. The common build helper
applies both parts atomically to PPE sources, accepts a complete existing
backport, and rejects partial backports or conflicts. When upstream changes
or incorporates the fix, refresh or remove this series rather than bypassing
the check.
