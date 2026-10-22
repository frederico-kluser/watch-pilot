---
tipo: research-qa
pergunta: "Q5 — OpenRouter + Xiaomi MiMo 2.6 Pro: model ids, providers, max reasoning payload, measured probe, error/retry, streaming"
criado: 2026-10-22
atualizado: 2026-10-22
estado: respondido
confianca_global: alta
metodo: "curl + jq via `zsh -l` com $OPENROUTER_API_KEY; endpoint /models, /models/{id}/endpoints, /chat/completions, /generation; debug.echo_upstream_body"
---

# Q5 — OpenRouter + Xiaomi MiMo 2.6 Pro

Everything below was **measured live** against `https://openrouter.ai/api/v1` on 2026-10-22 with a
paid key (no credit cap; `is_free_tier: false`). Where a claim comes from documentation instead of a
measurement it is marked `[doc]`. Confidence is stated per finding.

---

## 0. TL;DR — what the hub should actually send

The model id is real and cheap. The one non-obvious trap:

> **`reasoning.effort` is accepted and enum-validated, but it is NOT forwarded to the provider.**
> OpenRouter collapses it to a boolean. `effort: "max"` and `effort: "low"` produce an
> **byte-identical upstream body**. There is no graded "max thinking" knob for this model.

So "run at maximum reasoning" must be implemented as **(a) reasoning enabled + (b) an explicit depth
demand in the system prompt**, not as an effort dial. Details and proof in §3.

**Recommended body (verified HTTP 200):**

```json
{
  "model": "xiaomi/mimo-v2.6-pro",
  "messages": [
    {"role": "system", "content": "You are a voice assistant answering out loud. Think the problem through exhaustively before replying: enumerate the relevant cases, check your arithmetic, then answer in at most two short spoken sentences. No markdown, no lists."},
    {"role": "user", "content": "<transcript>"}
  ],
  "reasoning": {"effort": "max"},
  "include_reasoning": false,
  "max_tokens": 800,
  "stream": true,
  "usage": {"include": true},
  "provider": {
    "order": ["deepinfra/fp8", "xiaomi/fp8", "novita/fp8"],
    "allow_fallbacks": true,
    "quantizations": ["fp8"],
    "preferred_max_latency": {"p50": 5, "p90": 15},
    "preferred_min_throughput": {"p50": 15},
    "require_parameters": false
  }
}
```

---

## 1. Model ids available now

`GET /api/v1/models?q=mimo` returned **5** models (confidence: **certain**, direct API read):

| id | ctx | max_out | $/M prompt | $/M completion | `reasoning` param |
|---|---|---|---|---|---|
| **`xiaomi/mimo-v2.6-pro`** ← target | 1,050,000 | 131,072 | 0.435 | 0.87 | yes |
| `xiaomi/mimo-v2.6-pro-ultraspeed` | 1,048,576 | 131,072 | 4.35 | 8.70 | yes |
| `xiaomi/mimo-v2.6-flash` | 1,050,000 | 131,072 | 0.14 | 0.28 | yes |
| `xiaomi/mimo-v2.5-pro` | 1,050,000 | 945,000 | 0.3045 | 0.609 | yes |
| `xiaomi/mimo-v2.5` | 1,050,000 | 945,000 | 0.119 | 0.238 | yes |

`xiaomi/mimo-v2.6-pro` detail (confidence: **certain**):

- `canonical_slug`: `xiaomi/mimo-v2.6-pro-20260921` · `hugging_face_id`: `XiaomiMiMo/MiMo-V2.6-Pro-RL`
- `architecture.modality`: `text+image+audio+video->text` (multimodal in, text out)
- `pricing` **per token**: `prompt 0.000000435`, `completion 0.00000087`, `input_cache_read 0.0000000036`
  → i.e. **$0.435 / $0.87 / $0.0036 per million**. Reasoning tokens bill as *output* tokens.
- `context_length`: 1,050,000 · `top_provider.context_length`: 1,048,576 · `top_provider.max_completion_tokens`: 131,072
- `default_parameters`: `temperature 1`, `top_p 0.95`, `frequency_penalty 0`
- `reasoning` object: `{"mandatory": false}` — note it exposes **no** `supported_efforts`,
  `default_effort`, `default_enabled`, `supports_max_tokens` (that absence is a real signal, see §3).
- `supported_parameters`: `frequency_penalty, include_reasoning, logit_bias, max_tokens, min_p,
  presence_penalty, reasoning, repetition_penalty, response_format, seed, stop, structured_outputs,
  temperature, tool_choice, tools, top_k, top_p`
  → **no** `parallel_tool_calls`, **no** `logprobs`/`top_logprobs`, **no** `verbosity`, **no** `reasoning_effort` listed.
- Benchmarks exposed: AA intelligence index 46.3; design-arena elo 1290–1337 across 7 categories.

---

## 2. Providers serving `xiaomi/mimo-v2.6-pro`

`GET /api/v1/models/xiaomi/mimo-v2.6-pro/endpoints` → **5 endpoints** (confidence: **certain**).
Prices converted to $/M for readability; `throughput_last_30m` in tokens/s, `latency_last_30m` in **ms**.

| tag | provider | quant | ctx | max_out | $/M in | $/M out | $/M cache-read | tok/s p50 (p75/p90/p99) | latency p50 (p75/p90/p99) | uptime 5m/30m/1d |
|---|---|---|---|---|---|---|---|---|---|---|
| `deepinfra/fp8` | DeepInfra | fp8 | 1,048,576 | 943,718 | **0.387** ¹ | **0.783** ¹ | 0.00324 | 25 (19/13/5) | **1639** (2663/4460/15365) | 100/100/**100** |
| `xiaomi/fp8` | Xiaomi | fp8 | 1,048,576 | 131,072 | 0.435 | 0.87 | 0.0036 | **35** (26/19/7) | 2335 (4484/8567/20140) | 100/100/97.57 |
| `novita/fp8` | Novita | fp8 | 1,048,576 | 131,072 | 0.435 | 0.87 | 0.0036 | 29 (21/14/4) | 4428 (8323/12785/43579) | 100/100/96.60 |
| `gmicloud/bf16` | GMICloud | bf16 | 1,050,000 | 945,000 | 0.435 | 0.87 | 0.004 | 27 (20/13/6) | 4975 (9196/12506/27741) | 100/100/98.82 |
| `streamlake` | StreamLake | unknown | 1,000,000 | 128,000 | 0.522 | 1.044 | 0.00432 | 31.5 (28/26.2/22.4) | 2346 (2722/3143/3774) | —/—/**9.30** |

¹ DeepInfra carries `pricing.discount: 0.1` (already reflected in the per-token figures).

**Readings:**

- **DeepInfra wins on the three axes that matter for a voice hub**: cheapest, lowest p50 latency
  (1.64 s vs 2.3–5.0 s for the rest), and a flat **100 %** uptime over 1 day. Its p99 latency (15.4 s)
  is the best of the field too, and it allows a 943 k output budget.
- **Xiaomi's own endpoint** is the fastest token generator (35 tok/s p50) — better for long answers,
  worse for latency and price. Good second choice.
- **StreamLake is a trap**: 9.3 % uptime over 24 h, highest price, `discount: -0.2` (a *surcharge*),
  and `quantization: unknown`. Exclude it.
- **GMICloud bf16** is the only unquantized option (highest fidelity) at 19 % worse p50 latency.

### Recommended routing config

Low latency + reliability, measured to select DeepInfra (`openrouter_metadata.summary` →
`"available=3, selected=DeepInfra"`, `strategy: direct`, `attempt: 1`):

```json
"provider": {
  "order": ["deepinfra/fp8", "xiaomi/fp8", "novita/fp8"],
  "allow_fallbacks": true,
  "quantizations": ["fp8"],
  "preferred_max_latency": {"p50": 5, "p90": 15},
  "preferred_min_throughput": {"p50": 15},
  "require_parameters": false
}
```

Why each field behaves this way (confidence: **high** — `routing.md` + live test):

- `order` — strict attempt order, and it **disables price-based load balancing**, so you get
  deterministic behaviour instead of the default 1/price² lottery.
- `allow_fallbacks: true` — the whole point: if DeepInfra 5xx/429s, the request silently moves on.
  Use `only: [...]` instead *only* when you want a hard 404 rather than a fallback.
- `quantizations: ["fp8"]` — drops `gmicloud/bf16` and `streamlake/unknown`. Drop this filter if you
  ever prefer bf16 fidelity over latency.
- `preferred_max_latency` / `preferred_min_throughput` — **preferences, never exclusions**: endpoints
  that miss the cutoff are moved to the end of the queue, not removed, so they can't cause a 503.
  Units are **seconds** for latency here, tokens/s for throughput.
- `require_parameters: false` — leave it off. With `true`, any parameter the endpoint doesn't
  advertise would remove that endpoint entirely; all five advertise `reasoning`, so it buys nothing.

> **Unit correction (confidence: high).** The skill's `references/api.md` states `latency_last_30m` is
> *in seconds*. It is **milliseconds**: DeepInfra reports p50 `1639`, and the same request measured
> 0.97 s wall-clock / `latency: 403` ms via `/generation`. Treat the `latency_last_30m` numbers as ms.
> `preferred_max_latency` in the request body *is* in seconds.

---

## 3. Forcing maximum reasoning — exact schema, and what actually happens

### 3.1 The `reasoning` object

Both forms are accepted (confidence: **certain** — live 400 error text):

```
reasoning.effort: Invalid option: expected one of "max"|"xhigh"|"high"|"medium"|"low"|"minimal"|"none"
```

| field | type | verified behaviour |
|---|---|---|
| `effort` | enum `max, xhigh, high, medium, low, minimal, none` | **Validated, then discarded** for this model — see 3.2 |
| `enabled` | bool | **Works.** `true` turns reasoning on; `false` is the only reliable off switch (0 reasoning tokens) |
| `max_tokens` | int | Accepted alone, but **mutually exclusive with `effort`** → HTTP 400 `Only one of "reasoning.effort" and "reasoning.max_tokens" can be specified`. Alone (`max_tokens: 40`) it did **not** cap reasoning (124 reasoning tokens observed) — the model doesn't advertise `supports_max_tokens` |
| `exclude` | bool | **Weak.** `exclude: true` alone hid the `reasoning` field; but `exclude: true` + `include_reasoning: true` → reasoning text came back (161 chars). `include_reasoning` wins the conflict |
| `context`, `mode` | — | Listed in the schema; not exercised here |

`reasoning_effort` as a **top-level** parameter also works and maps to the same machinery (same enum).
Prefer the nested `reasoning` object; do not send both.

### 3.2 The finding that matters: effort is not forwarded

Captured with `"debug": {"echo_upstream_body": true}` (streaming only, per the docs) — this is the
literal body OpenRouter hands the provider (confidence: **certain**, read from the echo):

| provider | what the provider receives |
|---|---|
| `deepinfra/fp8` | `reasoning: {"enabled": true}` — with `effort: "max"` **and** with `effort: "minimal"` (identical) |
| `xiaomi/fp8` | `reasoning: null` + Xiaomi-native `thinking: {"type": "enabled"}` |

No effort level, no token budget, no "high" marker ever reaches the upstream. Confirmed downstream by
the numbers — same prompt ("how many arrangements of MISSISSIPPI"), same provider (DeepInfra):

| `reasoning` sent | reasoning_tokens | completion_tokens | cost | wall-clock |
|---|---|---|---|---|
| `{"effort": "max"}` | **154** | 183 | $0.000154899 | 2.16 s |
| `{"effort": "low"}` | **140** | 178 | $0.000150984 | 5.26 s |
| `{"effort": "none"}` | 0 | 22 | $0.000029610 | 1.58 s |
| *(omitted entirely)* | 81 | 111 | $0.000105705 | — |
| `{"enabled": false}` | 0 | 22 | $0.000029610 | — |

`max` vs `low` is a ~10 % difference — noise, not a thinking budget. `none` / `enabled:false` are
genuinely different (reasoning disappears and cost drops 5×).

Two more measured facts:

- **Reasoning is ON by default.** A call with no `reasoning` key at all still returned 81 reasoning
  tokens, a `reasoning` field and a `reasoning_details` array. You cannot "accidentally" get a cheap
  non-reasoning call; you must opt out.
- **Provider choice moves reasoning depth more than `effort` does**: same prompt at `effort: "max"`,
  `xiaomi/fp8` produced **192** reasoning tokens vs `deepinfra/fp8`'s **152**.

### 3.3 How to actually get maximum thinking

1. Send `"reasoning": {"effort": "max"}` anyway — it is valid, costs nothing, and is the
   forward-compatible spelling if Xiaomi/OpenRouter ever start honouring a graded budget.
2. **Put the depth in the system prompt.** That is the only lever with a measured effect on this
   model. Ask for exhaustive case enumeration and arithmetic checking before the answer.
3. Do not expect `max_tokens` to buy depth — it caps the *output*, and reasoning spends it.
4. Keep `include_reasoning: false` in production (see §3.4).

### 3.4 How reasoning is returned

Non-streaming — top-level keys were exactly:
`choices, created, id, model, object, provider, service_tier, system_fingerprint, usage`.

- `choices[0].message` keys: `content, reasoning, reasoning_details, refusal, role`
- `message.reasoning` — plain string of the thinking text
- `message.reasoning_details` — array; observed element:
  `{"type": "reasoning.text", "text": "...", "format": "unknown", "index": 0}`
  (docs also allow `reasoning.summary` and `reasoning.encrypted`) `[doc]`
- `usage.completion_tokens_details.reasoning_tokens` — **the only correct place**; there is no
  top-level `usage.reasoning_tokens`
- `usage.cost` in USD for the request; `usage.cost_details.upstream_inference_{prompt,completions}_cost`
  let you confirm which provider price was applied

Control:

- `include_reasoning: false` (or omit it) → `message` has **no** `reasoning` key, but
  `completion_tokens_details.reasoning_tokens` is still non-zero and still **billed**. Verified: 131
  reasoning tokens billed with the field suppressed. This is the right production setting.
- `GET /api/v1/generation?id=<X-Generation-Id>` adds `native_tokens_reasoning`, `latency`,
  `generation_time` — useful for the hub's logs.

---

## 4. The real probe

Primary probe, raw response kept at **`/tmp/mimo-probe.json`** (no secrets in a completion body;
`grep sk-or-v1` → 0 hits). Request: bat-and-ball puzzle, `reasoning: {"effort": "max"}`,
`include_reasoning: true`, `max_tokens: 2000`, no `provider` constraint.

| measurement | value |
|---|---|
| HTTP status | **200** |
| total wall-clock (curl `time_total`) | **0.9696 s** |
| time to first byte (`time_starttransfer`) | 0.5565 s |
| provider selected | **DeepInfra** (`deepinfra/fp8`) |
| `X-Generation-Id` | `gen-1792685105-xEJhEXN2y82fQIDkofda` |
| `usage.prompt_tokens` / `completion_tokens` / `total_tokens` | 49 / 17 / 66 |
| **`usage.completion_tokens_details.reasoning_tokens`** | **8** |
| `usage.cost` | **$0.000032274** |
| `finish_reason` / `native_finish_reason` | `stop` / `stop` |
| `/generation`: `latency` / `generation_time` | 403 ms / 624 ms |
| `/generation`: `native_tokens_reasoning` | 8 |
| answer | `"The ball costs five cents."` |
| reasoning text | `"Classic: ball costs 5 cents."` |

Cost arithmetic checks out against DeepInfra's own price: 49 × $3.87e-7 = $1.896e-5 prompt and
17 × $7.83e-7 = $1.331e-5 completion → $3.2274e-5. **You are billed at the selected provider's price,
not the list price.**

**Spoken-style streaming probe** (the hub's actual shape — 2-sentence system prompt, stream on,
recommended `provider` object): HTTP 200, provider DeepInfra, **TTFT 0.426 s**, **total 3.708 s**,
52 prompt / 70 completion / 26 reasoning tokens, **cost $0.0000749**
(`X-Generation-Id: gen-1792685251-PAVtL9Zdk1GrCnFHi4zn`). Output was a clean two-sentence spoken
answer with no markdown — the spoken-style system prompt holds.

**Cost envelope for the hub:** a short spoken turn is **~$0.00003–0.00008** (≈3–8 thousandths of a
cent). Even at 1,000 turns/day that is well under $1/day.

---

## 5. Errors, retries, streaming

Envelope (confidence: **high** — `references/errors.md` + one live 400):

```json
{"error": {"message": "...", "code": 400}, "user_id": "..."}
```
Branch on `error.metadata.error_type` when present, never on the HTTP status alone.

| status | `error_type` | meaning | action for the hub |
|---|---|---|---|
| 429 | `rate_limit_exceeded` | platform **or** upstream throttling | exponential backoff, honour `Retry-After` (seconds). **SDKs do not honour it for you** — implement manually |
| 402 | `payment_required` | out of credits / key cap | do not retry; surface it. Check `GET /api/v1/key` → `limit_remaining` |
| 401 | — | bad/revoked key | no retry |
| 404 | — | unknown model **or** no provider matches `only`/`max_price` | fix slug or relax routing |
| 503 | `provider_overloaded` | "temporarily overloaded" / no provider meets routing | short delay + retry; `allow_fallbacks` usually handles it |
| 502 | `provider_unavailable` | invalid/empty upstream response | retry; may be auto-retried with another provider |
| 504 | `timeout` | upstream too slow | retry or switch provider |
| 400 | — | body validation (e.g. the `effort` + `max_tokens` conflict) | never retry |

- Retry policy that fits this use case: 3 attempts, backoff 0.5 s → 1 s → 2 s, plus `Retry-After`
  when present, jittered. Give up and speak a fallback line rather than blocking the wrist.
- On success, `X-RateLimit-*` headers are **not** returned; they only appear on OpenRouter's own 429s.
- Zero-Completion Insurance: a response with zero completion tokens and a blank/null/`error` finish
  reason is not billed for prompt/completion/reasoning `[doc]`.

**Streaming notes (measured):**

- Chunk shape: standard SSE `data: {...}` lines ending in `data: [DONE]`.
- `choices[0].delta` keys observed: `role` (first chunk), `content`, **`reasoning`**,
  **`reasoning_details`**. Reasoning arrives as deltas *before* the answer.
- The **final** chunk carries `usage` (full object incl. `cost` and `reasoning_tokens`) and repeats
  `finish_reason` — so parse: accumulate `delta.content`, ignore `delta.reasoning`, read `usage` last.
- `usage: {"include": true}` was **not required** in practice (usage arrived without it; OpenRouter
  injects `stream_options.include_usage` upstream). Send it anyway — it is documented and free.
- `provider` and `model` appear on every chunk, which is handy for logging fallbacks.
- **Mid-stream failures come back as HTTP 200** with an `error` object in the chunk and
  `finish_reason: "error"` — check inside the loop, not just the initial status.
- Timing: TTFT ≈ 0.43 s, then ~25–35 tok/s. For short spoken answers the whole turn lands in ~1–4 s.

---

## 6. Copy-pasteable `httpx` snippet for the hub

Async, streams, forces reasoning at max, applies the routing object, retries 429/5xx honouring
`Retry-After`, and returns the spoken text plus cost/reasoning accounting.

```python
"""OpenRouter -> xiaomi/mimo-v2.6-pro, max reasoning, spoken-style answer. Python 3.11+."""
from __future__ import annotations

import asyncio
import json
import os
import random

import httpx

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "xiaomi/mimo-v2.6-pro"

SYSTEM_PROMPT = (
    "You are a voice assistant answering out loud. Think the problem through exhaustively "
    "before replying: enumerate the relevant cases, check your arithmetic, then answer in at "
    "most two short spoken sentences. No markdown, no lists, no code."
)

# Reasoning is ON by default for this model and reasoning.effort is NOT forwarded upstream,
# so depth is driven by SYSTEM_PROMPT. `effort: "max"` is kept for forward compatibility.
BODY = {
    "model": MODEL,
    "reasoning": {"effort": "max"},
    "include_reasoning": False,       # don't ship thinking text over the wire (still billed)
    "max_tokens": 800,                # caps total output; reasoning spends from this
    "stream": True,
    "usage": {"include": True},
    "provider": {
        "order": ["deepinfra/fp8", "xiaomi/fp8", "novita/fp8"],
        "allow_fallbacks": True,
        "quantizations": ["fp8"],
        "preferred_max_latency": {"p50": 5, "p90": 15},   # seconds; preference, not a hard limit
        "preferred_min_throughput": {"p50": 15},          # tokens/s; preference, not a hard limit
        "require_parameters": False,
    },
}

RETRY_STATUS = {429, 500, 502, 503, 504}


async def ask(transcript: str, *, timeout: float = 60.0, attempts: int = 3) -> dict:
    """Return {'text', 'cost', 'reasoning_tokens', 'provider', 'generation_id'}."""
    headers = {
        "Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/watch-pilot",
        "X-OpenRouter-Title": "watch-pilot-hub",
    }
    body = {**BODY, "messages": [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": transcript},
    ]}

    last_exc: Exception | None = None
    for attempt in range(attempts):
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                async with client.stream("POST", OPENROUTER_URL, headers=headers,
                                         json=body) as resp:
                    if resp.status_code in RETRY_STATUS and attempt < attempts - 1:
                        delay = float(resp.headers.get("Retry-After", 2 ** attempt))
                        await asyncio.sleep(delay + random.uniform(0, 0.25))
                        continue
                    resp.raise_for_status()

                    text: list[str] = []
                    usage: dict = {}
                    provider = None
                    gen_id = resp.headers.get("X-Generation-Id")

                    async for line in resp.aiter_lines():
                        if not line.startswith("data: "):
                            continue
                        payload = line[6:].strip()
                        if payload == "[DONE]":
                            break
                        try:
                            chunk = json.loads(payload)
                        except json.JSONDecodeError:
                            continue

                        # HTTP 200 + error inside the stream is a real failure mode
                        if chunk.get("error"):
                            raise RuntimeError(f"stream error: {chunk['error']}")

                        provider = chunk.get("provider") or provider
                        for choice in chunk.get("choices") or []:
                            if choice.get("finish_reason") == "error":
                                raise RuntimeError("upstream finish_reason=error")
                            delta = choice.get("delta") or {}
                            if delta.get("content"):
                                text.append(delta["content"])
                            # delta["reasoning"] / delta["reasoning_details"]: intentionally ignored
                        if chunk.get("usage"):
                            usage = chunk["usage"]

                    return {
                        "text": "".join(text).strip(),
                        "cost": usage.get("cost", 0.0),
                        "reasoning_tokens": (usage.get("completion_tokens_details") or {})
                                            .get("reasoning_tokens", 0),
                        "provider": provider,
                        "generation_id": gen_id,
                    }
        except (httpx.TransportError, httpx.HTTPStatusError, RuntimeError) as exc:
            last_exc = exc
            if attempt < attempts - 1:
                await asyncio.sleep(2 ** attempt + random.uniform(0, 0.25))

    raise RuntimeError(f"OpenRouter failed after {attempts} attempts") from last_exc


if __name__ == "__main__":
    print(asyncio.run(ask("Should I take an umbrella if the sky is clear but humidity is 95 percent?")))
```

Notes for wiring it into the hub:

- `OPENROUTER_API_KEY` from the environment only; never in the repo (§6 of `AGENTS.md`).
- Don't retry 400/401/402/404 — those are configuration bugs; retrying just burns the wrist's latency.
- If you need the thinking text for debugging, flip `include_reasoning` to `True` and read
  `delta["reasoning"]` / `delta["reasoning_details"]`; nothing else changes and the cost is identical.
- A `provider.only: ["deepinfra/fp8"]` variant is a fine "pin it" mode for latency A/B tests, but it
  turns a transient DeepInfra outage into a hard 503, so keep `allow_fallbacks` for production.

---

## 7. Confidence summary

| # | Finding | Confidence | Basis |
|---|---|---|---|
| 1 | `xiaomi/mimo-v2.6-pro` exists; ctx 1,050,000; $0.435/$0.87 per M; reasoning-capable | **certain** | direct `/models` read |
| 2 | 5 providers with the prices/latency/uptime in §2 | **certain** | direct `/endpoints` read |
| 3 | DeepInfra = cheapest + lowest latency + 100 % uptime | **high** | measured figures; 30 m/1 d windows are point-in-time |
| 4 | `reasoning.effort` enum is `max,xhigh,high,medium,low,minimal,none` | **certain** | live 400 error text |
| 5 | Effort is **not** forwarded upstream (collapsed to boolean) | **certain** | `debug.echo_upstream_body` + token counts |
| 6 | Reasoning ON by default; `enabled:false` truly disables | **certain** | three comparative calls |
| 7 | `effort` + `max_tokens` together → 400 | **certain** | live 400 |
| 8 | `include_reasoning:false` hides text, still bills tokens | **certain** | measured (131 tokens) |
| 9 | `reasoning.exclude` is overridden by `include_reasoning:true` | **moderate** | one conflicting pair; interaction not documented |
| 10 | `reasoning.max_tokens` does not cap reasoning for this model | **moderate** | one observation (asked 40, got 124) |
| 11 | Probe: HTTP 200, DeepInfra, 8 reasoning tokens, $0.000032274, 0.97 s | **certain** | raw response at `/tmp/mimo-probe.json` |
| 12 | Spoken streaming: TTFT 0.43 s, total 3.71 s, $0.0000749 | **high** | one measurement |
| 13 | `latency_last_30m` is milliseconds despite the skill doc saying seconds | **high** | cross-checked vs `/generation` |
| 14 | 429/402/503 handling, Zero-Completion Insurance | **moderate** | documentation, not triggered live |
| 15 | Reasoning depth is provider-dependent (Xiaomi 192 vs DeepInfra 152) | **moderate** | single comparison, noisy |

## 8. Sources

- Live API (all measurements): `https://openrouter.ai/api/v1/models`, `/models/xiaomi/mimo-v2.6-pro/endpoints`,
  `/chat/completions`, `/generation`, `/key`
- Local skill references: `/Users/minim1/.dsh/skills/openrouter-agent-skill/references/api.md` (§9–10),
  `routing.md` (§1 provider object), `errors.md` (§2, §6–7)
- OpenRouter docs: [Reasoning Tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens),
  [Provider Selection](https://openrouter.ai/docs/guides/routing/provider-selection),
  [Zero Completion Insurance](https://openrouter.ai/docs/guides/features/zero-completion-insurance),
  [Router Metadata](https://openrouter.ai/docs/guides/features/router-metadata)
- Raw artifacts: `/tmp/mimo-probe.json` (primary response), `/tmp/mimo-endpoints.json`, `/tmp/res-h.txt`
  (spoken stream), `/tmp/body-stream.json` (debug echo body)

### Reproduction

```bash
# model + pricing
zsh -l -c 'curl -s "https://openrouter.ai/api/v1/models?q=mimo" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" | jq ".data[] | select(.id==\"xiaomi/mimo-v2.6-pro\")"'

# providers
zsh -l -c 'curl -s "https://openrouter.ai/api/v1/models/xiaomi/mimo-v2.6-pro/endpoints" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" | jq ".data.endpoints[] | {tag, pricing, latency_last_30m, throughput_last_30m, uptime_last_1d}"'

# proof that effort is dropped: stream + debug echo, inspect reasoning in the echoed body
zsh -l -c 'curl -sN https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"xiaomi/mimo-v2.6-pro\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"reasoning\":{\"effort\":\"max\"},\"max_tokens\":50,\"stream\":true,\"debug\":{\"echo_upstream_body\":true}}" \
  | grep -o "\"reasoning\":{[^}]*}"'   # -> {"enabled": true}
```
