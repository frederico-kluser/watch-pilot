"""OpenRouter client — Xiaomi MiMo 2.6 Pro with reasoning forced to ``max``.

The hub is the only component that talks to the internet: the watch sends audio to
the Mac mini over the LAN/tunnel, the Mac mini transcribes on-device and calls
OpenRouter for the reasoning step.

Request shape (verified against the live API):

* ``model``: ``xiaomi/mimo-v2.6-pro`` (fallbacks in ``models``).
* ``reasoning: {"effort": "max"}`` — the enum accepts ``max`` and is the highest
  thinking budget available.
* ``usage.completion_tokens_details.reasoning_tokens`` carries the thinking tokens,
  which are billed as output.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field

import httpx

from .config import settings

RETRYABLE = {408, 429, 500, 502, 503, 504}


@dataclass
class LlmResult:
    text: str
    model: str
    elapsed_ms: int
    reasoning_tokens: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cost_usd: float = 0.0
    reasoning_excerpt: str = ""
    attempts: list[dict[str, object]] = field(default_factory=list)
    error: str = ""

    @property
    def ok(self) -> bool:
        return bool(self.text.strip())


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {settings.openrouter_api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": settings.public_base_url,
        "X-OpenRouter-Title": "Watch Pilot",
        "X-OpenRouter-Categories": "personal-assistant",
    }


def _payload(prompt: str, model: str) -> dict[str, object]:
    return {
        "model": model,
        "models": [model, *[m for m in settings.model_fallbacks if m != model]],
        "messages": [
            {"role": "system", "content": settings.system_prompt},
            {"role": "user", "content": prompt},
        ],
        # `effort` is validated by OpenRouter but collapsed to a boolean before it
        # reaches the provider, so depth is also demanded in the system prompt.
        "reasoning": {"effort": settings.reasoning_effort},
        "include_reasoning": settings.include_reasoning,
        "temperature": settings.llm_temperature,
        "max_tokens": settings.max_tokens,
        # Verified live (Q5 research): DeepInfra is cheapest AND has the lowest p50
        # latency with 100% uptime; StreamLake has ~9% uptime and must be avoided.
        # `latency_last_30m` is milliseconds while `preferred_max_latency` is seconds.
        "provider": {
            "order": ["deepinfra/fp8", "xiaomi/fp8", "novita/fp8"],
            "allow_fallbacks": True,
            "quantizations": ["fp8"],
            "preferred_max_latency": {"p50": 5, "p90": 15},
            "preferred_min_throughput": {"p50": 15},
            "require_parameters": False,
        },
        "usage": {"include": True},
    }


def _extract_reasoning(message: dict[str, object]) -> str:
    details = message.get("reasoning_details")
    if isinstance(details, list) and details:
        chunks = []
        for item in details:
            if isinstance(item, dict) and item.get("text"):
                chunks.append(str(item["text"]))
        if chunks:
            return "\n".join(chunks)
    if isinstance(message.get("reasoning"), str):
        return str(message["reasoning"])
    return ""


async def complete(prompt: str) -> LlmResult:
    """Run one reasoning completion, with backoff on transient failures."""
    started = time.perf_counter()
    attempts: list[dict[str, object]] = []
    if not settings.openrouter_api_key:
        return LlmResult(
            text="",
            model=settings.model,
            elapsed_ms=0,
            error="missing OPENROUTER_API_KEY",
            attempts=[{"status": "no-credentials"}],
        )

    url = f"{settings.openrouter_base_url}/chat/completions"
    delay = 1.0
    last_error = ""
    async with httpx.AsyncClient(http2=True, timeout=settings.llm_timeout_seconds) as client:
        for attempt in range(1, 4):
            try:
                response = await client.post(url, headers=_headers(), json=_payload(prompt, settings.model))
            except httpx.HTTPError as exc:
                last_error = f"transport: {exc!r}"
                attempts.append({"attempt": attempt, "status": "transport-error", "detail": last_error[:200]})
            else:
                body: dict[str, object] = {}
                try:
                    body = response.json()
                except ValueError:
                    body = {}
                if response.status_code == 200:
                    choice = (body.get("choices") or [{}])[0] if isinstance(body, dict) else {}
                    message = choice.get("message", {}) if isinstance(choice, dict) else {}
                    content = message.get("content") or ""
                    if isinstance(content, list):
                        content = "".join(
                            part.get("text", "")
                            for part in content
                            if isinstance(part, dict) and part.get("type") == "text"
                        )
                    usage = body.get("usage", {}) if isinstance(body, dict) else {}
                    details = usage.get("completion_tokens_details") or {}
                    reasoning = _extract_reasoning(message)
                    attempts.append({"attempt": attempt, "status": 200, "model": body.get("model")})
                    return LlmResult(
                        text=str(content).strip(),
                        model=str(body.get("model") or settings.model),
                        elapsed_ms=int((time.perf_counter() - started) * 1000),
                        reasoning_tokens=int(details.get("reasoning_tokens") or 0),
                        prompt_tokens=int(usage.get("prompt_tokens") or 0),
                        completion_tokens=int(usage.get("completion_tokens") or 0),
                        cost_usd=float(usage.get("cost") or 0.0),
                        reasoning_excerpt=reasoning[:4000],
                        attempts=attempts,
                    )
                last_error = f"HTTP {response.status_code}: {str(body.get('error') or body)[:300]}"
                attempts.append({"attempt": attempt, "status": response.status_code, "detail": last_error[:300]})
                if response.status_code not in RETRYABLE:
                    break
                retry_after = response.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    delay = max(delay, float(retry_after))
            await asyncio.sleep(delay)
            delay *= 2

    return LlmResult(
        text="",
        model=settings.model,
        elapsed_ms=int((time.perf_counter() - started) * 1000),
        error=last_error,
        attempts=attempts,
    )
