"""Secrets come from environment variables or the macOS Keychain - never from the config file or git."""
import json
import os
import subprocess

SERVICE = "img_to_ig"
LEGACY_SERVICE = "igpub"  # older installs; read-only fallback


class MissingSecret(Exception):
    pass


_bundle: dict | None = None


def _read_bundle() -> dict:
    """The App stores all secrets as one JSON item (account "bundle"); read it once per run."""
    global _bundle
    if _bundle is None:
        _bundle = {}
        raw = _lookup(SERVICE, "bundle")
        if raw:
            try:
                data = json.loads(raw)
                if isinstance(data, dict):
                    _bundle = {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}
            except ValueError:
                pass
    return _bundle


def _keychain(account: str) -> str | None:
    """Bundle first, then single items (CLI-made or older installs)."""
    return _read_bundle().get(account) or _lookup(SERVICE, account) or _lookup(LEGACY_SERVICE, account)


def _lookup(service: str, account: str) -> str | None:
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                             capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    value = out.stdout.strip()
    return value if out.returncode == 0 and value else None


def get(name: str, env: str) -> str:
    """Looks in the environment (`env`), then in the Keychain (service img_to_ig, account `name`)."""
    value = os.environ.get(env, "").strip() or _keychain(name)
    if not value:
        raise MissingSecret(f"missing secret '{name}': set {env} or add it to the Keychain "
                            f"(security add-generic-password -s {SERVICE} -a {name} -w)")
    return value


def redact(text: str, *secrets: str) -> str:
    for s in secrets:
        if s and len(s) >= 6:
            text = text.replace(s, "***")
    return text
