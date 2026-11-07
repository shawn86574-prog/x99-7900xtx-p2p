# gfx1100 魔改 SGLang：安装踩坑与实测

来源：`StevenChenSE/sglang@gfx1100-support`（commit `f84475c`，2026-09-11）。对应原帖 lcz.me/topic/2132。

## 一、实测结果（qwen38-27b / 27B-AWQ-INT4 / TP=2 / P2P 生效）

同一台机器、同一模型、同一压测脚本（`scripts/bench-sglang-concurrency.py`，max_tokens=256，每级 ×4 轮）：

| 并发 | 官方 0.5.10 | gfx1100 魔改 | 变化 |
|---|---|---|---|
| 1 | 17.7 tok/s | 28.2 tok/s | +59.3% |
| 2 | 33.8 tok/s | 77.1 tok/s | **+128.1%** |
| 4 | 61.3 tok/s | 147.1 tok/s | **+139.9%** |
| 8 | 106.5 tok/s | 151.6 tok/s | +42.3% |

端到端延迟（P50）与 TTFT：

| 并发 | 延迟 官方 → 魔改 | TTFT 官方 → 魔改 |
|---|---|---|
| 4 | 16.6 s → 7.0 s（**−57.8%**） | 2063 ms → 534 ms（**−74.1%**） |
| 8 | 19.2 s → 13.4 s（**−30.2%**） | 4070 ms → 6982 ms（+71.5%） |

8 并发全部 32/32 成功，GPU 99.1% / 98.4%。

### 为什么 8 并发只涨 42%

日志明确：

```
max_running_requests is capped to 4 by the mamba state cache
(max_mamba_cache_size=24, 5 state slots per request)
```

Qwen3.5 是混合线性注意力架构，每个请求要占 5 个 mamba state slot。24 ÷ 5 = 4，所以即使传 `--max-running-requests 8` 也被压到 4，8 条流实际按 4 并发排队。

要提高需加大 `--max-mamba-cache-size`（每 slot ssm_state ≈ 73 MB，翻倍到 48 约多占 1.8 GB）。当前剩余显存 3.69 GB，可试 40。

### 冷启动

首次请求会触发 WARM-L2 autotune，第一条可能慢到 4 s 以上（conc=1 那组的 TTFT P95 14.5 s 就是这个）。**正式测前先跑 2-3 条 warmup**，否则单并发数据不可信。

## 二、安装步骤与我踩的坑

### 正确步骤

```bash
git clone --depth 1 -b gfx1100-support https://github.com/StevenChenSE/sglang.git
cd sglang/python/sglang/kernels/aot
PYTORCH_ROCM_ARCH=gfx1100 python setup_rocm.py build_ext --inplace   # 约 50 分钟
cp build/lib.*/sgl_kernel/common_ops*.so $VIRTUAL_ENV/lib/python3.12/site-packages/sgl_kernel/
cd ../.. && pip install --no-build-isolation --no-deps -e .
```

### 坑 1：依赖版本全线不匹配

| 报错 | 根因 | 修法 |
|---|---|---|
| `cannot import name 'AnyTokensFormat'` | xgrammar 0.1.32 | `pip install xgrammar==0.2.1` |
| `No module named 'transformers.image_processing_backends'` | transformers 5.3.0 | `pip install transformers==5.12.1` |
| `Could not load this library: libtorchaudio.so` | torchaudio 2.9.1(rocm6.4) 与 torch 2.13(rocm7.2) ABI 不匹配 | 见坑 2 |
| `cannot import name 'gptq_gemm' from 'sgl_kernel'` | sglang-kernel 0.4.1 | `pip install sglang-kernel==0.4.6.post1` |

魔改版 pin 的是 `xgrammar==0.2.1`、`transformers==5.12.1`、`sglang-kernel==0.4.6.post1`、`torchaudio==2.11.0`。

### 坑 2：torchaudio 是坏的，而且一直被掩盖

本机 `torch 2.13.0+rocm7.2` 配 `torchaudio 2.9.1+rocm6.4`，版本根本对不上。之前没暴露只是因为没有任何模块 import 它；transformers 5.12.1 的 import 链把它带进来了。

`download.pytorch.org` 和 PyPI 镜像都拿不到 `torchaudio==2.13.0`。采取的做法是让 torchaudio 降级为纯 Python：

```python
# site-packages/torchaudio/_extension/__init__.py
_IS_TORCHAUDIO_EXT_AVAILABLE = False   # 跳过 libtorchaudio.so 加载
```

文本推理不需要 torchaudio 的 C 扩展。**副作用**：任何真正走音频解码的模型会失败。

### 坑 3：不要手动 mkdir sgl_kernel

`site-packages/sgl_kernel` 原本不存在——它由 `sglang_kernel-0.4.1-py3.12-linux-x86_64.egg`（目录形式）提供。我最初 `mkdir sgl_kernel && touch __init__.py` 把它遮蔽成空目录，导致 `dir(common_ops)` 为空、`torch.ops.sgl_kernel.gptq_shuffle` 不存在。

**正确做法**：先 `pip install sglang-kernel==0.4.6.post1`（它会装出真正的 `sgl_kernel` 目录），再往里覆盖自编的 `common_ops.so`。

### 坑 4：编译进程会静默消失

`setup_rocm.py` 用 `MAX_JOBS=8` 时曾中途退出且无 `.so`（内存压力 + 其他下载争抢）。改成 `MAX_JOBS=4` 后完整跑完，约 50 分钟，19 个 `.o`，产物 `common_ops.cpython-312-x86_64-linux-gnu.so` **26 MB**。

编译目标路径是相对 cwd 的，产物会出现在 `kernels/aot/python/sgl_kernel/` 和 `kernels/aot/build/lib.../sgl_kernel/` 两处，**要用 build/lib 里的那个**。

### 坑 5：后台任务必须 setsid

普通 `nohup ... &` 在本会话中会被回收。用 `setsid nohup ... < /dev/null &`。

## 三、回滚

```bash
pip uninstall sglang -y
pip install sglang==0.5.10.post1
cp -a /home/jay/sglang-backup-20261107-2352/sglang-pkg <site-packages>/sglang
```

备份还包含 `pip_freeze.txt` 与 `sgl_kernel` 目录快照。

## 四、DFlash2 投机解码实测：单流赚，并发亏

模型来源：`z-lab/Qwen3.8-27B-DFlash2`（ModelScope，3670.5 MiB，BF16，81 张量，5 层，`DFlash2DraftModel`）。HF 原仓 `incoai/Qwen3.8-27B-DFlash2` 国内不可达，ModelScope 有同文件副本，直链约 34 MB/s。

启动参数：

```
--speculative-algorithm dflash
--speculative-draft-model-path /mnt/llm/sglang/models/Qwen3.8-27B-DFlash2
--speculative-num-draft-tokens 8
--speculative-draft-window-size 2048
--mem-fraction-static 0.79   # 从 0.83 下调，给 BF16 draft 腾 4 GB
```

| 并发 | 官方 0.5.10 | gfx1100（无 draft） | gfx1100 + DFlash2 |
|---|---|---|---|
| 1 | 17.7 | 28.2 | **49.5（+75.5%）** |
| 2 | 33.8 | 77.1 | — |
| 4 | 61.3 | **147.1** | 109.7（−25.4%） |
| 8 | 106.5 | **151.6** | 108.1（−28.7%） |

**存在明确的并发拐点**：单流 49.5 tok/s 是本机最高，但从 2 流往上 draft 开始拖累。

原因有两条：

1. draft verify 的 CUDA graph 只覆盖 `bs=[1,2,3,4]`，并发超过 4 后走非图路径。
2. draft 本身要占 4 GB 显存和实打实的算力，高并发时与 target 抢 GPU（util 从 96% 降到 95% 但总吞吐腰斩）。

**接受率是另一个约束**：`accept len` 稳定在 2.1–3.1 / 8，即 26%–39%。draft 是按官方 Qwen3.8-27B 训练的，而 target 是 abliterated-AWQ-INT4 微调版，分布有漂移，接受率上不去。原帖能到 193 tok/s 是数学 CoT 场景（结构化、可预测度高），通用短文本达不到。

### 结论：按并发切两档

| 场景 | 配置 | 吞吐 |
|---|---|---|
| 单人交互、Agent 单线推理 | 开 DFlash2 | 49.5 tok/s |
| 多路并发、批量任务 | 关 DFlash2 | 147–152 tok/s |

脚本已支持用 `DFLASH_DRAFT` 控制：指向有效目录即启用，设为空或不存在则自动回退到无 draft 配置。

## 五、还没做的

- `--max-mamba-cache-size` 从 24 提到 40，验证 8 并发能否突破 151 tok/s（当前被 mamba state cache 压到 4 并发）。
- 魔改版的 custom all-reduce（`scripts/rdna_ar/rdna_ar_ext.py`）未安装，当前仍用 `--disable-custom-all-reduce`。
- W4A16 版 draft（`Qwen3.8-27B-DFlash2-W4A16`）未找到国内镜像；换成量化 draft 后可省约 2 GB 显存，也许能把拐点从 2 流推到 4 流。
- 长上下文（3k+ prompt）场景未测。HiCache 与 DFlash2 在该场景的价值应明显高于短文本压测。
