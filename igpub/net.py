"""One small HTTPS client (standard library). Tests replace it with a fake."""
import urllib.error
import urllib.request
from typing import Callable

# http(method, url, data=None, headers=None) -> (status, body bytes)
Http = Callable[..., "tuple[int, bytes]"]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):      # a redirect would leak a signed URL / token elsewhere
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def http(method: str, url: str, data: bytes | None = None, headers: dict | None = None,
         timeout: int = 60) -> "tuple[int, bytes]":
    if not url.lower().startswith("https://"):
        raise ValueError("only https URLs are allowed")
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with _opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read(5_000_000)
    except urllib.error.HTTPError as e:
        return e.code, e.read(5_000_000)
