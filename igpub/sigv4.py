"""AWS Signature V4 query-string presigning for S3-compatible storage (AWS S3, Cloudflare R2, MinIO ...).

Standard library only. Only what igpub needs: a presigned URL for GET / PUT / DELETE on one object.
"""
import hashlib
import hmac
from datetime import datetime, timezone
from urllib.parse import quote

_SAFE = "-_.~"


def _enc(value: str, safe: str = "") -> str:
    return quote(value, safe=safe + _SAFE)


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def presign(method: str, host: str, path: str, *, access_key: str, secret_key: str, region: str,
            expires: int = 900, now: datetime | None = None, service: str = "s3") -> str:
    """Returns an https URL that allows `method` on `path` of `host` for `expires` seconds."""
    if not path.startswith("/"):
        raise ValueError("path must start with /")
    if not 1 <= expires <= 604800:
        raise ValueError("expires must be 1..604800 seconds")
    now = now or datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    stamp = amz_date[:8]
    scope = f"{stamp}/{region}/{service}/aws4_request"
    params = {
        "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
        "X-Amz-Credential": f"{access_key}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": "host",
    }
    canonical_query = "&".join(f"{_enc(k)}={_enc(v)}" for k, v in sorted(params.items()))
    canonical_uri = _enc(path, safe="/")
    canonical_request = "\n".join([method, canonical_uri, canonical_query, f"host:{host}\n", "host",
                                   "UNSIGNED-PAYLOAD"])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()])
    key = _hmac(("AWS4" + secret_key).encode("utf-8"), stamp)
    for part in (region, service, "aws4_request"):
        key = _hmac(key, part)
    signature = hmac.new(key, to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"https://{host}{canonical_uri}?{canonical_query}&X-Amz-Signature={signature}"
