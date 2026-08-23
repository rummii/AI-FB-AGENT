from __future__ import annotations

import json
from dataclasses import dataclass
from urllib import error, parse, request


@dataclass(slots=True)
class FacebookGraphClient:
    page_id: str
    access_token: str
    api_version: str = "v23.0"

    def publish_post(self, message: str, link: str | None = None) -> dict:
        if not self.page_id or not self.access_token:
            raise RuntimeError("Facebook credentials are missing")

        endpoint = f"https://graph.facebook.com/{self.api_version}/{self.page_id}/feed"
        payload_data = {
            "message": message,
            "access_token": self.access_token,
        }
        if link:
            payload_data["link"] = link

        payload = parse.urlencode(payload_data).encode("utf-8")

        req = request.Request(endpoint, data=payload, method="POST")
        req.add_header("User-Agent", "ai-facebook-news-agent/1.0")
        try:
            with request.urlopen(req, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"Facebook publish failed: {exc.code} {details}") from exc
        except error.URLError as exc:
            raise RuntimeError(f"Facebook publish failed: {exc.reason}") from exc
