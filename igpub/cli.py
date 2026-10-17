import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

from . import __version__, files, secrets
from .config import Config, ConfigError, load
from .instagram import Client, InstagramError
from .net import http
from .state import Ledger
from .storage import StorageError, TempStorage

DEFAULT_CONFIG = Path(os.environ.get("IGPUB_CONFIG", "config.toml"))
LEGACY_STATE = Path("~/.igpub/published.json").expanduser()
DEFAULT_STATE = Path(os.environ.get("IGPUB_STATE", "~/.img_to_ig/published.json")).expanduser()


def migrate_legacy_state(old: Path, new: Path) -> None:
    """One-time move from the old ledger location: atomic copy (temp file + rename), then remove the old file."""
    if new.exists() or new.is_symlink() or not old.is_file() or old.is_symlink():
        return
    tmp = None
    try:
        new.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(new.parent, 0o700)
        fd, tmp = tempfile.mkstemp(dir=new.parent, prefix=".ledger-")   # O_EXCL, mode 0600
        with os.fdopen(fd, "wb") as f, open(old, "rb") as src:
            shutil.copyfileobj(src, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, new)
        tmp = None
        old.unlink()
    except OSError:
        pass
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _client(cfg: Config) -> Client:
    return Client(cfg, secrets.get("access_token", "IGPUB_ACCESS_TOKEN"), http)


def _storage(cfg: Config) -> TempStorage:
    return TempStorage(cfg.storage, secrets.get("s3_access_key", "IGPUB_S3_ACCESS_KEY"),
                       secrets.get("s3_secret_key", "IGPUB_S3_SECRET_KEY"), http)


def cmd_check(args, cfg: Config) -> int:
    ig = _client(cfg)
    _storage(cfg)                                   # only checks that the keys exist
    acc = ig.account()
    print(f"OK  Instagram account: @{acc.get('username', '?')} ({cfg.ig_user_id})")
    try:
        lim = ig.publishing_limit().get("data", [{}])[0]
        print(f"    publishing quota used: {lim.get('quota_usage', '?')} "
              f"of {lim.get('config', {}).get('quota_total', '?')} in the last 24 h")
    except (InstagramError, IndexError, AttributeError):
        print("    (publishing quota not available)")
    print("OK  storage keys present; the bucket itself is exercised by the first publish")
    return 0


def _plan(args, cfg: Config, ledger: Ledger):
    paths = [Path(p).expanduser() for p in args.paths]
    ok, bad = files.collect(paths, cfg.max_bytes)
    for p, why in bad:
        print(f"skip  {p.name}: {why}")
    todo = []
    for p in ok:
        digest = files.sha256(p)
        if ledger.has(digest) and not args.again:
            print(f"skip  {p.name}: already published")
            continue
        todo.append((p, digest))
    return todo


def cmd_publish(args, cfg: Config) -> int:
    if "IGPUB_STATE" not in os.environ:
        migrate_legacy_state(LEGACY_STATE, DEFAULT_STATE)
    ledger = Ledger(DEFAULT_STATE)
    todo = _plan(args, cfg, ledger)
    if args.carousel:
        if not 2 <= len(todo) <= 10:
            print(f"a carousel needs 2 to 10 photos, got {len(todo)}", file=sys.stderr)
            return 2
    else:
        todo = todo[:cfg.max_per_run]
    if not todo:
        print("nothing to publish")
        return 0

    try:
        captions = [files.caption_for(p, args.caption, cfg.default_caption) for p, _ in todo]
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.dry_run:
        kind = "carousel" if args.carousel else "single posts"
        print(f"dry run: {len(todo)} photo(s) as {kind}")
        for (p, _), c in zip(todo, captions):
            print(f"  {p.name}  caption: {c[:60]!r}{'...' if len(c) > 60 else ''}")
        return 0

    ig, store = _client(cfg), _storage(cfg)
    keys: list[str] = []
    try:
        if args.carousel:
            children = []
            for p, _ in todo:
                key, url = store.upload(p)
                keys.append(key)
                cid = ig.create_container(url, carousel_item=True)
                ig.wait_finished(cid)
                children.append(cid)
            parent = ig.create_carousel(children, captions[0])
            ig.wait_finished(parent)
            media = ig.publish(parent)
            for _, digest in todo:
                ledger.add(digest, media, "carousel")
            print(f"published carousel of {len(todo)}: media id {media}")
        else:
            for (p, digest), caption in zip(todo, captions):
                key, url = store.upload(p)
                keys.append(key)
                cid = ig.create_container(url, caption)
                ig.wait_finished(cid)
                media = ig.publish(cid)
                ledger.add(digest, media, p.name)
                print(f"published {p.name}: media id {media}")
                store.delete(key)
                keys.remove(key)
    except (InstagramError, StorageError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    finally:
        for key in keys:
            store.delete(key)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="igpub", description=__doc__ or "Publish JPEGs to Instagram.")
    ap.add_argument("--version", action="version", version=__version__)
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="validate config, token and keys; show the account and quota")
    pub = sub.add_parser("publish", help="publish JPEG files / folders")
    pub.add_argument("paths", nargs="+")
    pub.add_argument("--caption", help="caption for every post (otherwise <name>.txt, then the config default)")
    pub.add_argument("--carousel", action="store_true", help="one carousel post of 2-10 photos")
    pub.add_argument("--dry-run", action="store_true", help="show what would be published, change nothing")
    pub.add_argument("--again", action="store_true", help="publish even if the same file was published before")
    args = ap.parse_args(argv)
    try:
        cfg = load(args.config.expanduser())
        return {"check": cmd_check, "publish": cmd_publish}[args.cmd](args, cfg)
    except (ConfigError, secrets.MissingSecret, InstagramError, StorageError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
