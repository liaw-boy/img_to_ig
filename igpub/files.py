"""Which files may be published: real JPEG files only, size-capped, no symlinks."""
import hashlib
from pathlib import Path

JPEG_SUFFIXES = {".jpg", ".jpeg"}
MAX_CAPTION = 2200


def check_file(path: Path, max_bytes: int) -> str | None:
    """None when the file is acceptable, otherwise the reason."""
    if path.suffix.lower() not in JPEG_SUFFIXES:
        return "not a .jpg / .jpeg file"
    if path.is_symlink():
        return "symbolic link"
    if not path.is_file():
        return "not a regular file"
    size = path.stat().st_size
    if size == 0:
        return "empty file"
    if size > max_bytes:
        return f"larger than {max_bytes // (1024 * 1024)} MB (options.max_bytes)"
    with open(path, "rb") as f:
        if f.read(3) != b"\xff\xd8\xff":
            return "not a JPEG (bad signature)"
    return None


def collect(paths: list[Path], max_bytes: int) -> "tuple[list[Path], list[tuple[Path, str]]]":
    """Expands folders (not recursive, hidden files ignored). Returns (accepted, [(path, reason)])."""
    found: list[Path] = []
    for p in paths:
        if p.is_dir() and not p.is_symlink():
            found += sorted(c for c in p.iterdir() if not c.name.startswith(".")
                            and c.suffix.lower() in JPEG_SUFFIXES)
        else:
            found.append(p)
    ok, bad = [], []
    for p in found:
        reason = check_file(p, max_bytes)
        (bad.append((p, reason)) if reason else ok.append(p))
    return ok, bad


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def caption_for(path: Path, explicit: str | None, default: str) -> str:
    """--caption wins, then <name>.txt next to the photo, then the config default."""
    if explicit is not None:
        text = explicit
    else:
        side = path.with_suffix(".txt")
        text = default
        if side.is_file() and not side.is_symlink() and side.stat().st_size <= 20_000:
            text = side.read_text(encoding="utf-8", errors="replace")
    text = text.strip()
    if len(text) > MAX_CAPTION:
        raise ValueError(f"caption of {path.name} is longer than {MAX_CAPTION} characters")
    return text
