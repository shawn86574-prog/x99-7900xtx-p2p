#!/usr/bin/env python3
"""统一压测：Strata DP2 / SGLang TP2 通用，口径对齐 lcz.me/post/24728。

口径：
  - temperature=0、reasoning_effort=medium（帖子的 medium thinking）
  - 每条流用不同种子提示词（规避 DP2 的「同会话回原卡」路由）
  - 记录 TTFT、decode 速率（(out-1)/(total-ttft)，扣除 prefill）
  - 聚合 = 同轮所有流 completion_tokens 之和 ÷ 墙钟
  - 可选 --context-tokens N：在提问前塞入 N token 的填充素材（对齐帖子 64K/128K 口径）

用法：
  /home/jay/sglang-venv/bin/python scripts/bench-unified.py \
      --base-url http://127.0.0.1:8082 --levels 1,2 --rounds 3 \
      --max-tokens 512 --context-tokens 0 --out /tmp/strata_dp2_short.json
"""
import argparse
import asyncio
import json
import os
import statistics
import sys
import time

import aiohttp

TOKENIZER = "/mnt/llm/sglang/models/Qwen3.8-27B-abliterated-AWQ-INT4"


class HFTok:
    """transformers 分词器；encode/decode 接口与 tokenizers.Tokenizer 对齐。"""

    def __init__(self, path):
        from transformers import AutoTokenizer
        self.t = AutoTokenizer.from_pretrained(path, trust_remote_code=True)

    def encode(self, text, add_special_tokens=False):
        ids = self.t.encode(text, add_special_tokens=add_special_tokens)
        return type("E", (), {"ids": ids})()

    def decode(self, ids):
        return self.t.decode(ids, skip_special_tokens=True)

SEEDS = [
    "请写一篇长文，主题：为什么 DRAM 带宽会成为大模型推理的瓶颈。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：MoE 模型的专家路由是怎样影响显存与内存的占用的。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：张量并行与流水并行的取舍。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：投机解码（speculative decoding）的收益条件。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：量化到 3bit 之后精度与速度的关系。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：CUDA graph 在推理引擎里的作用。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：注意力机制在长上下文下的复杂度。要求连续论证，不要列表，不要提前收尾。",
    "请写一篇长文，主题：PCIe 带宽对多卡推理的影响。要求连续论证，不要列表，不要提前收尾。",
]

FILLER = (
    "以下是一段用于填充上下文的资料，请把它当作背景阅读，不要复述、不要总结，直接回答最后的问题。"
    "在分布式推理系统中，单机内部的资源包括处理器、内存、加速卡以及连接它们的总线。"
    "内存子系统通常按照通道组织，每个通道可以独立提供一定的峰值带宽，实际可用带宽取决于访问模式、"
    "并发度、缓存命中率以及内存控制器的调度策略。顺序访问与随机访问的差异在专家权重流式加载的场景中尤其明显。"
    "当工作集的规模远大于末级缓存时，预取器的作用有限，延迟主要由内存访问的并行度决定。"
    "加速卡一侧则受制于显存容量与显存带宽，以及主机与设备之间的传输通道。"
    "把经常被访问的权重块缓存在显存中，可以显著降低跨总线的流量，但缓存容量与KV缓存、中间激活之间存在竞争关系。"
    "推理引擎需要在批处理规模、上下文长度、缓存命中率与延迟之间做权衡。"
)

CORPUS_GLOB = "/home/jay/work/x99-7900xtx-p2p/docs/*.md"


def build_corpus(paths):
    import glob
    text = []
    for p in sorted(glob.glob(paths)):
        try:
            text.append(open(p, encoding="utf-8").read())
        except OSError:
            continue
    return "\n\n".join(text)


def build_prompt(tok, target_tokens, seed_idx, corpus_ids=None):
    q = SEEDS[seed_idx % len(SEEDS)]
    n_q = len(tok.encode(q, add_special_tokens=False).ids)
    if target_tokens <= n_q + 16:
        return q
    body_target = target_tokens - n_q
    if corpus_ids:
        n = len(corpus_ids)
        start = (seed_idx * (n // len(SEEDS))) % n
        ids = (corpus_ids * (body_target // n + 2))[start:start + body_target]
        body = tok.decode(ids)
    else:
        ids = tok.encode(FILLER, add_special_tokens=False).ids
        if len(ids) < body_target:
            ids = (ids * (body_target // len(ids) + 1))[:body_target]
        body = tok.decode(ids[:body_target])
    return body + "\n\n" + q


async def one(session, ep, model, prompt, idx, max_tokens, effort, results):
    t0 = time.perf_counter()
    ttft = None
    t_last = None
    usage = None
    try:
        payload = {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": True,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"reasoning_effort": effort},
        }
        async with session.post(ep, json=payload) as r:
            if r.status != 200:
                body = await r.text()
                results.append({"ok": False, "idx": idx, "err": f"HTTP {r.status}: {body[:160]}"})
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
                if ch and (ch[0].get("delta", {}).get("content") or ch[0].get("delta", {}).get("reasoning_content")):
                    now = time.perf_counter()
                    if ttft is None:
                        ttft = now - t0
                    t_last = now
        total = time.perf_counter() - t0
        out_tok = (usage or {}).get("completion_tokens", 0)
        prompt_tok = (usage or {}).get("prompt_tokens", 0)
        dec = None
        if ttft is not None and t_last is not None and out_tok > 1 and t_last > t0 + ttft:
            dec = (out_tok - 1) / (t_last - t0 - ttft)
        results.append({
            "ok": True, "idx": idx, "ttft": ttft, "total": total,
            "t_first": (t0 + ttft) if ttft else None, "t_end": time.perf_counter(),
            "out_tok": out_tok, "prompt_tok": prompt_tok, "decode_tps": dec,
        })
    except Exception as exc:  # noqa: BLE001
        results.append({"ok": False, "idx": idx, "err": repr(exc)[:120]})


def pct(arr, p):
    if not arr:
        return None
    arr = sorted(arr)
    k = max(0, min(len(arr) - 1, int(round((len(arr) - 1) * p))))
    return arr[k]


async def get_model(session, base):
    async with session.get(base + "/v1/models") as r:
        data = await r.json()
    return data["data"][0]["id"]


async def get_metrics(session, base):
    try:
        async with session.get(base + "/metrics", timeout=aiohttp.ClientTimeout(total=5)) as r:
            return await r.json()
    except Exception:  # noqa: BLE001
        return None


async def run_level(session, base, model, prompts, conc, rounds, max_tokens, effort, warmup):
    ep = base + "/v1/chat/completions"
    per_round = []
    for r in range(rounds + (1 if warmup else 0)):
        results = []
        t0 = time.perf_counter()
        await asyncio.gather(*[
            one(session, ep, model, prompts[(r * conc + i) % len(prompts)], i, max_tokens, effort, results)
            for i in range(conc)
        ])
        wall = time.perf_counter() - t0
        ok = [x for x in results if x["ok"]]
        if r < (1 if warmup else 0):
            print(f"  warmup c={conc}: {len(ok)}/{len(results)} ok, wall {wall:.1f}s", flush=True)
            continue
        if not ok:
            per_round.append({"conc": conc, "fail": [x.get("err") for x in results][:2]})
            continue
        t_first = min(x["t_first"] for x in ok if x["t_first"])
        t_end = max(x["t_end"] for x in ok)
        dec_window = max(t_end - t_first, 1e-6)
        per_round.append({
            "conc": conc,
            "ok": len(ok),
            "wall_s": round(wall, 2),
            "decode_window_s": round(dec_window, 2),
            "out_tokens": sum(x["out_tok"] for x in ok),
            "agg_tps": round(sum(x["out_tok"] for x in ok) / dec_window, 1),
            "agg_tps_wall": round(sum(x["out_tok"] for x in ok) / wall, 1),
            "per_stream_mean": round(statistics.mean(x["decode_tps"] for x in ok if x["decode_tps"]), 1),
            "decode_tps": [round(x["decode_tps"], 1) for x in ok if x["decode_tps"]],
            "ttft_ms": [round(x["ttft"] * 1000) for x in ok if x["ttft"]],
            "prompt_tok": ok[0]["prompt_tok"],
            "out_tok": [x["out_tok"] for x in ok],
        })
    agg = [x for x in per_round if "agg_tps" in x]
    summary = {"conc": conc}
    if agg:
        summary.update({
            "rounds": len(agg),
            "agg_tps_mean": round(statistics.mean(x["agg_tps"] for x in agg), 1),
            "agg_tps_all": [x["agg_tps"] for x in agg],
            "per_stream_mean": round(statistics.mean(x["per_stream_mean"] for x in agg), 1),
            "ttft_p50_ms": pct([t for x in agg for t in x["ttft_ms"]], 0.5),
            "ttft_p95_ms": pct([t for x in agg for t in x["ttft_ms"]], 0.95),
            "prompt_tok": agg[0]["prompt_tok"],
        })
    else:
        summary["fail"] = per_round[:1]
    summary["detail"] = per_round
    return summary


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8082")
    ap.add_argument("--levels", default="1,2")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--context-tokens", type=int, default=0)
    ap.add_argument("--reasoning-effort", default="medium")
    ap.add_argument("--warmup", action="store_true", default=True)
    ap.add_argument("--out", default="/tmp/bench-unified.json")
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    tok = HFTok(TOKENIZER)
    corpus_ids = None
    if args.context_tokens > 64:
        corpus_ids = tok.encode(build_corpus(CORPUS_GLOB), add_special_tokens=False).ids
        print(f"corpus {len(corpus_ids)} tokens", flush=True)
    prompts = [build_prompt(tok, args.context_tokens, i, corpus_ids) for i in range(len(SEEDS))]
    est = len(tok.encode(prompts[0], add_special_tokens=False).ids)

    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=3600)) as s:
        model = await get_model(s, args.base_url)
        print(f"label={args.label} base={args.base_url} model={model} "
              f"ctx≈{est}tok max_tokens={args.max_tokens} effort={args.reasoning_effort}", flush=True)
        m0 = await get_metrics(s, args.base_url)
        out = []
        for c in [int(x) for x in args.levels.split(",")]:
            r = await run_level(s, args.base_url, model, prompts, c, args.rounds,
                                args.max_tokens, args.reasoning_effort, args.warmup)
            out.append(r)
            print(json.dumps({k: v for k, v in r.items() if k != "detail"}, ensure_ascii=False), flush=True)
        m1 = await get_metrics(s, args.base_url)
    payload = {"label": args.label, "base_url": args.base_url, "model": model,
               "context_tokens": est, "max_tokens": args.max_tokens,
               "reasoning_effort": args.reasoning_effort, "results": out,
               "metrics_before": m0, "metrics_after": m1}
    with open(args.out, "w") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print(f"written {args.out}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
