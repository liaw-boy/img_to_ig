"""Ledger of what has been published (by file hash), so a photo is never posted twice."""
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


class Ledger:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict = {"published": {}}
        try:
            if path.stat().st_size <= 5_000_000:
                loaded = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict) and isinstance(loaded.get("published"), dict):
                    self.data = loaded
        except (OSError, ValueError):
            pass

    def has(self, digest: str) -> bool:
        return digest in self.data["published"]

    def add(self, digest: str, media_id: str, name: str) -> None:
        self.data["published"][digest] = {
            "media_id": media_id, "file": name,
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        self._save()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".ledger-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self.data, f, ensure_ascii=False, indent=1)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
