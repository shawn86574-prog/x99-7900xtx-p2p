# PCIe P2P between two RX 7900 XTX on an X99 / Broadwell-EP workstation

Force peer-to-peer access between two Radeon RX 7900 XTX cards on a platform AMD never
whitelisted, without patching the kernel or rebuilding `amdgpu`: a ~50-line kretprobe module
plus one fake topology XML. Measured RCCL busbw goes from **3.96–4.14 GB/s (SHM) to
5.03 GB/s (P2P/IPC)**, and a 1920×1088 / 124-frame / 4-step video pipeline drops from
88.91 s to 85.00 s per step.

## Motivation

An X99 board (`8086:6f00`) is not in the kernel's `pci_p2pdma_whitelist`, so
`pci_p2pdma_distance_many()` returns a negative distance. amdgpu reads exactly that one
return value: peer access is marked unreachable, the dma-buf falls back to system memory,
and every cross-card copy silently becomes host staging. Two gates stand in the way, and
both are software gates:

| # | Gate | Symptom | Fix |
|---|---|---|---|
| 1 | `pci_p2pdma` chipset whitelist | `hipDeviceCanAccessPeer` = 0/0, `PCIe P2P access is not supported by the chipset` in dmesg | kretprobe on `pci_p2pdma_distance_many`, force a positive return for AMD peers |
| 2 | RCCL path policy | kernel P2P works, but RCCL still logs `via SHM/direct/direct` | `NCCL_TOPO_FILE` with a faked PXB layout |

RCCL 2.27.7 hard-codes `p2pLevel = PATH_PXB` on Intel x86 (`ncclTopoCheckP2p()`). These two
cards sit under two different root ports, so the computed path type is PHB(8), i.e. "farther
than PXB(5)" → no direct path. Setting `NCCL_P2P_LEVEL=PHB` or `SYS` does nothing: the user
value is overwritten later by that Intel rule.

## The three layers

| Layer | Component | What it actually does |
|---|---|---|
| Kernel | [`kernel/p2p_force.c`](kernel/p2p_force.c) | kretprobe, return handler on `pci_p2pdma_distance_many`; entry handler checks `provider->vendor == PCI_VENDOR_ID_ATI`, so only AMD peers get a faked distance and `xe` / `habanalabs` / `nvmet` keep the real value |
| Topology | [`topo/fake_topo_p2p.xml`](topo/fake_topo_p2p.xml) | puts both GPUs under one virtual bridge so RCCL classifies the path as PXB instead of PHB — process-local, no hardware change |
| Runtime env | [`scripts/p2p-env.sh`](scripts/p2p-env.sh) | exports `NCCL_TOPO_FILE`, `NCCL_P2P_DISABLE=0`, `NCCL_P2P_LEVEL=PXB`, `NCCL_DEBUG_SUBSYS=INIT` |

Each layer is independent: kernel on + topology off still yields SHM; topology on + kernel
off makes RCCL try P2P and fail. Either can be rolled back alone.

## Hardware

| Item | Value |
|---|---|
| CPU | Intel Xeon E5-2696 v4 @ 2.20 GHz (Broadwell-EP, 1 socket, 22 logical cores, HT off) |
| Chipset | X99 / C610, host bridge `8086:6f00` |
| RAM | 128 GB DDR4 ECC |
| Compute GPUs | 2 × Radeon RX 7900 XTX 24 GB, `1002:744c`, gfx1100, at `05:00.0` / `08:00.0` |
| Display GPU | GeForce GTX 750 Ti, `10de:1380` |
| GPU link | Gen4 x16 per card (`16.0 GT/s x16`) |
| Upstream link | Gen3 x8 (`8.0 GT/s x8`), theoretical 7.88 GB/s one-way — the ceiling for everything below |
| Switches | AMD Navi 10 XL, `1002:1478` / `1479`, at `03:00.0` / `04:00.0` and `06:00.0` / `07:00.0` |
| IOMMU | VT-d **translated**, not passthrough (required: the VRAM BAR sits at ~61.6 TiB, above the 44-bit DMA mask) |
| Kernel / userspace | `7.0.0-38-generic`, ROCm 7.2.0, RCCL 2.27.7 |

## Requirements and compatibility

All of these are hard prerequisites. `scripts/p2p-preflight.sh` checks every one of them;
`--env-only` runs just the checks without the probe.

| # | Requirement | How to check | If it fails |
|---|---|---|---|
| 1 | `amdgpu` is a **module**, not built into the kernel | `modinfo -n amdgpu` must not print `(builtin)` | built-in amdgpu probes before the hook loads, so peer access is already decided; a modular kernel is required |
| 2 | Kernel exports `pci_p2pdma_distance_many` and has `CONFIG_KRETPROBES` / `CONFIG_PCI_P2PDMA` | `grep -qw pci_p2pdma_distance_many /proc/kallsyms`; `grep -E '^CONFIG_(KRETPROBES\|PCI_P2PDMA)=y' /boot/config-$(uname -r)` | module cannot build or attach |
| 3 | Secure Boot off (or module signed + MOK-enrolled) | `mokutil --sb-state` | unsigned module refused |
| 4 | IOMMU in **translated** mode (the default; not `iommu=off`, not `iommu=pt`) | each GPU has `/sys/bus/pci/devices/<bdf>/iommu_group`; `cat /proc/cmdline` | the VRAM BAR sits above the 44-bit DMA mask; mappings fail without translation |
| 5 | Two AMD GPUs sharing one gfx target | KFD `simd_count`, `gfx_target_version`, `location_id` | cross-architecture peer access is not supported |
| 6 | Topology XML matches this machine's GPU BDFs | preflight compares `class="0x030000"` entries against KFD | RCCL never finds the cards; regenerate with `scripts/gen-topo.sh` |
| 7 | RCCL **2.27.x** on Intel x86 | `python -c "import torch;print(torch.cuda.nccl.version())"` | the `PATH_PXB` hardcode this repo works around may be fixed or changed in other releases |
| 8 | Kernel / distro in the tested range | `uname -r` | tested on `7.0.0-38-generic` with Ubuntu headers only |

Verified fingerprint of this machine: `7.0.0-38-generic`, `CONFIG_KRETPROBES=y`,
torch `2.13.0+rocm7.2`, RCCL `2.27.7`, two `1002:744c` at `05:00.0` / `08:00.0`,
both inside IOMMU groups.

### What reproduces, and what does not

| Item | Reproducible by a third party? |
|---|---|
| `canAccessPeer` both ways, `isAllDirectP2p 1`, `via P2P/IPC` | **Yes**, on hardware/kernel/RCCL that satisfies the table above |
| ~5.0 GB/s RCCL 16 MB allreduce, ~5.15 GB/s one-way peer copy | **Yes**, same conditions; absolute numbers depend on link width |
| The video-pipeline speedup (85.00 s vs 88.91 s per step) | **No** — the private benchmark is not in this repo |
| 4 h soak, kernel-upgrade, GPU-reset, IOMMU-off/ACS, 3-card variants | **No** — not completed here either; see `docs/test-results.md` §8 |
| Bit-identical outputs across runs | **No** — the pipeline is non-deterministic across runs; only cross-rank latent equality is meaningful |

## Quick start

```bash
git clone https://github.com/shawn86574-prog/x99-7900xtx-p2p.git && cd x99-7900xtx-p2p
bash scripts/gen-topo.sh                       # regenerate topo from this machine's KFD/BDF
sudo bash kernel/install-p2p-kernel.sh --dkms  # build + DKMS + softdep + install topology
sudo reboot                                    # amdgpu must re-probe with the hook in place
bash scripts/p2p-preflight.sh                  # env gates, then isAllDirectP2p 1 / via P2P/IPC
source scripts/p2p-env.sh && <your torchrun job>  # one process per GPU
```

`install-p2p-kernel.sh` refuses to run if the kernel headers are missing, if
`pci_p2pdma_distance_many` is not exported, or if Secure Boot is enabled.

## Verification

`scripts/p2p-preflight.sh` runs a two-process 16 MB allreduce probe and exits non-zero unless
both of these appear in the RCCL log:

```
isAllDirectP2p 1
via P2P/IPC
```

It also asserts `canAccessPeer 0->1=True 1->0=True`. If either check fails the script
refuses to let a long job run on SHM. Scale-only checks for the kernel side:

| Check | Expected |
|---|---|
| `lsmod \| grep p2p_force` | loaded, listed before `amdgpu` |
| `dmesg \| grep p2p_force` | `已在 pci_p2pdma_distance_many 上挂钩` |
| `/sys/class/kfd/kfd/topology/nodes/*/properties` | `p2p_links_count = 1`, `max_bandwidth = 8000` |

## Results

| Metric | SHM baseline | P2P/IPC | Change |
|---|---|---|---|
| RCCL 16 MB allreduce busbw | 3.96–4.14 GB/s | **5.03 GB/s** | +21% ~ +27% |
| Peer copy ceiling (one-way) | — | 5.15 GB/s | reference only, not a collective target |
| Video pipeline, per step (1920×1088, 124 frames, 4 steps) | 88.91 s | **85.00 s** | −4.4% |
| Communication per step (81.63 GB allreduce payload) | 19.7 s | **16.2 s** | −3.5 s |
| Soak, per step (3 rounds) | — | 85.88 / 85.99 / 85.97 s | — |
| Soak, end to end | — | 857.7 / 856.6 / 860.6 s | — |
| Soak, peak temperature / dual-card power | — | 91.0 °C / 742 W | — |
| Soak, AER correctable delta / fatal | — | **0 / 0** | — |
| Soak, cross-rank latent `max\|diff\|` | — | **0.0** (all 3 rounds) | — |

The gap between +21–27% at the RCCL level and −4.4% end to end is expected: at 81.63 GB per
step over ~85 s, communication is still the minority of the runtime. Full numbers, including
what was **not** tested, are in [`docs/test-results.md`](docs/test-results.md).

## Caveats

- **Kernel upgrades.** The module is out-of-tree and compiled against the running kernel's
  headers. Use `--dkms` (the install script registers `p2p-force/1.0`), otherwise re-run it
  after every `linux-image-*` update. Never copy a prebuilt `.ko` across kernel versions.
- **Secure Boot.** Must be off, or the module has to be signed and enrolled via MOK. The
  installer checks `mokutil --sb-state` and aborts if it is enabled.
- **GPU BDF changes.** The shipped XML pins `05:00.0` / `08:00.0`. Run
  `bash scripts/gen-topo.sh` to regenerate it from KFD (BDF, device id and gfx target all
  read from this machine), then reinstall or copy it to `/etc/p2p/topo-pxb.xml`. `preflight`
  fails loudly when the XML and the hardware disagree.
- **The topology is a fiction.** It does not change hardware, it changes RCCL's path
  classification. Verify correctness with a **cross-rank latent** comparison, not with an
  output-file md5: the pipeline is non-deterministic across runs (cross-run latent
  `max|diff| = 4.116` in our own measurements), so equal md5s are a coincidence and unequal
  md5s prove nothing.
- **Bandwidth expectations.** This platform is Gen3 x8. 5.23 GB/s one-way write is ~66% link
  efficiency; do not use the 27–29 GB/s published for Gen5 x8 hardware as a pass mark.
- **One process per GPU.** A single process initializing both cards hits
  `invalid device context (201)` on cross-card IPC import. Always `--nproc_per_node=2`
  (or one process per visible card).

## Rollback

```bash
sudo dkms remove p2p-force/1.0 --all
sudo rm -f /etc/modprobe.d/99-p2p-force.conf /etc/profile.d/p2p-rccl.sh /etc/p2p/topo-pxb.xml
sudo reboot
```

`rmmod p2p_force` alone is **not** enough: amdgpu already made its peer-access decision at
probe time, so a reboot is the only clean revert. RCCL needs nothing at all — unset
`NCCL_TOPO_FILE` and the next process is back on SHM.

## Disclaimer

This is an unsupported configuration. The out-of-tree module taints the kernel
(`tainted = 12289` / `0x3001` on this machine: proprietary NVIDIA + out-of-tree + unsigned),
kernel crashes are therefore not reportable upstream. Forcing a faked p2pdma distance can,
in principle, make a driver DMA into an unreachable BAR; the AMD-vendor filter in
`p2p_force.c` narrows that to AMD peers only. Run it on your own machine, keep the rollback
commands handy, and do not deploy it where silent data corruption is unacceptable.

## Documentation

- [`docs/report.md`](docs/report.md) — the full reproduction log, including the 18 failed
  attempts and the parameter table (Chinese).
- [`docs/stability-testplan.md`](docs/stability-testplan.md) — risk register, operating
  matrix, rollback levels, monitoring points (Chinese).
- [`docs/test-results.md`](docs/test-results.md) — measured numbers and the corrected
  acceptance criteria (Chinese).

## License

MIT — see [LICENSE](LICENSE).
