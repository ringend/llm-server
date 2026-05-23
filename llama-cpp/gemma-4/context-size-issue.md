# Gemma 4 26B A4B — llama.cpp Server Configuration Summary

## Final Configuration

```bash
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --device /dev/dri \
  -p 8130:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -v /llm-models:/llm-models \
  cr.ringen.cloud:5000/llama.cpp:server-vulkan-b8763-04-11-26 \
  --model "$LLM_MODEL" \
  --gpu-layers -1 \
  --parallel 6 \
  --kv-unified \
  --ctx-size 1075200 \
  --batch-size 1024 \
  --ubatch-size 256 \
  --cache-ram 0 \
  --cont-batching \
  --flash-attn on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --metrics \
  --host :: \
  --port 8080
```

**Net result:** 6 concurrent slots, 175K context per slot, ~11 GB single Vulkan KV allocation, no server-level prompt-state crashes.

---

## Hardware & Model Context

- **GPU:** AMD Radeon 8060S (RADV STRIX_HALO) with 120 GB GTT memory, ~108 GB free at startup
- **Backend:** Vulkan
- **Model:** Gemma 4 26B A4B Q8_0 (~25 GB on disk, MoE with 128 experts / 8 active)
- **Model's native context:** 262,144 tokens (256K), iSWA hybrid attention
- **llama.cpp build:** b8763

---

## Configuration Decisions

### `--parallel 6`
Supports up to 6 concurrent sessions across opencode, continue.dev, Hermes-agent, and OpenClaw. Each slot gets its own session state.

### `--kv-unified`
Shares the KV cache pool across all slots instead of allocating per-slot buffers. Drastically reduces the single-buffer Vulkan allocation size, which is the actual bottleneck on Strix Halo (not total memory).

### `--ctx-size 1075200`
175K × 6 slots = 1,075,200 total cells. Chosen as the sweet spot:
- Large enough for monorepo coding contexts, long RAG preambles, and deep agent chains
- Small enough to keep the single Vulkan KV buffer at ~11 GB, well under RADV's per-allocation ceiling (~12–16 GB driver-dependent)
- Proven allocation size — the earlier 256K × 4 test allocated ~10.9 GB successfully

### `--cache-type-k q8_0` + `--cache-type-v q8_0`
Quantizes the KV cache from f16 to q8_0, **halving** the KV buffer size (~22 GB → ~11 GB at this context size). Quality loss on Gemma 4 attention is negligible. Requires `--flash-attn` to be enabled.

### `--flash-attn on`
Required for KV quantization. Also a meaningful perf win on its own.

### `--batch-size 1024` / `--ubatch-size 256`
Conservative compute buffer sizing that matches what was proven stable at 128K × 4 in earlier testing. Can be bumped later (`--ubatch-size 512`) for faster prompt evaluation once stability is confirmed.

### `--cont-batching`
Continuous batching across slots — needed for efficient multi-slot serving.

### `--cache-ram 0`
**The critical flag.** Disables the server-level RAM prompt cache. See next section.

---

## The Bug: `--kv-unified` + iSWA + Prompt Cache Save

### What happens

During testing with `--parallel 4 --kv-unified --ctx-size 1048576` (256K × 4) and the default `--cache-ram 8192`, the server crashed on the **second concurrent request**:

```
GGML_ASSERT(tensor->data != NULL && "tensor not allocated") failed
  libllama.so: llama_io_write_buffer::write_tensor
  libllama.so: llama_kv_cache::state_write_data
  libllama.so: llama_kv_cache_iswa::state_write
  libllama.so: llama_context::state_seq_write_data
  llama-server: slot_save
```

### Why it happens

Three recently-added features interact badly:

1. **iSWA (interleaved Sliding Window Attention)** — Gemma 3 and 4 use this; the KV cache is split into non-SWA layers (full cache) and SWA layers (small windowed cache).
2. **`--kv-unified`** — when enabled, all slots share a single KV pool and re-enables `--clear-idle` behavior (idle slots get saved to the RAM prompt cache when another slot becomes active).
3. **RAM prompt cache** (introduced in [PR #16391](https://github.com/ggml-org/llama.cpp/pull/16391)) — serializes an idle slot's full KV state into host RAM so it can be restored later for prefix matching.

The crash path:
1. User sends request → hits slot 3 → runs successfully.
2. User sends second request → LRU picks slot 2 → server tries to save slot 3's state to the RAM cache first.
3. The iSWA cache's `state_write` path tries to serialize a tensor that wasn't allocated in this unified-KV + hybrid-memory configuration.
4. `GGML_ASSERT(tensor->data != NULL)` fires → server aborts.

### Is it fixed upstream?

As of build **b8847** (April 19, 2026 — ~85 builds ahead of b8763), **no merged PR or open issue explicitly addresses this specific crash path**. The bug combines three relatively new features (Gemma 4 support, `--kv-unified` default behavior, and the RAM prompt cache) in a way that's likely underexposed to broader testing. Worth filing an upstream issue with the clean stack trace and reproducer.

---

## The Workaround: `--cache-ram 0`

Disabling the RAM prompt cache removes the crashing code path entirely. The server still operates normally — it just doesn't save/restore slot states to host RAM between sessions.

### What you KEEP with `--cache-ram 0`

- **In-slot KV cache** — the primary cache that makes same-conversation turns fast. Completely unaffected.
- All tool-call round-trips within an active session: instant.
- Multi-turn agent loops: instant (stays in same slot).
- Long-running chat continuations: instant.
- Full 175K context per slot, Q8_0 quality, 6-way concurrency.

### What you LOSE with `--cache-ram 0`

Cross-session prefix reuse that the server-level RAM cache would have provided. Impact varies by tool:

| Tool | Pain Level | Why |
|---|---|---|
| **continue.dev** | High | Frequent context shifts (file switching, RAG rebuilds) each pay full re-eval cost |
| **opencode** | Moderate | New tasks re-evaluate AGENTS.md + repo context; active tasks unaffected |
| **OpenClaw** | Moderate | Depends on agent-run length; short runs hurt more |
| **Hermes-agent** | Low | Long cohesive agent runs stay warm in-slot; only cold-starts hit |

### Real-world cost estimate

- Cold task start (~20–50K prefix): 30–90 sec extra re-evaluation
- Fresh continue.dev chat with codebase RAG: 30–120 sec on first query
- Agent cold-start (system prompt + tool schemas): 5–15 sec
- Estimated daily aggregate: **5–20 minutes of extra waiting** across typical mixed usage

### Mitigating factor: SWA already limits RAM cache benefit

Gemma 4's iSWA architecture **already** forces full prompt re-processing in many cases even with `--cache-ram` enabled, due to sliding-window attention's incompatibility with arbitrary prefix restoration. Startup logs confirm this:

```
forcing full prompt re-processing due to lack of cache data 
(likely due to SWA or hybrid/recurrent memory)
```

This means `--cache-ram 0` on Gemma 4 hurts *less* than it would on a non-SWA model like Qwen or Llama. Some of the cache hits that `--cache-ram` would theoretically provide are already unavailable due to the architecture itself.

---

## What This Config Optimizes For

| Priority | How it's addressed |
|---|---|
| **No crashes under multi-slot concurrent use** | `--cache-ram 0` eliminates the iSWA + unified-KV + prompt-save assert |
| **Large per-slot context for coding/RAG workloads** | 175K per slot — well above typical needs |
| **Multiple concurrent sessions** | 6 parallel slots covers realistic peak (opencode + continue.dev + Hermes + OpenClaw + headroom) |
| **Memory efficiency on Strix Halo** | KV quantization halves the single-buffer Vulkan allocation |
| **Stability over micro-optimization** | Conservative batch sizes; no experimental features |

---

## Future Revisit Triggers

Reconsider this configuration if:

1. **Upstream fixes the iSWA + unified-KV + prompt-save bug** → re-enable `--cache-ram 8192`, regain cross-session prefix reuse.
2. **Workload shifts toward continue.dev being primary** → consider splitting into two containers (one with cache-ram for short queries, one stable for long sessions).
3. **Realistic concurrency exceeds 6** → bump `--parallel` up; may need to drop per-slot context.
4. **Prompt-eval speed becomes a pain point** → bump `--ubatch-size` to 512 (roughly doubles prompt-eval throughput for ~500 MB extra compute buffer).



Here you go — drop this into the summary document as a new section (e.g., after "Configuration Decisions" or as an addendum):

---

## Addendum: Performance Impact of `--kv-unified` and KV Quantization

After putting the initial configuration into production, a repeatable chat benchmark (same prompt sent to the model three times, measuring generation tokens-per-second on each response) showed a drop from ~42 tok/s to ~35 tok/s compared to the earlier non-unified, f16-KV setup. Investigation traced this roughly 17% slowdown to two of the newly-added flags: `--kv-unified` and `--cache-type-k q8_0 / --cache-type-v q8_0`. Importantly, `--cache-ram 0` itself had **no measurable impact** on the benchmark — it only affects server-level prompt-state serialization across sessions, not in-slot KV caching or token generation speed.

The dominant cost (~5–6 tok/s of the 7 tok/s drop) comes from `--kv-unified`. When the KV cache is shared across all slots in a single pool, the attention kernel operates over the entire unified buffer even when only one slot is active, then masks out the other slots' regions. This wastes memory bandwidth and compute on every token generated, regardless of how many sessions are actually running. This behavior is acknowledged in the upstream PR ([#14363](https://github.com/ggml-org/llama.cpp/pull/14363)) that introduced unified KV, where the maintainers specifically note it "leads to performing a lot of unnecessary computation in the attention when the unified buffer is shared between many large independent sequences." A secondary cost (~1–2 tok/s) comes from q8_0 KV quantization, which requires on-the-fly dequantization during attention reads in the Vulkan backend.

### Why KV Quantization Must Stay

Initial analysis suggested both flags could be dropped to recover the lost speed. That analysis was wrong in one important respect: **KV quantization is not optional at this context size.** llama.cpp allocates a single Vulkan buffer for the entire KV cache (not per-slot buffers), and RADV on STRIX_HALO has a per-allocation ceiling of roughly 10–12 GB. At 175K × 6 total cells (~1.08M cells) the f16 KV buffer would be ~21 GB — well over the driver limit, which is exactly the failure mode encountered in earlier testing when attempting larger total contexts like 175K × 4 without quantization. The q8_0 flags halve the buffer to ~11 GB, which is what makes the large total context allocatable in the first place. These flags must remain, and they cost 1–2 tok/s as an unavoidable trade for the context size.

### What `--kv-unified` Actually Buys (and Why It's Not Worth It Here)

`--kv-unified` changes how context is partitioned across slots without meaningfully changing the total KV buffer size. In non-unified mode, `--ctx-size` is divided evenly across slots (each slot gets `n_ctx / n_parallel` guaranteed). In unified mode, all slots share a single pool of size `n_ctx`, meaning one heavy session could use the entire pool while others sit idle. At the same ~1.08M cell buffer budget, unified mode would allow each slot to reach up to **262K** (Gemma 4's trained maximum) on demand, versus the **175K** fixed per-slot ceiling in non-unified mode. That flexibility is the legitimate use case for unified KV — supporting bursty long-context workloads without pre-committing per-slot allocations.

For this deployment, the trade-off clearly favors the ~5–6 tok/s of generation speed over the +87K of theoretical per-slot context headroom. In coding and agent workloads (opencode, continue.dev, Hermes-agent, OpenClaw), 175K per slot is far more than typical sessions actually consume — even large monorepo context, tool definitions, conversation history, and RAG preambles rarely exceed 100K combined. Trading real, constant generation speed for context that almost never gets used is a bad deal. The non-unified 175K × 6 configuration provides predictable per-slot capacity, faster per-request response, and no contention under concurrent load.

### Revised Configuration (recommended)

```bash
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --device /dev/dri \
  -p 8130:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -v /llm-models:/llm-models \
  cr.ringen.cloud:5000/llama.cpp:server-vulkan-b8763-04-11-26 \
  --model "$LLM_MODEL" \
  --gpu-layers -1 \
  --parallel 6 \
  --ctx-size 1075200 \
  --batch-size 1024 \
  --ubatch-size 256 \
  --cache-ram 0 \
  --cont-batching \
  --flash-attn on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --metrics \
  --host :: \
  --port 8080
```

**Changes from the original final configuration:**
- Removed `--kv-unified` (restores ~5–6 tok/s, locks per-slot context at 175K fixed instead of 262K flexible)
- **Retained** `--cache-type-k q8_0` and `--cache-type-v q8_0` (required — f16 KV at this context size would exceed RADV's single-allocation limit)
- Retained `--cache-ram 0` (still needed to prevent the iSWA + idle-slot-save crash; no performance cost)
- All other stability and concurrency settings unchanged

**Expected outcome:** benchmark returns to ~40–41 tok/s (1–2 tok/s shy of the original f16 baseline, which is the permanent cost of q8_0 at this context size). KV footprint is ~11 GB in a single Vulkan buffer, comfortably under RADV's per-allocation ceiling. The original crash condition remains mitigated by `--cache-ram 0`. This is the recommended daily-driver configuration going forward.

### Single Vulkan Buffer Ceiling — The Real Constraint

| Configuration | Total cells | f16 buffer | q8_0 buffer | Viable on RADV? |
|---|---|---|---|---|
| 128K × 4 | 524,288 | ~10.0 GB | ~5.0 GB | ✅ f16 worked (at edge) |
| 175K × 4 | 716,800 | ~14.0 GB | ~7.0 GB | ❌ f16 crashes — needs q8_0 |
| **175K × 6 (current)** | **1,075,200** | ~21.0 GB | **~11.0 GB** | **✅ q8_0 only** |
| 256K × 4 | 1,048,576 | ~20.5 GB | ~10.9 GB | ✅ q8_0 only |
| 225K × 6 | 1,382,400 | ~27.0 GB | ~14.0 GB | ⚠️ approaching q8_0 limit |
| 256K × 6 | 1,572,864 | ~30.7 GB | ~16.3 GB | ❌ likely exceeds q8_0 ceiling |

The practical ceiling on this hardware is roughly **1.1M total KV cells with q8_0**. Beyond that, the single Vulkan allocation starts pressing against RADV's per-allocation limit, regardless of total GPU memory available.

### When to Revisit These Flags

- **Re-enable `--kv-unified`** only if workload patterns shift such that single sessions regularly need more than 175K of context (e.g., feeding entire large documents or deep RAG retrievals that exceed the per-slot fixed limit). Accept the ~5–6 tok/s cost knowingly.
- **Cannot disable KV quantization** at this context size — it's structurally required. Only becomes optional if total cells drop below ~500K (e.g., 128K × 4 or 80K × 6).
- **Re-enable `--cache-ram`** only after upstream llama.cpp fixes the iSWA + unified-KV + prompt-save assert (currently unresolved as of build b8847).
- **Consider `--parallel 4 --ctx-size 1048576`** (256K × 4, q8_0, non-unified) as an alternative daily driver if realistic concurrency peaks at 3–4 sessions — trades 2 slots for full 256K per-slot context at the same ~40 tok/s generation speed.

---

## Upstream References

- **Model architecture:** [Gemma 4 model type detection (PR #22027)](https://github.com/ggml-org/llama.cpp/pull/22027)
- **iSWA KV cache:** [kv-cache: add SWA support (PR #13194)](https://github.com/ggml-org/llama.cpp/pull/13194)
- **Unified KV / high-throughput mode:** [PR #14363](https://github.com/ggml-org/llama.cpp/pull/14363)
- **RAM prompt cache:** [PR #16391](https://github.com/ggml-org/llama.cpp/pull/16391)
- **Current build:** b8763 · **Latest release:** [b8847](https://github.com/ggml-org/llama.cpp/releases/tag/b8847)
- **Bug report destination:** [ggml-org/llama.cpp/issues](https://github.com/ggml-org/llama.cpp/issues/new/choose)