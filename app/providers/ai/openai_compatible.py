from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from typing import Any
from urllib import error, request

from app.models import Article

LOGGER = logging.getLogger("ai-facebook-news-agent")


def _extract_message(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") or []
    if not choices:
        raise ValueError("AI provider returned no choices")

    message = choices[0].get("message", {})
    content = message.get("content")
    if content is None:
        return ""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        text_parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                text_parts.append(item.strip())
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str) and text.strip():
                    text_parts.append(text.strip())
        return "\n".join(text_parts).strip()
    return str(content).strip()


@dataclass(slots=True)
class OpenAICompatibleClient:
    provider_name: str
    api_key: str
    model: str
    base_url: str

    def generate_post(self, article: Article, tone: str, max_chars: int) -> str:
        system_prompt = (
            "You write social posts for a Facebook page focused on AI news. "
            "Keep it informative, natural, and human. Avoid hype and emojis. "
            "Return only the final post body."
        )
        user_prompt = (
            f"Write a Facebook post about this AI news article in under {max_chars} characters.\n"
            f"Tone: {tone}.\n"
            "The post should: start with a strong one-line hook, summarize why it matters, "
            "and end with a light call to action.\n\n"
            f"Title: {article.title}\n"
            f"Source: {article.source}\n"
            f"Published: {article.published_at.isoformat() if article.published_at else 'unknown'}\n"
            f"Summary: {article.summary or 'No summary provided.'}\n"
            f"URL: {article.url}\n"
        )

        body: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.4,
        }
        # Groq's gpt-oss models reason heavily by default: one call can burn
        # ~7000 of the 8000 TPM dev-tier budget and occasionally return empty
        # content (reasoning eats the whole output). Curb that for short posts.
        if "groq.com" in self.base_url or self.provider_name == "groq":
            body["reasoning_effort"] = "low"
            body["include_reasoning"] = False
            body["max_completion_tokens"] = 600

        url = f"{self.base_url}/chat/completions"
        for attempt in range(3):
            payload = self._post(url, body)
            message = _extract_message(payload)
            if message:
                # Return the full body: PostGenerator owns all length policy so
                # that trimming is word-aware and never clips the URL.
                return message.strip()
        raise RuntimeError("AI provider returned an empty post")

    def _post(self, url: str, body: dict[str, Any]) -> dict[str, Any]:
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            # Without a real User-Agent, Python-urllib's default is blocked by
            # Cloudflare (Groq returns HTTP 403 error code 1010).
            "User-Agent": "ai-facebook-news-agent/1.0",
        }
        req = request.Request(
            url=url,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )

        transient_statuses = {429, 500, 502, 503, 504}
        max_attempts = 5
        for attempt in range(max_attempts):
            try:
                with request.urlopen(req, timeout=60) as response:
                    return json.loads(response.read().decode("utf-8"))
            except error.HTTPError as exc:
                details = exc.read().decode("utf-8", errors="ignore")
                if exc.code == 403:
                    # Cloudflare bot-block (error 1010): urllib is often blocked
                    # even with a UA. The server's curl binary passes, so retry
                    # the same request through curl as a fallback.
                    LOGGER.warning(
                        "AI provider blocked urllib (HTTP 403); retrying with curl: %s",
                        details[:160],
                    )
                    return self._curl_post(url, body)
                if exc.code not in transient_statuses or attempt == max_attempts - 1:
                    raise RuntimeError(f"AI request failed: {exc.code} {details}") from exc
                time.sleep(2**attempt)
            except error.URLError as exc:
                if attempt == max_attempts - 1:
                    raise RuntimeError(f"AI request failed: {exc.reason}") from exc
                time.sleep(2**attempt)

        raise RuntimeError("AI request failed without a response")

    def _curl_post(self, url: str, body: dict[str, Any]) -> dict[str, Any]:
        import shutil
        import subprocess

        curl = shutil.which("curl") or shutil.which("curl.exe")
        if not curl:
            raise RuntimeError("AI request failed: curl is not available on this server")

        cmd = [
            curl,
            "-sS",
            "--max-time", "60",
            "-X", "POST",
            url,
            "-H", f"Authorization: Bearer {self.api_key}",
            "-H", "Content-Type: application/json",
            "-H", "User-Agent: ai-facebook-news-agent/1.0",
            "--data", json.dumps(body),
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=70)
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("AI request failed: curl timed out") from exc

        if result.returncode != 0:
            raise RuntimeError(
                f"AI request failed: curl exited {result.returncode}: {result.stderr.strip()[:300]}"
            )

        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"AI request failed: curl returned unparseable JSON: {result.stdout[:300]}"
            ) from exc