"""Exercise setup in disposable directories without touching a Docker daemon."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class SetupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="gitlab-cert-fixture-")
        cls.fixture_path = Path(cls.fixture.name)
        cls.addClassCleanup(cls.fixture.cleanup)
        for name in ("setup.sh", "docker-compose.yml", ".env"):
            shutil.copy2(REPO / name, cls.fixture_path / name)
        (cls.fixture_path / ".env").write_text("hostname=gitlab.local\n")
        env = os.environ.copy()
        env.pop("hostname", None)
        result = subprocess.run(
            ["bash", str(cls.fixture_path / "setup.sh")],
            cwd="/tmp", env=env, capture_output=True, text=True,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="gitlab-setup-test-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        shutil.copytree(self.fixture_path, self.root, dirs_exist_ok=True)
        self.env = os.environ.copy()
        self.env.pop("hostname", None)
        self.key = self.root / ".volumes/ssl/gitlab.local.key"
        self.cert = self.root / ".volumes/ssl/gitlab.local.crt"

    def run_setup(self, *args, ok=True):
        result = subprocess.run(
            ["bash", str(self.root / "setup.sh"), *args], cwd="/tmp",
            env=self.env, capture_output=True, text=True,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def issue_certificate(self, *, san=True, days=3650):
        command = [
            "openssl", "req", "-x509", "-nodes", "-days", str(days),
            "-key", str(self.key), "-out", str(self.cert), "-subj", "/CN=gitlab.local",
        ]
        if san:
            command += ["-addext", "subjectAltName=DNS:gitlab.local"]
        subprocess.run(command, capture_output=True, check=True)

    def test_generated_certificate_and_safe_rerun_from_other_directory(self):
        key_before, cert_before = self.key.read_bytes(), self.cert.read_bytes()
        self.run_setup()
        self.assertEqual(self.key.read_bytes(), key_before)
        self.assertEqual(self.cert.read_bytes(), cert_before)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        runner = self.root / ".volumes/gitlab-runner/certs"
        self.assertEqual((runner / "gitlab.local.crt").read_bytes(), cert_before)
        self.assertFalse(list(runner.glob("*.key")))
        result = subprocess.run(
            ["openssl", "x509", "-in", str(self.cert), "-noout", "-ext", "subjectAltName"],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("DNS:gitlab.local", result.stdout)

    def test_compose_dotenv_quotes_and_environment_precedence(self):
        (self.root / ".env").write_text('hostname="from-dotenv.local" # comment\n')
        self.env["hostname"] = "gitlab.local"
        self.assertIn("GitLab hostname: gitlab.local", self.run_setup())
        del self.env["hostname"]
        self.key.rename(self.key.with_name("from-dotenv.local.key"))
        self.cert.rename(self.cert.with_name("from-dotenv.local.crt"))
        output = self.run_setup(ok=False)
        self.assertIn("GitLab hostname: from-dotenv.local", output)
        self.assertIn("Certificate needs a DNS SAN", output)

    def test_missing_or_empty_hostname_fails_before_writing(self):
        shutil.rmtree(self.root / ".volumes")
        (self.root / ".env").unlink()
        self.assertIn("Set hostname", self.run_setup(ok=False))
        self.assertFalse((self.root / ".volumes").exists())
        (self.root / ".env").write_text("hostname=\n")
        self.run_setup(ok=False)
        self.assertFalse((self.root / ".volumes").exists())

    def test_invalid_hostname_is_rejected_before_writing(self):
        shutil.rmtree(self.root / ".volumes")
        for host in ("https://gitlab.local", "gitlab.local:443", "127.0.0.1", "../outside", "-bad.local", "a" * 64 + ".local"):
            with self.subTest(host=host):
                self.env["hostname"] = host
                self.run_setup(ok=False)
                self.assertFalse((self.root / ".volumes").exists())

    def test_legacy_certificate_is_preserved_until_explicit_renewal(self):
        self.issue_certificate(san=False)
        original = self.cert.read_bytes()
        self.assertIn("--renew-cert", self.run_setup(ok=False))
        self.assertEqual(self.cert.read_bytes(), original)
        self.run_setup("--renew-cert")
        backups = list(self.cert.parent.glob("backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / self.cert.name).read_bytes(), original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)
        self.assertNotEqual(self.cert.read_bytes(), original)
        self.run_setup()

    def test_nearly_expired_certificate_is_rejected(self):
        self.issue_certificate(days=1)
        self.assertIn("expires within 30 days", self.run_setup(ok=False))

    def test_mismatched_private_key_is_rejected(self):
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(self.key)],
            capture_output=True, check=True,
        )
        self.assertIn("do not match", self.run_setup(ok=False))

    def test_partial_certificate_is_not_overwritten(self):
        original = self.key.read_bytes()
        self.cert.unlink()
        self.assertIn("Certificate or key is missing", self.run_setup(ok=False))
        self.assertFalse(self.cert.exists())
        self.assertEqual(self.key.read_bytes(), original)

    def test_failed_generation_keeps_previous_files(self):
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_openssl = fake_bin / "openssl"
        fake_openssl.write_text("#!/bin/sh\nexit 1\n")
        fake_openssl.chmod(0o755)
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]
        original = (self.key.read_bytes(), self.cert.read_bytes())
        self.run_setup("--renew-cert", ok=False)
        self.assertEqual((self.key.read_bytes(), self.cert.read_bytes()), original)
        self.assertFalse(list(self.cert.parent.glob(".certificate.*")))

    def test_check_without_certificate_does_not_create_directories(self):
        shutil.rmtree(self.root / ".volumes")
        self.run_setup("--check", ok=False)
        self.assertFalse((self.root / ".volumes").exists())

    def install_diagnostic_stubs(self):
        # Keep real Compose parsing; stub only daemon and HTTP interactions.
        docker_binary = shutil.which("docker")
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        docker = fake_bin / "docker"
        docker.write_text('''#!/bin/bash
case "$*" in
    'compose version'|'compose config --quiet'|'compose config --environment')
        exec "$REAL_DOCKER" "$@" ;;
    info) exit "${TEST_DAEMON_STATUS:-0}" ;;
    'compose ps -a') echo 'gitlab running (healthy)' ;;
    'compose ps -a -q gitlab') echo test-container ;;
    inspect*) echo 'State: running; health: healthy' ;;
    'compose exec -T gitlab curl '*)
        echo '{"status":"ok"}'
        exit "${TEST_READINESS_STATUS:-0}" ;;
    *) echo "Unexpected Docker command: $*" >&2; exit 99 ;;
esac
''')
        docker.chmod(0o755)
        curl = fake_bin / "curl"
        curl.write_text('''#!/bin/bash
case "${!#}" in
    https://gitlab.local/users/sign_in) exit "${TEST_HTTPS_STATUS:-0}" ;;
    https://gitlab.local:5050/v2/) printf '%s' "${TEST_REGISTRY_STATUS:-401}" ;;
    *) exit 99 ;;
esac
''')
        curl.chmod(0o755)
        self.env["REAL_DOCKER"] = docker_binary
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]

    def file_snapshot(self):
        return {
            str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mode)
            for path in self.root.rglob("*") if path.is_file()
        }

    def test_check_accepts_registry_auth_challenge_without_writing(self):
        self.install_diagnostic_stubs()
        before = self.file_snapshot()
        self.assertIn("OK: configuration", self.run_setup("--check"))
        self.assertEqual(self.file_snapshot(), before)

    def test_check_reports_daemon_readiness_https_and_registry_failures(self):
        self.install_diagnostic_stubs()
        for variable, value, message in (
            ("TEST_DAEMON_STATUS", "1", "Cannot access Docker"),
            ("TEST_READINESS_STATUS", "1", "GitLab is not ready"),
            ("TEST_HTTPS_STATUS", "6", "Cannot reach GitLab from this host"),
            ("TEST_REGISTRY_STATUS", "503", "Unexpected Container Registry HTTP status: 503"),
        ):
            with self.subTest(variable=variable):
                self.env[variable] = value
                self.assertIn(message, self.run_setup("--check", ok=False))
                del self.env[variable]

    def test_help_and_unknown_option(self):
        self.assertIn("Usage:", self.run_setup("--help"))
        self.assertIn("Unknown option", self.run_setup("--unknown", ok=False))


if __name__ == "__main__":
    unittest.main()
