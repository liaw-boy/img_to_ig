"""config.toml: ids and endpoints only. Tokens and keys never live here (see secrets.py)."""
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

API_HOSTS = {"graph.instagram.com", "graph.facebook.com"}


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Storage:
    endpoint: str            # https://<account>.r2.cloudflarestorage.com  or  https://s3.<region>.amazonaws.com
    region: str              # "auto" for Cloudflare R2
    bucket: str
    prefix: str = "igpub/"
    url_expiry: int = 900    # seconds a signed URL lives


@dataclass(frozen=True)
class Config:
    ig_user_id: str
    storage: Storage
    api_host: str = "graph.instagram.com"
    api_version: str = ""    # "" = unversioned calls; set e.g. "v23.0" to pin
    default_caption: str = ""
    max_per_run: int = 10
    max_bytes: int = 8 * 1024 * 1024
    poll_seconds: int = 60
    poll_tries: int = 5

    @property
    def endpoint_host(self) -> str:
        return urlparse(self.storage.endpoint).netloc


def _need(table: dict, key: str, kind: type, where: str):
    value = table.get(key)
    if not isinstance(value, kind) or (kind is str and not value.strip()):
        raise ConfigError(f"{where}.{key} is required and must be {kind.__name__}")
    return value


def parse(data: dict) -> Config:
    ig = data.get("instagram", {})
    st = data.get("storage", {})
    opt = data.get("options", {})
    user_id = str(_need(ig, "user_id", str, "instagram"))
    if not re.fullmatch(r"\d{5,25}", user_id):
        raise ConfigError("instagram.user_id must be the numeric Instagram user id")
    host = ig.get("api_host", "graph.instagram.com")
    if host not in API_HOSTS:
        raise ConfigError(f"instagram.api_host must be one of {sorted(API_HOSTS)}")
    version = ig.get("api_version", "")
    if version and not re.fullmatch(r"v\d{1,2}\.\d", version):
        raise ConfigError("instagram.api_version must look like v23.0")

    endpoint = _need(st, "endpoint", str, "storage")
    u = urlparse(endpoint)
    if u.scheme != "https" or not u.netloc or u.path not in ("", "/") or u.username or u.query:
        raise ConfigError("storage.endpoint must be a plain https://host URL")
    bucket = _need(st, "bucket", str, "storage")
    if not re.fullmatch(r"[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]", bucket):
        raise ConfigError("storage.bucket has an invalid name")
    prefix = st.get("prefix", "igpub/")
    if not re.fullmatch(r"[A-Za-z0-9_\-/]{0,60}", prefix) or ".." in prefix or prefix.startswith("/"):
        raise ConfigError("storage.prefix may contain letters, digits, _ - / only")
    region = _need(st, "region", str, "storage")
    if not re.fullmatch(r"[a-z0-9\-]{2,30}", region):
        raise ConfigError("storage.region has an invalid name")
    expiry = int(st.get("url_expiry", 900))
    if not 60 <= expiry <= 3600:
        raise ConfigError("storage.url_expiry must be 60..3600")

    caption = str(opt.get("default_caption", ""))
    if len(caption) > 2200:
        raise ConfigError("options.default_caption is longer than Instagram's 2200 characters")
    per_run = int(opt.get("max_per_run", 10))
    if not 1 <= per_run <= 25:
        raise ConfigError("options.max_per_run must be 1..25")
    max_bytes = int(opt.get("max_bytes", 8 * 1024 * 1024))
    if not 1024 <= max_bytes <= 100 * 1024 * 1024:
        raise ConfigError("options.max_bytes is out of range")
    return Config(ig_user_id=user_id, api_host=host, api_version=version,
                  storage=Storage(endpoint=endpoint.rstrip("/"), region=region, bucket=bucket, prefix=prefix,
                                  url_expiry=expiry),
                  default_caption=caption, max_per_run=per_run, max_bytes=max_bytes)


def load(path: Path) -> Config:
    try:
        with open(path, "rb") as f:
            return parse(tomllib.load(f))
    except FileNotFoundError:
        raise ConfigError(f"config file not found: {path} (copy config.example.toml)") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"config file is not valid TOML: {e}") from None
