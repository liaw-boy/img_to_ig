"""Temporary public URL for a photo: upload to an S3-compatible bucket, hand Instagram a short-lived signed GET
URL, delete the object afterwards."""
import uuid
from pathlib import Path
from urllib.parse import urlparse

from . import sigv4
from .config import Storage
from .net import Http


class StorageError(Exception):
    pass


class TempStorage:
    def __init__(self, cfg: Storage, access_key: str, secret_key: str, http: Http):
        self.cfg = cfg
        self.access, self.secret = access_key, secret_key
        self.http = http
        self.host = urlparse(cfg.endpoint).netloc

    def _url(self, method: str, key: str) -> str:
        return sigv4.presign(method, self.host, f"/{self.cfg.bucket}/{key}", access_key=self.access,
                             secret_key=self.secret, region=self.cfg.region, expires=self.cfg.url_expiry)

    def new_key(self) -> str:
        return f"{self.cfg.prefix}{uuid.uuid4().hex}.jpg"       # random: the file name is not exposed

    def upload(self, path: Path) -> "tuple[str, str]":
        """Returns (key, signed GET url)."""
        key = self.new_key()
        status, _ = self.http("PUT", self._url("PUT", key), data=path.read_bytes(),
                              headers={"Content-Type": "image/jpeg"})
        if status not in (200, 201, 204):
            raise StorageError(f"upload failed (HTTP {status})")
        return key, self._url("GET", key)

    def delete(self, key: str) -> None:
        try:
            self.http("DELETE", self._url("DELETE", key))
        except Exception:                                        # cleanup must not hide the real result
            pass
