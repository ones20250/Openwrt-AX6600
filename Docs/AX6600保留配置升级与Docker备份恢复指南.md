# 京东云 AX6600 雅典娜 保留配置升级与 Docker 备份恢复指南

本指南适用于京东云 AX6600（雅典娜 RE-CS-02）从旧版固件升级至 Linux 6.18 LTS（Qualcomm PPE + firewall4）固件。提供升级前分区与存储体检、Docker 全量与数据库一致性备份、保留配置平滑升级、NSS 遗留项清理以及端到端功能验收规范。

---

## 一、升级前红线与只读检查

在执行任何升级或备份操作前，请先在雅典娜路由器终端（SSH）执行以下只读检查，确认系统环境与硬件状态。

### 1. 固件版本与硬件型号确认
```bash
# 查看当前固件版本描述
cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION

# 查看设备型号
cat /tmp/sysinfo/model 2>/dev/null || cat /proc/device-tree/model 2>/dev/null
```

### 2. 目标升级分区与容量核查（严格遵循 BOOTCONFIG 判定机制，严禁 60MB 原厂分区刷入 PLUS）
雅典娜采用 eMMC 双系统分区设计（内核为 `0:HLOS`/`0:HLOS_1`，根文件系统为 `rootfs`/`rootfs_1`）。OpenWrt 平台的 `sysupgrade`（`platform.sh`）通过读取 `0:BOOTCONFIG` 分区第 148 字节标记确定目标写入分区：
- 标记为 `1`：写入对侧 `0:HLOS_1`（内核）与 `rootfs_1`（根文件系统）；
- 标记为 `0`：写入对侧 `0:HLOS`（内核）与 `rootfs`（根文件系统）；
- **严格判定原则**：若 `0:BOOTCONFIG` 缺失或读取失败，辅助工具及升级流程将**立即严格报错退出**，绝不盲猜分区、绝不在双分区中误取较小分区；若待写入的目标对侧分区（如 `0:HLOS_1` 或 `rootfs_1`）不存在，严禁向同名或非目标分区借用扇区容量，必须即刻阻断。

```bash
# 1. 查看 BOOTCONFIG 分区偏移 148 字节标记（确定主备切换目标，严格基于 partlabel 或 sysfs 权威节点）
CFG_DEV=$(readlink -f /dev/disk/by-partlabel/0:BOOTCONFIG 2>/dev/null || grep -l "PARTNAME=0:BOOTCONFIG" /sys/class/block/mmcblk0p*/uevent 2>/dev/null | sed 's|/uevent||' | sed 's|.*/|/dev/|')
[ -e "$CFG_DEV" ] && (hexdump -e '1/1 "%01x|"' -n 1 -s 148 -C "$CFG_DEV" 2>/dev/null || od -An -tx1 -N 1 -j 148 "$CFG_DEV")

# 2. 查看 eMMC 分区表及实际分区名称与扇区容量
# 注：util-linux 标准 fdisk -l 在 GPT 下不输出 Name 列，系统内核 sysfs 是最权威的数据源：
for u in /sys/class/block/mmcblk0p*/uevent; do
    [ -f "$u" ] || continue
    pname=$(grep '^PARTNAME=' "$u" | cut -d= -f2)
    pdev=$(grep '^DEVNAME=' "$u" | cut -d= -f2)
    psize=$(cat "/sys/class/block/$pdev/size" 2>/dev/null || echo 0)
    psize_mb=$(( psize * 512 / 1024 / 1024 ))
    echo "设备: /dev/$pdev, 分区名: $pname, 扇区: $psize (${psize_mb} MB)"
done | grep -E "0:BOOTCONFIG|0:HLOS|rootfs"

# 3. 提取固件包内实际 kernel 与 root 字节大小（sysupgrade 格式 tar 包预检）
tar -tvf /tmp/ones20250-owrt-plus-*.bin 2>/dev/null | grep -E "kernel|root"
```
- **容量红线判定**：
  - 本次 PLUS 完整升级包约为 **152.04 MB**（解压后实际 `root` 镜像约 130-150MB，`kernel` 约 4-6MB）。
  - 辅助工具在预检时会解包分析固件内部 `kernel` 和 `root` 的精确字节数，比对目标分区可用容量，且要求目标 rootfs 分区在承载固件解压后必须保留至少 **50 MB** 的内部 overlay 存储空间；
  - 为保证系统启动后有足够的内部临时存储空间，待升级目标根文件系统分区必须 **大于 200 MB**（如扩容后的 512MB 或 1024MB 分区），目标内核分区需大于 6MB。
  - 若待升级的对侧分区仅为 **60 MB**（未扩容的原厂双分区状态），**严禁刷入 PLUS 版**（会导致分区溢出变砖！），请先选择 30MB 的 `PURE` 纯净版，或使用 U-Boot 重新刷入扩容分区表。
  - **重要原则**：绝不能根据整机 64GB/128GB eMMC 的总存储容量来判断能否刷入，必须精确核对待写入的目标分区实际大小；双分区机型绝不能盲目取两者中较大的一个。

### 3. Docker 运行状态与存储介质归属排查
```bash
# 查看 Docker 版本与存储驱动
docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version
docker info -f '{{.Driver}}' 2>/dev/null

# 必须在 dockerd 运行状态下探测真实 DockerRootDir（禁止盲猜默认路径）
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
echo "当前 DockerRootDir: $DOCKER_ROOT"

# 查看 DockerRootDir 所在文件系统挂载点与设备类型
df -h "$DOCKER_ROOT"
mount | grep -E " / | /overlay "
```

#### 存储介质分类与风险等级：
1. **内部 eMMC Overlay（高危！`mount` 显示设备为 `/dev/mmcblk0p*` 挂载在 `/overlay`）**：
   > ⚠️ **底层原理**：OpenWrt 的 `sysupgrade` 机制在刷写 squashfs 固件时，**默认会擦除并重新格式化内部 flash 的 overlay 分区**！保留配置（`-c` 参数）仅仅是按 `/etc/sysupgrade.conf` 打包恢复指定的文本配置文件，**绝不等于保留整个 overlay**！
   > 若 DockerRootDir 位于内部 overlay（如 `/overlay/docker`），直接升级将导致 Docker 镜像、Named Volumes 与容器可写层被彻底销毁！升级前必须完整导出到外部存储或 PC！
2. **Extroot 外置 USB 存储（中危，`mount` 显示 `/dev/sd*` 挂载在 `/overlay`）**：
   数据位于外置 U 盘/移动硬盘，但根文件系统依赖该外置存储，升级新内核后需防范挂载兼容性。
3. **独立外部数据分区（推荐安全架构，`mount` 显示 `/dev/sd*` 挂载在 `/mnt/sda1` 等独立目录）**：
   Docker 数据完全独立于系统根目录，不受固件刷写影响。但升级后**必须先确认存储挂载就绪，再启动 Docker**，避免 dockerd 在空挂载目录下重新初始化覆盖。

### 4. 扫描现有卷（Volumes）与绑定挂载（Bind Mounts）
```bash
# 列出全部 Named Volumes
docker volume ls

# 列出所有容器的宿主机绑定挂载路径 (Bind Mounts，通过 Type=bind 严格过滤命名卷)
docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{println}}{{end}}{{end}}' $(docker ps -aq) 2>/dev/null | sort -u
```

### 5. 唯一固件文件校验与机型兼容性预检
定义唯一的 `IMAGE` 变量，拒绝通配符匹配，并比对官方 Release SHA256 校验和：
```bash
# 以官方最新 PLUS 固件为例
IMAGE="/tmp/ones20250-owrt-plus-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.10.27-20.11.54.bin"
EXPECTED_SHA="bdd9f3c2a2aba88fd59f6d0891c0c5fecfd3aca83834ee38cfaea4d935d91865"

[ ! -f "$IMAGE" ] && { echo "固件文件不存在: $IMAGE"; exit 1; }

# 核对哈希
ACTUAL_SHA=$(sha256sum "$IMAGE" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "ERROR: 固件 SHA256 校验不匹配！预期: $EXPECTED_SHA, 实际: $ACTUAL_SHA"
    exit 1
fi
echo "固件 SHA256 校验一致: $ACTUAL_SHA"

# 机型兼容性预检（验证硬件平台与固件元数据兼容）
sysupgrade -T "$IMAGE" || { echo "机型兼容性校验未通过，禁止刷入！"; exit 1; }
```

---

## 二、Docker 全量备份与数据库一致性导出

为保证绝对数据安全，备份必须保存到外部独立挂载存储（如 `/mnt/sda1`）或通过 SSH 流式传输至个人电脑。**严禁把唯一备份保存在易失的 `/tmp`（内存盘）或升级后将被重置的内部 `/overlay` 中！严禁向内存中的 `/tmp` 打包数十 GB 的大体积 Docker 数据（会导致内存溢出 OOM 重启挂机）！**

### 1. 数据库应用级逻辑热备（在停止容器前执行）
如果你的 Docker 中运行有 MySQL、PostgreSQL 或 Redis 等数据库容器，在直接停止前应优先执行应用一致性导出，确保事务完全落盘：

```bash
# MySQL / MariaDB 逻辑全备
docker exec <mysql_container> mysqldump -u root -p<密码> --all-databases --single-transaction --quick > /mnt/sda1/mysql_all_backup.sql

# PostgreSQL 逻辑全备
docker exec <postgres_container> pg_dumpall -U postgres > /mnt/sda1/postgres_all_backup.sql

# Redis 强制落盘
docker exec <redis_container> redis-cli SAVE
```

### 2. 停机顺序与一致性保障说明
1. **业务影响**：停用容器与 dockerd 后，基于 Docker 运行的服务（如本地内网穿透、自建 DNS、媒体库等）将暂时下线；
2. **严格操作时序**：
   - 步骤 ①：导出容器清单、inspect 元数据与 Compose 目录（含 `.env` 配置文件）；在修改任何服务状态前先预检独立容器参数合法性，遇到多网络/依赖容器等无法单命令还原的配置时提前明确阻断；
   - 步骤 ②：完成数据库应用级一致性热备（MySQL / MariaDB / Postgres / Redis 转储）；
   - 步骤 ③：**临时禁用 dockerd 开机自启动**（避免升级首次开机在外盘未就绪时误在空目录初始化）；
   - 步骤 ④：**优雅停止运行中的所有业务容器**（`docker stop`，使容器内进程正常关机并完成数据完全落盘）；
   - 步骤 ⑤：**提交并导出独立容器镜像快照**（在容器停机后执行 `docker commit` 与 `docker save`，保证停机刷盘的数据完整写入镜像），同时生成带完整单引号安全转义的独立容器重建脚本；
   - 步骤 ⑥：**停止 dockerd 守护进程**（`/etc/init.d/dockerd stop`）；
   - 步骤 ⑦：打包归档 Named Volumes、各 Compose 项目工作目录与 Bind Mounts 目录，同时将各组件解压所需空间精确记录至 `metadata/uncompressed_sizes.tsv` 与 `backup_manifest.txt`；
   - 步骤 ⑧：生成全局校验清单 `sha256sums.txt`（通过隐藏临时文件严格排除自身与清单文件，杜绝哈希污染），并在完成打包后立即在原地执行 `sha256sum -c sha256sums.txt` 严密自检，确保归档未发生位翻转或损坏。

### 3. 使用辅助脚本执行自动化备份
项目提供了完善的 POSIX 兼容辅助工具 `Scripts/docker_upgrade_helper.sh`：
```bash
# 1. 上传或准备脚本
chmod +x /tmp/docker_upgrade_helper.sh

# 2. 执行备份（指定外部挂载目标路径，如 /mnt/sda1/docker_backup_20261027）
/tmp/docker_upgrade_helper.sh backup --target-dir /mnt/sda1/docker_backup_$(date +%Y%m%d)
```
脚本会自动完成：
- 探测并安全核对 `DockerRootDir` 挂载介质（拒绝 `/overlay` 和 `/tmp` 目标）；
- 导出各 Compose 项目配置文件（包括隐藏 `.env` 文件）；
- 自动检测 MySQL/MariaDB/Postgres 容器并执行一致性 dump；
- 对有变动的独立容器在停机落盘后提交快照镜像并生成重建命令；
- 记录 Docker 原自启状态，升级前临时禁用自启动；
- 优雅停止容器与 dockerd 服务；
- 打包 Named Volumes 与宿主 Bind Mounts，记录解压空间并生成 `sha256sums.txt` 与 `backup_manifest.txt`；
- 执行就地校验和自检；
- 自动将恢复辅助脚本复制一份至备份介质根目录，确保重启后脱机可用。

### 4. 远程 SSH 流式备份至电脑（无路由器外挂盘时的方案）
若路由器未连接外部移动硬盘，可直接在电脑终端通过 SSH 管道将归档数据直接写入电脑本地硬盘：

#### Linux / macOS 电脑终端：
```bash
ssh root@192.168.1.1 '
    set -e
    DOCKER_ROOT=$(docker info -f "{{.DockerRootDir}}")
    /etc/init.d/dockerd stop
    tar -cz -C "$DOCKER_ROOT" volumes
' > ~/Desktop/athena_docker_volumes_$(date +%Y%m%d).tar.gz

# 校验电脑端归档完整性
tar -tzvf ~/Desktop/athena_docker_volumes_*.tar.gz | head -20
```

#### Windows PowerShell 电脑终端：
```powershell
$cmd = 'DOCKER_ROOT=$(docker info -f "{{.DockerRootDir}}"); /etc/init.d/dockerd stop; tar -cz -C "$DOCKER_ROOT" volumes'
ssh root@192.168.1.1 "sh -c '$cmd'" > "C:\Athena_Backup\docker_volumes_$(Get-Date -Format 'yyyyMMdd').tar.gz"

# 检查归档可读性
tar -tzvf "C:\Athena_Backup\docker_volumes_*.tar.gz" | Select-Object -First 20
```

---

## 三、保留配置平滑升级与 NSS 遗留项精准清理

### 1. 执行保留配置刷入
在确认升级前检查全部通过且备份已妥善保存后，执行升级：
```bash
IMAGE="/tmp/ones20250-owrt-plus-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.10.27-20.11.54.bin"
sysupgrade -c -v "$IMAGE"
```
系统将保留现有网络、Wi-Fi、DHCP、防火墙及用户自定义规则并自动重启。

### 2. 首次启动与安全接管原则
- 首次开机进入系统后，**绝对不要立即手动启动 dockerd**！
- 必须先确认外部存储设备已被内核识别并正确挂载到了既定目录。

### 3. 精准清理 NSS 专用失效条目（严禁覆盖整份防火墙配置）
因新固件迁移至 Linux 6.18 LTS 并采用开源 PPE 硬件加速，旧固件中残留的闭源 NSS 防火墙 include 钩子已失效。**升级方案严禁为了启用 PPE 而直接覆盖或重置用户的整份旧防火墙配置！** 必须在备份后仅精准清理确认失效的 NSS 节：

```bash
# 推荐使用备份盘中随附的 helper 执行（自动备份旧配置并精准清理）
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh clean-nss
```

或手动执行审查与清理：
```bash
# 1. 检查是否存在 firewall.qcanssecm
if uci -q get firewall.qcanssecm >/dev/null; then
    SEC_TYPE=$(uci -q get firewall.qcanssecm || true)
    SCRIPT_PATH=$(uci -q get firewall.qcanssecm.path || true)
    
    # 严格核对：节类型必须为 include，且路径严格匹配已废弃的旧 NSS 脚本
    if [ "$SEC_TYPE" = "include" ]; then
        case "$SCRIPT_PATH" in
            /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss|/etc/init.d/qca-nss-ecm)
                echo "发现废弃 NSS 防火墙钩子 ($SCRIPT_PATH)，正在备份并安全清理..."
                # 备份旧配置
                cp /etc/config/firewall /etc/config/firewall.bak.$(date +%Y%m%d%H%M%S)
                # 仅删除该废弃条目
                uci delete firewall.qcanssecm
                uci commit firewall
                /etc/init.d/firewall reload
                echo "NSS 废弃 include 项清理完成，所有用户自定义规则与端口转发已完好保留。"
                ;;
            *)
                echo "firewall.qcanssecm 指向未知脚本 ($SCRIPT_PATH)，保留不做修改。"
                ;;
        esac
    else
        echo "firewall.qcanssecm 属于非 include 规则（如用户同名 rule），严禁删除！"
    fi
fi
```

---

## 四、Docker 完整恢复流程

### 1. 核对外部数据盘挂载
```bash
# 确认外置存储挂载点与设备真实就绪（不能仅检查目录存在）
df -h | grep /mnt/sda1 || mount /mnt/sda1
```

### 2. 执行数据还原与服务恢复
使用备份目录中的 helper 脚本执行恢复（不依赖任何升级前的旧临时变量）：
```bash
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh restore \
    --backup-dir /mnt/sda1/docker_backup_20261027 \
    --target-data-root /mnt/sda1/docker_data
```
还原流程包括：
- **完整性双重验证**：严格校验全局 `sha256sums.txt`、`backup_manifest.txt` 清单与所有备份组件（包括独立容器镜像归档与重建脚本、Compose 归档、Volumes 归档、Bind 归档及数据库转储），任一文件缺失或哈希不匹配即刻阻断；
- **文件系统挂载点聚合容量校验**：通过 `df -P` 精准识别 DataRoot、各 Compose 项目目标目录、各 Bind Mounts 目标目录分别归属的文件系统挂载点；若多个组件恢复至同一存储分区，脚本会自动聚合累加所有组件的**实际解压后体积**（读取 `metadata/uncompressed_sizes.tsv`），并校验该挂载点可用空间满足 `总解压需求 + 10MB` 冗余缓冲，严禁未挂载或空间不足时写入；
- 恢复 `/etc/config/dockerd` 与 `/etc/docker/daemon.json` 配置，自动同步更新 `data_root` 路径；
- **防覆盖安全解压时序**：先释放 Compose 编排目录结构，后解压释放 Bind Mounts 与 Named Volumes，确保冷备持久化数据绝对权威，绝不被 Compose 目录内的旧归档覆盖；
- 启动 dockerd 守护进程并按原有状态恢复开机自启；
- 仅拉起本次升级记录的 Compose 编排项目（严格使用记录的项目名 `-p`、配置文件 `-f` 与 `--env-file`）；
- **参数完备的独立容器重建**：完整支持环境变量 `-e`、端口映射 `-p`、数据卷 `-v`、高级挂载 `--mount`（bind/volume/tmpfs 完整解析）、网络模式 `--net`、重启策略 `--restart`、特权 `--privileged`、运行用户 `-u`、工作目录 `-w`、主机名 `-h`、多段入口点 `--entrypoint` 与跟随参数、设备映射 `--device`、权限控制 `--cap-add`/`--cap-drop`、DNS `--dns` 以及命令与参数，所有参数经单引号安全转义；在无网络脱机环境下通过 `docker load` 自动导入导出的本地镜像；
- 若存在 SQL 备份文件，按需导入对应数据库。

---

## 五、升级后核心功能验收与排错方法

按照 **1. 网络与代理** $\rightarrow$ **2. 软硬件加速** $\rightarrow$ **3. Docker 与防火墙边界** 的严格顺序进行端到端验收。

```bash
# 推荐使用 helper 统一全量验收
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh verify all
```

或手动执行分步验收：

### 1. 网络连通性与 PassWall2 节点平滑继承核验

#### ① 检查继承的旧节点配置结构
```bash
# 检查旧节点数据结构、加密类型与协议
uci show passwall2 | grep -E "\.type=|\.protocol=|\.address=|\.port="
```

#### ② 最小平滑迁移策略（若核心升级导致旧节点不兼容时）
如果发现旧节点无法读取或核心报错，按以下最小迁移原则在 Web 界面重新录入：
- **提取并保留关键要素**：服务器域名/IP（`address`）、服务端口（`port`）、用户凭据（`uuid` / `password`）、传输协议（`transport`：如 ws/grpc/tcp）、TLS 参数（`tls` / `sni` / `alpn` / `fingerprint`）；
- **选择现代化核心**：在新版界面中首选 `sing-box` 或 `Xray`，以相同凭据新建同类节点，保留原分流语义。

#### ③ 核心配置文件语法与进程审查
```bash
# 确认核心进程处于运行状态
pgrep -x sing-box || pgrep -x xray

# 动态反查运行中核心进程的真实命令行参数与配置文件位置（解析 /proc/<pid>/cmdline 与 ps -w）
CORE_PIDS=$(pgrep -x sing-box || true; pgrep -x xray || true)
for pid in $CORE_PIDS; do
    [ -n "$pid" ] || continue
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || ps -w 2>/dev/null | grep "^[ ]*$pid " || true)
    echo "进程 PID $pid 命令行: $cmdline"
done

# 递归检查生成的 JSON 客户端配置语法（覆盖 /var/etc/passwall2 及其 ACL/ 等所有子目录）
find /var/etc/passwall2 -type f -name "*.json" 2>/dev/null | while read -r cfg; do
    [ -f "$cfg" ] || continue
    if command -v jq >/dev/null 2>&1; then
        jq empty "$cfg" && echo "配置语法验证通过: $cfg"
    fi
done
```

#### ④ 真实代理网络与 TLS 握手鉴权核验
> [!CAUTION]
> **真实性警告**：单纯的 TCP Ping 或 HTTP 延时测试**绝不能证明** TLS 握手、用户认证与节点流量解密成功！Ping 仅能证明网络路由可达，握手失败时依然可能显示低延迟！

必须通过指定本地 SOCKS 端口进行带 TLS 握手的 HTTPS 深度请求与出口 IP 核验：
```bash
# 1. 自动定位活动核心的实际本地 SOCKS 监听端口（先查运行进程 cmdline，再查 JSON 的 inbounds 节区，包含 ACL/ 子目录，杜绝截取 outbounds 远程端口或盲猜 1080）
SOCKS_PORT=""
find /var/etc/passwall2 -type f -name "*.json" 2>/dev/null | while read -r cfg; do
    [ -f "$cfg" ] || continue
    if command -v jq >/dev/null 2>&1; then
        SOCKS_PORT=$(jq -r '.inbounds[]? | select((.protocol? == "socks") or (.type? == "socks") or ((.tag? // "") | test("socks"; "i"))) | (.listen_port // .port // empty)' "$cfg" 2>/dev/null | head -n 1)
    fi
    if [ -z "$SOCKS_PORT" ]; then
        SOCKS_PORT=$(sed -n '/"inbounds"/,/"outbounds"/p' "$cfg" | grep -oE '"(listen_port|port)": *[0-9]+' | head -n 1 | awk '{print $2}')
    fi
    [ -n "$SOCKS_PORT" ] && echo "$SOCKS_PORT" && break
done
echo "PassWall2 活动核心 SOCKS 本地监听端口: $SOCKS_PORT"

# 2. 发起真实 TLS 握手深度请求
curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s -I https://www.google.com

# 3. 核验当前代理公网出口 IP（必须与代理节点出口一致）
curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s https://api.ipify.org && echo ""

# 4. 验证国内直连分流是否穿透正常（直连百度）
curl -m 5 -s -I https://www.baidu.com

# 5. 检查核心日志，确认无 TLS Handshake Failed 或 Invalid User 报错
logread -e passwall2 | tail -n 25
```

---

### 2. 软硬件加速与 PPE Flowtable 硬件卸载核对

> [!WARNING]
> 单纯在 nftables 中存在 `flowtable` 仅代表开启了**软件流表卸载**；Qualcomm PPE 硬件加速必须确认 flowtable 规则中包含 `flags offload;` 或 `flags = { hw_offload }` 硬件标志，且内核驱动未出现 probe failed。

```bash
# 1. 验证内核 Flowtable 流表是否包含硬件卸载标志 flags offload; 或 hw_offload
nft list ruleset | grep -qE "flags[[:space:]]+offload;|flags[[:space:]]*=[[:space:]]*\{[[:space:]]*hw_offload[[:space:]]*\}|hw_offload" && echo "PPE 硬件卸载标志: 已生效" || echo "警告: 仅为软件 Flowtable，缺少 hw_offload/flags offload; 硬件标志"

# 2. 检查内核日志是否存在 PPE 驱动初始化或探测失败
dmesg | grep -qiE "(ppe|flowtable|qcom-ppe).*(fail|error|disabled)" && echo "警告: PPE 驱动探测或初始化存在报错！" || echo "PPE 驱动就绪: 无报错"
```

---

### 3. Docker 防火墙后端与网络链路端到端验收

#### ① 识别实际防火墙后端与链检查
> [!WARNING]
> OpenWrt 上的 Docker 守护进程通常通过 `iptables-nft` 兼容层与 Linux 内核交互。**绝对不能硬编码 `nft list chain inet fw4 DOCKER` 作为唯一判断依据**！

```bash
# 1. 识别当前防火墙后端类型
if command -v iptables >/dev/null 2>&1; then
    iptables -V
    echo "=== 检查 iptables filter 表与 nat 表中的 DOCKER 链 ==="
    iptables -t filter -n -L DOCKER 2>/dev/null | head -10 || true
    iptables -t nat -n -L DOCKER 2>/dev/null | head -10 || true
fi

if command -v nft >/dev/null 2>&1; then
    echo "=== 检查 nftables 相关规则集 ==="
    nft list ruleset 2>/dev/null | grep -i "chain docker" || true
fi
```

#### ② 容器端到端网络验收（出网、端口映射与 WAN 边界防护）
```bash
# 1. 验证容器出网能力 (Egress)
docker run --rm alpine sh -c "wget -q -T 5 -O - http://connectivitycheck.gstatic.com/generate_204 || wget -q -T 5 -O - http://www.baidu.com" >/dev/null
echo "容器出网能力: 正常"

# 2. 验证 LAN 侧端口映射与 NAT 回流 (Ingress / Loopback)
CID=$(docker run -d -p 127.0.0.1:18888:80 alpine sh -c "echo -e 'HTTP/1.1 200 OK\r\n\r\nPORT_OK' | nc -l -p 80")
sleep 1
RESP=$(curl -m 3 -s http://127.0.0.1:18888 || true)
docker rm -f "$CID" >/dev/null 2>&1 || true
if echo "$RESP" | grep -q "PORT_OK"; then
    echo "LAN 访问容器映射端口: 正常"
else
    echo "ERROR: 端口映射与 NAT 回流异常！" >&2
    exit 1
fi

# 3. 验证 WAN 边界阻断策略 (WAN Ingress Block)
# 确认防火墙 FORWARD 默认策略为 DROP/REJECT，外部未授权流量无法绕过路由器直接攻击容器端口
iptables -S FORWARD 2>/dev/null | head -n 3
```

若上述各项指标均通过，则京东云 AX6600 雅典娜保留配置升级与 Docker 恢复全部验收完毕！
