from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any
from urllib import error, request

from app.models import Article


def _extract_message(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") or []
    if not choices:
        raise ValueError("AI provider returned no choices")

    message = choices[0].get("message", {})
    content = message.get("content", "")
    if isinstance(content, list):
        text_parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text_parts.append(item.get("text", ""))
        return "\n".join(part for part in text_parts if part).strip()
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

        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.4,
        }

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        if self.provider_name == "openrouter":
            headers["X-Title"] = "AI Facebook News Agent"

        req = request.Request(
            url=f"{self.base_url}/chat/completions",
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )

        try:
            with request.urlopen(req, timeout=60) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"AI request failed: {exc.code} {details}") from exc
        except error.URLError as exc:
            raise RuntimeError(f"AI request failed: {exc.reason}") from exc

        message = _extract_message(payload)
        if not message:
            raise RuntimeError("AI provider returned an empty post")
        return message[:max_chars].strip()