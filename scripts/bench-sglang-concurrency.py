#!/usr/bin/env python3
"""SGLang 并发压测：测 TTFT / 端到端延迟 / 总吞吐 / 双卡利用率。

用法：
    /home/jay/sglang-venv/bin/python scripts/bench-sglang-concurrency.py [并发列表] [每级轮数]
    /home/jay/sglang-venv/bin/python scripts/bench-sglang-concurrency.py 1,2,4,8 4

环境变量：
    SGLANG_PORT  默认 30000
    SGLANG_MODEL 默认 qwen38-27b
    MAX_TOKENS   默认 256
依赖：aiohttp（sglang-venv 自带）
"""
import asyncio
import json
import os
import statistics
import sys
import threading
import time

import aiohttp

PORT = os.environ.get("SGLANG_PORT", "30000")
MODEL = os.environ.get("SGLANG_MODEL", "qwen38-27b")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
EP = f"http://127.0.0.1:{PORT}/v1/chat/completions"
PROMPT = ("请用中文解释张量并行的基本原理，包括它在 Transformer 推理中如何切分权重、"
          "如何引入集合通信，以及为什么通信开销会决定扩展效率。请给出结构化的说明。") * 4

LEVELS = [int(x) for x in (sys.argv[1].split(",") if len(sys.argv) > 1 else ["1", "2", "4", "8"])]
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 4


def gpu_busy():
    out = []
    for c in ("card0", "card2"):
        try:
            out.append(int(open(f"/sys/class/drm/{c}/device/gpu_busy_percent").read()))
        except OSError:
            out.append(None)
    return out


class GpuSampler:
    def __init__(self):
        self.samples = []
        self._run = False

    def start(self):
        self._run = True
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self._run:
            g = gpu_busy()
            if g[0] is not None:
                self.samples.append(g)
            time.sleep(0.2)

    def stop(self):
        self._run = False
        time.sleep(0.25)
        if not self.samples:
            return None
        return [round(statistics.mean(s[i] for s in self.samples), 1) for i in range(2)]


async def one(session, idx, sem, results):
    async with sem:
        t0 = time.perf_counter()
        ttft = None
        chunks = 0
        usage = None
        try:
            payload = {
                "model": MODEL,
                "messages": [{"role": "user", "content": PROMPT}],
                "max_tokens": MAX_TOKENS,
                "temperature": 0,
                "stream": True,
                "stream_options": {"include_usage": True},
            }
            async with session.post(EP, json=payload) as r:
                if r.status != 200:
                    results.append({"ok": False, "err": f"HTTP {r.status}", "idx": idx})
                    return
                async for raw in r.content:
                    line = raw.decode("utf-8", "ignore").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        obj = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("usage"):
                        usage = obj["usage"]
                    ch = obj.get("choices") or []
                    if ch and ch[0].get("delta", {}).get("content"):
                        if ttft is None:
                            ttft = time.perf_counter() - t0
                        chunks += 1
            total = time.perf_counter() - t0
            out_tok = (usage or {}).get("completion_tokens", chunks)
            results.append({"ok": True, "ttft": ttft, "total": total, "out_tok": out_tok, "idx": idx})
        except Exception as exc:  # noqa: BLE001
            results.append({"ok": False, "err": repr(exc)[:80], "idx": idx})


def pct(arr, p):
    if not arr:
        return None
    k = max(0, min(len(arr) - 1, int(round((len(arr) - 1) * p))))
    return arr[k]


async def run_level(conc, rounds):
    results = []
    sem = asyncio.Semaphore(conc)
    sampler = GpuSampler()
    sampler.start()
    t0 = time.perf_counter()
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=300)) as s:
        await asyncio.gather(*[one(s, i, sem, results) for i in range(conc * rounds)])
    wall = time.perf_counter() - t0
    gpu = sampler.stop()

    ok = [r for r in results if r["ok"]]
    bad = [r for r in results if not r["ok"]]
    if not ok:
        return {"conc": conc, "ok": 0, "fail": len(bad), "errs": [b.get("err") for b in bad][:3]}

    ttfts = sorted(r["ttft"] for r in ok if r["ttft"] is not None)
    totals = sorted(r["total"] for r in ok)
    toks = sum(r["out_tok"] for r in ok)

    return {
        "conc": conc,
        "reqs": len(results),
        "ok": len(ok),
        "fail": len(bad),
        "wall_s": round(wall, 2),
        "req_per_s": round(len(ok) / wall, 2),
        "out_tokens": toks,
        "tokens_per_s": round(toks / wall, 1),
        "per_req_tok_s": round(statistics.mean(r["out_tok"] / r["total"] for r in ok), 1),
        "ttft_mean_ms": round(statistics.mean(ttfts) * 1000, 0) if ttfts else None,
        "ttft_p50_ms": round(pct(ttfts, 0.5) * 1000, 0) if ttfts else None,
        "ttft_p95_ms": round(pct(ttfts, 0.95) * 1000, 0) if ttfts else None,
        "lat_mean_ms": round(statistics.mean(totals) * 1000, 0),
        "lat_p50_ms": round(pct(totals, 0.5) * 1000, 0),
        "lat_p95_ms": round(pct(totals, 0.95) * 1000, 0),
        "gpu_busy_pct": gpu,
        "errs": [b.get("err") for b in bad][:3],
    }


async def main():
    out = []
    print(f"endpoint={EP} model={MODEL} max_tokens={MAX_TOKENS} 每级并发×{ROUNDS}轮", flush=True)
    for c in LEVELS:
        r = await run_level(c, ROUNDS)
        out.append(r)
        print(json.dumps(r, ensure_ascii=False), flush=True)
    with open("/tmp/sglang_tp2_p2p_bench.json", "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("\n结果已写入 /tmp/sglang_tp2_p2p_bench.json")


if __name__ == "__main__":
    asyncio.run(main())
