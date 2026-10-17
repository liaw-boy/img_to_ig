"""Instagram Content Publishing API: container -> (wait) -> publish."""
import json
import time
from typing import Callable
from urllib.parse import urlencode

from .config import Config
from .net import Http
from .secrets import redact


class InstagramError(Exception):
    pass


class Client:
    def __init__(self, cfg: Config, token: str, http: Http, sleep: Callable[[float], None] = time.sleep):
        self.cfg, self.token, self.http, self.sleep = cfg, token, http, sleep

    def _url(self, path: str) -> str:
        v = f"{self.cfg.api_version}/" if self.cfg.api_version else ""
        return f"https://{self.cfg.api_host}/{v}{path}"

    def _call(self, method: str, path: str, params: dict | None = None) -> dict:
        params = dict(params or {})
        params["access_token"] = self.token
        body = urlencode(params)
        status = 0
        try:
            if method == "GET":
                status, raw = self.http("GET", self._url(path) + "?" + body)
            else:
                status, raw = self.http(method, self._url(path), data=body.encode(),
                                        headers={"Content-Type": "application/x-www-form-urlencoded"})
            payload = json.loads(raw.decode("utf-8", "replace") or "{}")
        except ValueError:
            raise InstagramError(f"unexpected response from Instagram (HTTP {status})") from None
        except Exception as e:
            raise InstagramError(redact(f"request failed: {e}", self.token)) from None
        if status >= 400 or "error" in payload:
            err = payload.get("error", {}) if isinstance(payload, dict) else {}
            msg = redact(str(err.get("message", "request rejected")), self.token)
            raise InstagramError(f"Instagram error {err.get('code', status)}: {msg}")
        return payload

    def account(self) -> dict:
        return self._call("GET", self.cfg.ig_user_id, {"fields": "username"})

    def publishing_limit(self) -> dict:
        return self._call("GET", f"{self.cfg.ig_user_id}/content_publishing_limit",
                          {"fields": "quota_usage,config"})

    def create_container(self, image_url: str, caption: str = "", carousel_item: bool = False) -> str:
        params = {"image_url": image_url}
        if carousel_item:
            params["is_carousel_item"] = "true"
        elif caption:
            params["caption"] = caption
        return str(self._call("POST", f"{self.cfg.ig_user_id}/media", params)["id"])

    def create_carousel(self, children: list[str], caption: str = "") -> str:
        params = {"media_type": "CAROUSEL", "children": ",".join(children)}
        if caption:
            params["caption"] = caption
        return str(self._call("POST", f"{self.cfg.ig_user_id}/media", params)["id"])

    def wait_finished(self, container_id: str) -> None:
        """Polls the container (the docs suggest once a minute, at most five minutes)."""
        for attempt in range(self.cfg.poll_tries):
            status = self._call("GET", container_id, {"fields": "status_code"}).get("status_code")
            if status in ("FINISHED", "PUBLISHED"):
                return
            if status in ("ERROR", "EXPIRED"):
                raise InstagramError(f"container {status}")
            if attempt + 1 < self.cfg.poll_tries:
                self.sleep(self.cfg.poll_seconds)
        raise InstagramError("container was not ready in time")

    def publish(self, container_id: str) -> str:
        return str(self._call("POST", f"{self.cfg.ig_user_id}/media_publish",
                              {"creation_id": container_id})["id"])
