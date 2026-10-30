# 16MB allreduce 探针：验证 canAccessPeer、RCCL 通道和数值正确性
import os
import torch
import torch.distributed as dist

rank = int(os.environ["RANK"])
local = int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(local)
dist.init_process_group("nccl")

if rank == 0:
    assert torch.cuda.device_count() >= 2, "需要两张可见 GPU"
    p01 = torch.cuda.can_device_access_peer(0, 1)
    p10 = torch.cuda.can_device_access_peer(1, 0)
    print(f"[probe] canAccessPeer 0->1={p01} 1->0={p10}", flush=True)
    assert p01 and p10, "HIP peer access 未打通，先检查 p2p_force / KFD"

n = 4 << 20  # 4M float32 = 16MB
t = torch.ones(n, dtype=torch.float32, device=f"cuda:{local}")

# 预热：先把 GPU 时钟拉起来，否则空闲功耗状态下测到的带宽会低一半
w = torch.ones(16 << 20, dtype=torch.float32, device=f"cuda:{local}")
m = torch.randn(4096, 4096, dtype=torch.float16, device=f"cuda:{local}")
for _ in range(30):
    dist.all_reduce(w)
    m @ m
torch.cuda.synchronize()
del w, m

for _ in range(5):
    dist.all_reduce(t)
torch.cuda.synchronize()

start = torch.cuda.Event(enable_timing=True)
end = torch.cuda.Event(enable_timing=True)
start.record()
for _ in range(20):
    dist.all_reduce(t)
end.record()
torch.cuda.synchronize()

ms = start.elapsed_time(end)
algbw = n * 4 * 20 / (ms * 1e-3) / 1e9

check = torch.ones(1 << 16, dtype=torch.float32, device=f"cuda:{local}")
dist.all_reduce(check)
torch.cuda.synchronize()
bad = int(((check - 2.0).abs() > 1e-5).sum().item())

if rank == 0:
    print(f"[probe] allreduce 16MB: {ms / 20 * 1000:.1f} us/iter, {algbw:.2f} GB/s, bad={bad}", flush=True)

assert bad == 0, "allreduce 数值错误"
dist.destroy_process_group()
