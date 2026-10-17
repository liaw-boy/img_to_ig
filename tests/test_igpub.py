import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from igpub import cli, config, files, sigv4
from igpub.instagram import Client, InstagramError
from igpub.state import Ledger

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


def cfg_dict(**over):
    d = {"instagram": {"user_id": "17841400000000000"},
         "storage": {"endpoint": "https://acc.r2.cloudflarestorage.com", "region": "auto", "bucket": "my-bucket"},
         "options": {}}
    for k, v in over.items():
        d[k].update(v)
    return d


class SigV4Test(unittest.TestCase):
    def test_aws_documentation_example(self):
        url = sigv4.presign("GET", "examplebucket.s3.amazonaws.com", "/test.txt",
                            access_key="AKIAIOSFODNN7EXAMPLE", secret_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                            region="us-east-1", expires=86400,
                            now=datetime(2013, 5, 24, tzinfo=timezone.utc))
        self.assertTrue(url.endswith("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))

    def test_rejects_bad_arguments(self):
        with self.assertRaises(ValueError):
            sigv4.presign("GET", "h", "no-slash", access_key="a", secret_key="b", region="r")
        with self.assertRaises(ValueError):
            sigv4.presign("GET", "h", "/x", access_key="a", secret_key="b", region="r", expires=0)


class ConfigTest(unittest.TestCase):
    def test_valid(self):
        c = config.parse(cfg_dict())
        self.assertEqual(c.api_host, "graph.instagram.com")
        self.assertEqual(c.storage.prefix, "igpub/")

    def test_rejects(self):
        bad = [cfg_dict(instagram={"user_id": "abc"}),
               cfg_dict(instagram={"api_host": "evil.example.com"}),
               cfg_dict(instagram={"api_version": "latest"}),
               cfg_dict(storage={"endpoint": "http://acc.example.com"}),
               cfg_dict(storage={"endpoint": "https://user:pw@acc.example.com"}),
               cfg_dict(storage={"prefix": "../x/"}),
               cfg_dict(storage={"bucket": "Bad Bucket"}),
               cfg_dict(options={"max_per_run": 500})]
        for d in bad:
            with self.assertRaises(config.ConfigError, msg=str(d)):
                config.parse(d)


class FilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_checks(self):
        (self.tmp / "a.jpg").write_bytes(JPEG)
        (self.tmp / "b.png").write_bytes(JPEG)
        (self.tmp / "c.jpg").write_bytes(b"not a jpeg")
        (self.tmp / "d.jpg").write_bytes(JPEG + b"0" * 5000)
        (self.tmp / "e.jpg").symlink_to(self.tmp / "a.jpg")
        (self.tmp / ".hidden.jpg").write_bytes(JPEG)
        ok, bad = files.collect([self.tmp], max_bytes=2048)
        self.assertEqual([p.name for p in ok], ["a.jpg"])
        self.assertEqual({p.name for p, _ in bad}, {"c.jpg", "d.jpg", "e.jpg"})

    def test_caption_order(self):
        p = self.tmp / "a.jpg"
        p.write_bytes(JPEG)
        self.assertEqual(files.caption_for(p, None, "default"), "default")
        p.with_suffix(".txt").write_text("side", encoding="utf-8")
        self.assertEqual(files.caption_for(p, None, "default"), "side")
        self.assertEqual(files.caption_for(p, "cli", "default"), "cli")
        with self.assertRaises(ValueError):
            files.caption_for(p, "x" * 2201, "")


class LedgerTest(unittest.TestCase):
    def test_roundtrip_and_permissions(self):
        path = Path(tempfile.mkdtemp()) / "sub" / "p.json"
        led = Ledger(path)
        self.assertFalse(led.has("abc"))
        led.add("abc", "123", "a.jpg")
        self.assertTrue(Ledger(path).has("abc"))
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")

    def test_corrupt_file_is_ignored(self):
        path = Path(tempfile.mkdtemp()) / "p.json"
        path.write_text("{not json")
        self.assertFalse(Ledger(path).has("x"))


class FakeHttp:
    """Records requests and answers from a script of (status, payload)."""

    def __init__(self, answers):
        self.answers, self.calls = list(answers), []

    def __call__(self, method, url, data=None, headers=None, timeout=60):
        self.calls.append((method, url, data))
        status, payload = self.answers.pop(0)
        return status, payload if isinstance(payload, bytes) else json.dumps(payload).encode()


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.cfg = config.parse(cfg_dict(options={}))

    def test_single_photo_sequence(self):
        h = FakeHttp([(200, {"id": "C1"}), (200, {"status_code": "IN_PROGRESS"}),
                      (200, {"status_code": "FINISHED"}), (200, {"id": "M1"})])
        sleeps = []
        c = Client(self.cfg, "TOKEN123456", h, sleep=sleeps.append)
        cid = c.create_container("https://x/y.jpg", "hello")
        c.wait_finished(cid)
        self.assertEqual(c.publish(cid), "M1")
        self.assertEqual(sleeps, [60])
        method, url, data = h.calls[0]
        self.assertEqual(method, "POST")
        self.assertIn("/17841400000000000/media", url)
        self.assertIn(b"image_url=https%3A%2F%2Fx%2Fy.jpg", data)
        self.assertIn(b"caption=hello", data)
        self.assertNotIn("TOKEN123456", url)           # the token travels in the body of a POST

    def test_error_is_reported_without_token(self):
        h = FakeHttp([(400, {"error": {"message": "bad TOKEN123456 value", "code": 190}})])
        with self.assertRaises(InstagramError) as cm:
            Client(self.cfg, "TOKEN123456", h).account()
        self.assertNotIn("TOKEN123456", str(cm.exception))
        self.assertIn("190", str(cm.exception))

    def test_container_error_and_timeout(self):
        h = FakeHttp([(200, {"status_code": "ERROR"})])
        with self.assertRaises(InstagramError):
            Client(self.cfg, "TOKEN123456", h).wait_finished("C1")
        h = FakeHttp([(200, {"status_code": "IN_PROGRESS"})] * self.cfg.poll_tries)
        with self.assertRaises(InstagramError):
            Client(self.cfg, "TOKEN123456", h, sleep=lambda s: None).wait_finished("C1")

    def test_non_json_response(self):
        with self.assertRaises(InstagramError):
            Client(self.cfg, "TOKEN123456", FakeHttp([(502, b"<html>")])).account()


class CliTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.photo = self.dir / "a.jpg"
        self.photo.write_bytes(JPEG)
        self.conf = self.dir / "config.toml"
        self.conf.write_text('[instagram]\nuser_id = "17841400000000000"\n'
                             '[storage]\nendpoint = "https://acc.r2.cloudflarestorage.com"\n'
                             'region = "auto"\nbucket = "my-bucket"\n', encoding="utf-8")
        self.state = self.dir / "state.json"
        self.env = mock.patch.dict(os.environ, {"IGPUB_ACCESS_TOKEN": "TOKEN123456",
                                                "IGPUB_S3_ACCESS_KEY": "AK", "IGPUB_S3_SECRET_KEY": "SK"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.state_patch = mock.patch.object(cli, "DEFAULT_STATE", self.state)
        self.state_patch.start()
        self.addCleanup(self.state_patch.stop)

    def run_cli(self, *argv):
        return cli.main(["--config", str(self.conf), *argv])

    def test_dry_run_touches_nothing(self):
        with mock.patch.object(cli, "http", side_effect=AssertionError("network")):
            self.assertEqual(self.run_cli("publish", str(self.photo), "--dry-run"), 0)
        self.assertFalse(self.state.exists())

    def test_publish_and_no_duplicates(self):
        fake = FakeHttp([(200, b""),                         # PUT upload
                         (200, {"id": "C1"}), (200, {"status_code": "FINISHED"}), (200, {"id": "M1"}),
                         (204, b"")])                        # DELETE
        with mock.patch.object(cli, "http", fake):
            self.assertEqual(self.run_cli("publish", str(self.photo), "--caption", "hi"), 0)
        methods = [c[0] for c in fake.calls]
        self.assertEqual(methods, ["PUT", "POST", "GET", "POST", "DELETE"])
        self.assertTrue(fake.calls[0][1].startswith("https://acc.r2.cloudflarestorage.com/my-bucket/igpub/"))
        self.assertIn("M1", self.state.read_text())
        with mock.patch.object(cli, "http", side_effect=AssertionError("network")):
            self.assertEqual(self.run_cli("publish", str(self.photo)), 0)    # already published: no calls

    def test_failure_cleans_up_object(self):
        fake = FakeHttp([(200, b""), (400, {"error": {"message": "nope", "code": 100}}), (204, b"")])
        with mock.patch.object(cli, "http", fake):
            self.assertEqual(self.run_cli("publish", str(self.photo)), 1)
        self.assertEqual([c[0] for c in fake.calls][-1], "DELETE")
        self.assertFalse(self.state.exists())

    def test_missing_secret(self):
        with mock.patch.dict(os.environ, {"IGPUB_ACCESS_TOKEN": ""}), \
                mock.patch("igpub.secrets._keychain", return_value=None):
            self.assertEqual(self.run_cli("check"), 1)

    def test_carousel_needs_two_photos(self):
        self.assertEqual(self.run_cli("publish", str(self.photo), "--carousel", "--dry-run"), 2)


if __name__ == "__main__":
    unittest.main()


class LegacyMigrationTest(unittest.TestCase):
    def test_state_moves_from_old_location(self):
        with tempfile.TemporaryDirectory() as d:
            old, new = Path(d) / "old" / "p.json", Path(d) / "new" / "p.json"
            old.parent.mkdir()
            old.write_text('{"published": {"abc": {"media_id": "1", "file": "a.jpg", "at": "x"}}}')
            cli.migrate_legacy_state(old, new)
            self.assertTrue(Ledger(new).has("abc"))
            self.assertFalse(old.exists())
            self.assertEqual(new.stat().st_mode & 0o777, 0o600)

    def test_state_keeps_existing_new_file(self):
        with tempfile.TemporaryDirectory() as d:
            old, new = Path(d) / "old.json", Path(d) / "new.json"
            old.write_text('{"published": {"old": {}}}')
            new.write_text('{"published": {"new": {}}}')
            cli.migrate_legacy_state(old, new)
            self.assertTrue(Ledger(new).has("new"))
            self.assertTrue(old.exists())

    def test_keychain_falls_back_to_legacy_service(self):
        from igpub import secrets
        calls = []

        def fake(service, account):
            calls.append(service)
            return "tok" if service == "igpub" else None
        secrets._bundle = None
        with mock.patch("igpub.secrets._lookup", side_effect=fake):
            self.assertEqual(secrets._keychain("access_token"), "tok")
        secrets._bundle = None
        self.assertEqual(calls, ["img_to_ig", "img_to_ig", "igpub"])   # bundle, single item, legacy item

    def test_keychain_reads_bundle_once(self):
        from igpub import secrets
        secrets._bundle = None
        calls = []

        def fake(service, account):
            calls.append((service, account))
            return '{"access_token": "t", "s3_access_key": "a"}' if account == "bundle" else None
        try:
            with mock.patch("igpub.secrets._lookup", side_effect=fake):
                self.assertEqual(secrets._keychain("access_token"), "t")
                self.assertEqual(secrets._keychain("s3_access_key"), "a")
            self.assertEqual(calls, [("img_to_ig", "bundle")])
        finally:
            secrets._bundle = None
