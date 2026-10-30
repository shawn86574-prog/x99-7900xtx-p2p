#!/usr/bin/env bash
# 安装并固化 p2p_force：
#   sudo bash install-p2p-kernel.sh          # 直接装入当前内核
#   sudo bash install-p2p-kernel.sh --dkms   # 注册 DKMS，随内核升级自动重编
# 作用：让 amdgpu 在 probe 时把对端 GPU 视为可达，peer BAR 映射才会建立。
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0 [--dkms]" >&2
  exit 1
fi

MODE="direct"
case "${1:-}" in
  --dkms) MODE="dkms" ;;
  "") ;;
  *) echo "未知参数：$1（只支持 --dkms）" >&2; exit 1 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
PKG="p2p-force"
VER="1.0"
MOD="p2p_force"

say() { printf '[%s] %s\n' "$1" "$2"; }
die() { echo "[FAIL] $*" >&2; exit 1; }

[[ -d "/lib/modules/${KVER}/build" ]] || die "缺少内核头文件：sudo apt install linux-headers-${KVER}"
grep -qw pci_p2pdma_distance_many /proc/kallsyms || die "当前内核没有 pci_p2pdma_distance_many，kretprobe 无法挂钩"
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  die "Secure Boot 已开启；p2p_force 未签名，请先关闭 Secure Boot，或签模块并注册 MOK"
fi
amod="$(modinfo -n amdgpu 2>/dev/null || true)"
case "${amod}" in
  *"(builtin)"*) die "amdgpu 被编译进内核：钩子挂不上 probe 阶段，必须换模块化内核" ;;
esac

# 仓库自带拓扑只对应 05:00.0 / 08:00.0；其他机器先重新生成
real_bdfs="$(lspci -D -d 1002: 2>/dev/null | awk '/VGA|Display|3D/{print $1}' | sort)"
topo_bdfs="$(awk '/class="0x030000"/{ if (match($0,/busid="[^"]*"/)) print substr($0,RSTART+7,RLENGTH-8) }' "${DIR}/../topo/fake_topo_p2p.xml" | sort)"
if [[ -z "${real_bdfs}" ]]; then
  echo "[WARN] lspci 未找到 AMD 显示设备；稍后 preflight 会再校验"
elif [[ "${topo_bdfs}" != "${real_bdfs}" ]]; then
  echo "[WARN] 仓库拓扑与本机 GPU 地址不一致"
  echo "       实机：$(echo ${real_bdfs})"
  echo "       拓扑：$(echo ${topo_bdfs})"
  echo "       先执行：bash ${DIR}/../scripts/gen-topo.sh，再重跑本脚本"
fi

say 1 "编译 ${MOD}.ko"
make -C "/lib/modules/${KVER}/build" M="${DIR}" modules

if [[ "${MODE}" == "dkms" ]]; then
  command -v dkms >/dev/null 2>&1 || die "未安装 dkms：sudo apt install dkms"
  say 2 "注册 DKMS ${PKG}/${VER}"
  rm -rf "/usr/src/${PKG}-${VER}"
  install -d "/usr/src/${PKG}-${VER}"
  install -m 0644 "${DIR}/${MOD}.c" "${DIR}/Makefile" "/usr/src/${PKG}-${VER}/"
  cat > "/usr/src/${PKG}-${VER}/dkms.conf" <<'EOF'
PACKAGE_NAME="p2p-force"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="p2p_force"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
EOF
  if dkms status -m "${PKG}" -v "${VER}" 2>/dev/null | grep -q .; then
    dkms remove -m "${PKG}" -v "${VER}" --all
  fi
  dkms add -m "${PKG}" -v "${VER}"
  dkms build -m "${PKG}" -v "${VER}"
  dkms install -m "${PKG}" -v "${VER}" --force
  # 清掉早期直接安装的旧 ko，避免 updates/ 与 extra/ 同时存在两份不同版本
  rm -f "/lib/modules/${KVER}/extra/${MOD}.ko"
else
  say 2 "安装到 /lib/modules/${KVER}/extra"
  install -d "/lib/modules/${KVER}/extra"
  install -m 0644 "${DIR}/${MOD}.ko" "/lib/modules/${KVER}/extra/${MOD}.ko"
fi

say 3 "固化 amdgpu 加载顺序"
rm -f /etc/modprobe.d/p2p-force.conf   # 清掉早期手工安装留下的同名旧配置，避免重复 softdep
cat > /etc/modprobe.d/99-p2p-force.conf <<'EOF'
# p2p_force 必须先于 amdgpu 加载；否则 amdgpu probe 时看不到 peer 距离
softdep amdgpu pre: p2p_force
EOF

if [[ -f /etc/initramfs-tools/modules ]]; then
  grep -qxF "${MOD}" /etc/initramfs-tools/modules || echo "${MOD}" >> /etc/initramfs-tools/modules
fi

say 4 "固化伪造拓扑到 /etc/p2p"
install -d /etc/p2p
install -m 0644 "${DIR}/../topo/fake_topo_p2p.xml" /etc/p2p/topo-pxb.xml
echo "       /etc/p2p/topo-pxb.xml 已就位（来自仓库拓扑；GPU BDF 变化请先跑 scripts/gen-topo.sh）"

say 5 "固化 RCCL 环境到 /etc/profile.d"
cat > /etc/profile.d/p2p-rccl.sh <<'EOF'
# P2P 优先：默认读伪造 PXB 拓扑，让 RCCL 选 P2P/IPC 而不是 SHM
# 需要跑 SHM 基线时在同一个 shell 里 unset NCCL_TOPO_FILE 即可
if [ -f /etc/p2p/topo-pxb.xml ]; then
  export NCCL_TOPO_FILE="${NCCL_TOPO_FILE:-/etc/p2p/topo-pxb.xml}"
fi
export NCCL_P2P_DISABLE=0
export NCCL_P2P_LEVEL=PXB
EOF
chmod 0644 /etc/profile.d/p2p-rccl.sh

say 6 "安装开机自检"
cat > /usr/local/sbin/p2p-bootcheck.sh <<'EOF'
#!/usr/bin/env bash
# P2P 开机自检：模块是否加载、KFD 是否看到 2 条 p2p 链路、拓扑文件是否就位
log() { echo "$(date '+%F %T') $*"; }
ok=1
lsmod | grep -q '^p2p_force' || { log "[FAIL] p2p_force 未加载"; ok=0; }
links=$(cat /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null |
        awk '/p2p_links_count/{s+=$2} END{printf "%d", s+0}')
[ "${links:-0}" -ge 2 ] || { log "[FAIL] KFD p2p 链路数=${links:-0}（期望 >=2）"; ok=0; }
[ -f /etc/p2p/topo-pxb.xml ] || { log "[FAIL] 缺少 /etc/p2p/topo-pxb.xml"; ok=0; }
[ "$ok" = 1 ] && log "[OK] P2P 就绪，KFD 链路 ${links}"
exit $((1 - ok))
EOF
chmod 0755 /usr/local/sbin/p2p-bootcheck.sh
cat > /etc/systemd/system/p2p-bootcheck.service <<'EOF'
[Unit]
Description=P2P 开机自检（模块 / KFD 链路 / 拓扑）
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/p2p-bootcheck.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable p2p-bootcheck.service >/dev/null 2>&1 || echo "[WARN] 启用 p2p-bootcheck.service 失败"

say 7 "更新模块依赖与 initramfs"
depmod -a "${KVER}"
if command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -u -k "${KVER}"
fi

say 8 "立即加载 ${MOD}（只影响后续调用；已 probe 的 amdgpu 必须重启）"
modprobe "${MOD}" 2>/dev/null || echo "[WARN] modprobe 未成功，重启后再看 dmesg"
if lsmod | grep -q '^amdgpu'; then
  echo "[WARN] amdgpu 已在运行；必须重启，新的 amdgpu 才会按 P2P 路径 probe"
fi

say 9 "校验"
if dmesg | grep -q "p2p_force:.*挂钩"; then
  echo "[OK] kretprobe 已注册"
else
  echo "[WARN] dmesg 暂未看到 hooked 记录；重启后执行 journalctl -k -b | grep p2p_force"
fi

echo
echo "安装完成。固化产物："
if [[ "${MODE}" == "dkms" ]]; then
  echo "  模块     /lib/modules/${KVER}/updates/dkms/${MOD}.ko（DKMS 管理） + /etc/modprobe.d/99-p2p-force.conf"
else
  echo "  模块     /lib/modules/${KVER}/extra/${MOD}.ko + /etc/modprobe.d/99-p2p-force.conf"
fi
echo "  拓扑     /etc/p2p/topo-pxb.xml"
echo "  环境     /etc/profile.d/p2p-rccl.sh（登录 shell 生效；systemd 服务需在 unit 里自行 Environment=）"
echo "  自检     /usr/local/sbin/p2p-bootcheck.sh + p2p-bootcheck.service"
echo
echo "重启后验证："
echo "  sudo reboot"
echo "  bash ${DIR}/../scripts/p2p-preflight.sh"
echo "  systemctl status p2p-bootcheck.service --no-pager"
echo
if [[ "${MODE}" == "dkms" ]]; then
  echo "DKMS 状态："
  dkms status -m "${PKG}" -v "${VER}"
  echo "回滚：sudo dkms remove ${PKG}/${VER} --all"
else
  echo "回滚：sudo rm -f /lib/modules/${KVER}/extra/${MOD}.ko"
fi
echo "      sudo rm -f /etc/modprobe.d/99-p2p-force.conf /etc/profile.d/p2p-rccl.sh /etc/p2p/topo-pxb.xml \\"
echo "              /usr/local/sbin/p2p-bootcheck.sh /etc/systemd/system/p2p-bootcheck.service"
echo "      sudo systemctl disable p2p-bootcheck.service; sudo depmod -a; sudo reboot"