#!/usr/bin/env bash
# 从本机 KFD 真实拓扑生成 RCCL 伪造 PXB 拓扑：
#   BDF、device id、gfx 架构全部取自 /sys/class/kfd，不依赖手改。
# 用法：bash scripts/gen-topo.sh [输出路径]
# 默认写 topo/fake_topo_p2p.xml（安装脚本会把同一份文件装到 /etc/p2p/topo-pxb.xml）。
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${DIR}/../topo/fake_topo_p2p.xml}"
KFD=/sys/class/kfd/kfd/topology/nodes

fail() { echo "[FAIL] $*" >&2; exit 1; }

[[ -d "${KFD}" ]] || fail "找不到 ${KFD}；需要先加载 amdgpu 并确认 /dev/kfd 存在"

rows=""
for d in "${KFD}"/*; do
  simd=$(awk '/^simd_count/{print $2}' "$d/properties" 2>/dev/null || true)
  [[ "${simd:-0}" -gt 0 ]] || continue
  loc=$(awk '/^location_id/{print $2}' "$d/properties")
  did=$(awk '/^device_id/{print $2}' "$d/properties")
  gfxv=$(awk '/^gfx_target_version/{print $2}' "$d/properties")
  [[ -n "${loc}" && -n "${did}" && -n "${gfxv}" ]] || continue

  # location_id = ((domain & 0xffff) << 32) | (bus << 8) | devfn
  bus=$(( (loc >> 8) & 0xff ))
  devfn=$(( loc & 0xff ))
  devn=$(( devfn >> 3 ))
  fn=$(( devfn & 7 ))
  bdf=$(printf '0000:%02x:%02x.%d' "${bus}" "${devn}" "${fn}")
  # device_id 是十进制，XML 里写十六进制
  hexid=$(printf '0x%04x' "${did}")
  # gfx_target_version 110000 -> gfx1100（major*10000 + minor*100 + step）
  gfx="gfx$(( gfxv / 10000 ))$(( (gfxv / 100) % 100 ))$(( gfxv % 100 ))"
  rows+="${bus} ${bdf} ${hexid} ${gfx}"$'\n'
done

[[ -n "${rows}" ]] || fail "KFD 里没有 GPU 节点；先确认 amdgpu 正常加载"

count=$(printf '%s' "${rows}" | grep -c . || true)
[[ "${count}" -ge 2 ]] || fail "只检测到 ${count} 张 AMD GPU；本方案至少需要 2 张"
[[ "${count}" -eq 2 ]] || echo "[WARN] 检测到 ${count} 张 GPU；伪造拓扑按两卡设计，多于两张请自行核对 rank/路径" >&2

# lscpu 字段仅用于让 XML 形似真实输出，路径判定不依赖 family/model
fam=$(lscpu | awk -F: '/^CPU family/{gsub(/ /,"",$2); print $2}' 2>/dev/null || true)
model=$(lscpu | awk -F: '/^Model:/{gsub(/ /,"",$2); print $2}' 2>/dev/null || true)
vendor=$(lscpu | awk -F: '/^Vendor ID/{gsub(/^ +| +$/,"",$2); print $2}' 2>/dev/null || true)
arch=$(uname -m)
nproc_n=$(nproc)
if [[ "${nproc_n}" -gt 63 ]]; then
  affinity="ffffffffffffffff"
else
  affinity=$(printf '%x' $(( (1 << nproc_n) - 1 )))
fi

# 伪造桥沿用第一张卡的真实上游桥地址；两张卡仍然被“挪”到同一个 PXB 下
first_bdf=$(printf '%s' "${rows}" | sort -n -k1,1 | awk 'NR==1{print $2}')
bridge=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${first_bdf}")")" 2>/dev/null || true)
[[ "${bridge}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || bridge="0000:ff:00.0"

{
  echo '<system version="2">'
  echo "  <cpu host_hash=\"0xdeadbeef\" numaid=\"0\" affinity=\"${affinity}\" arch=\"${arch}\" vendor=\"${vendor:-GenuineIntel}\" familyid=\"${fam:-6}\" modelid=\"${model:-79}\">"
  # 伪造一个上游桥，把两张卡挂到同一个 PXB 下；class 0x060400 = PCI bridge
  echo '    <pci busid="'"${bridge}"'" class="0x060400" vendor="0x1002" device="0x1479" link_speed="16.0 GT/s PCIe" link_width="16">'
  rank=0
  while read -r _bus bdf hexid gfx; do
    echo "      <pci busid=\"${bdf}\" class=\"0x030000\" vendor=\"0x1002\" device=\"${hexid}\" link_speed=\"16.0 GT/s PCIe\" link_width=\"16\">"
    echo "        <gpu dev=\"${rank}\" sm=\"48\" gcn=\"${gfx}\" arch=\"38911\" rank=\"${rank}\" gdr=\"0\"/>"
    echo '      </pci>'
    rank=$((rank + 1))
  done < <(printf '%s' "${rows}" | sort -n -k1,1)
  echo '    </pci>'
  echo '  </cpu>'
  echo '</system>'
} > "${OUT}"

echo "[OK] 已生成 ${OUT}"
printf '%s' "${rows}" | sort -n -k1,1 | awk '{printf "     %-14s %-6s %s\n", $2, $3, $4}'
echo "     下一步：sudo bash kernel/install-p2p-kernel.sh --dkms（会把这份文件装到 /etc/p2p/topo-pxb.xml）"
