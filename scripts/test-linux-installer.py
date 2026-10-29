#!/usr/bin/env python3
"""Isolated native installer/update lifecycle tests; never invokes host services."""
from __future__ import annotations

import argparse
import datetime
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
INSTALLER = (ROOT / "platforms/linux/install-linux.sh").read_text()
UPDATER = (ROOT / "platforms/shared/package-update.sh").read_text()


def bash_path(path):
    value = Path(path).resolve().as_posix()
    if len(value) > 1 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    path.chmod(0o755)


STUB = r"""#!/usr/bin/env bash
set -eu
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >> "$TEST_ROOT/calls"
case "$name" in
  pwsh) printf '7.4.16\n' ;;
  chown|chmod|runuser|sleep|groupadd|useradd|convert|identify|curl) exit 0 ;;
  id) printf '1234\n' ;;
  getent) exit 0 ;;
  install)
    arguments=()
    directory=false
    while (( $# )); do
      case "$1" in -o|-g|-m) shift 2 ;; -d) directory=true; shift ;; *) arguments+=("$1"); shift ;; esac
    done
    if [[ "$SCENARIO" == copy-fail && "${arguments[*]}" == *tautweekly-remote-access.socket* && ! -f "$TEST_ROOT/failed-copy" ]]; then
      touch "$TEST_ROOT/failed-copy"
      exit 71
    fi
    if [[ "$directory" == true ]]; then mkdir -p "${arguments[@]}"; else cp "${arguments[@]}"; fi
    ;;
  flock)
    if [[ "$*" == '-u 9' ]]; then rm -f "$TEST_ROOT/op-held"; exit 0; fi
    if [[ "$*" == '-n 7' ]]; then [[ "$SCENARIO" != installer-busy ]]; exit; fi
    count=0; [[ ! -f "$TEST_ROOT/lock-count" ]] || read -r count < "$TEST_ROOT/lock-count"
    count=$((count+1)); printf '%s\n' "$count" > "$TEST_ROOT/lock-count"
    if [[ "$SCENARIO" == operation-busy && "$count" == 1 ]] || [[ "$SCENARIO" == operation-race && "$count" == 2 ]]; then exit 1; fi
    touch "$TEST_ROOT/op-held"
    ;;
  systemctl)
    case "$1" in
      is-active) [[ "$(cat "$TEST_ROOT/active")" == true ]] ;;
      is-enabled) [[ "$(cat "$TEST_ROOT/enabled")" == true ]] ;;
      show) printf '1234\n' ;;
      stop)
        [[ ! -e "$TEST_ROOT/op-held" ]] || { echo DEADLOCK >&2; exit 88; }
        if [[ "$SCENARIO" == rollback-fail ]]; then
          [[ ! -e "$TEST_ROOT/stop-called" ]] || exit 74
          touch "$TEST_ROOT/stop-called"
        fi
        printf 'false\n' > "$TEST_ROOT/active"
        if [[ "$SCENARIO" == stop-fail && ! -f "$TEST_ROOT/failed-stop" ]]; then touch "$TEST_ROOT/failed-stop"; exit 72; fi
        ;;
      start)
        [[ ! -e "$TEST_ROOT/op-held" ]] || { echo DEADLOCK >&2; exit 88; }
        if [[ "$SCENARIO" == start-fail ]] && grep -q 'candidate' "$TEST_ROOT/host/opt/tautweekly/TautWeekly.ps1"; then exit 73; fi
        printf 'true\n' > "$TEST_ROOT/active"
        ;;
      enable) printf 'true\n' > "$TEST_ROOT/enabled" ;;
      disable) printf 'false\n' > "$TEST_ROOT/enabled" ;;
      daemon-reload) : ;;
      *) exit 90 ;;
    esac
    ;;
  python3)
    cat > "$TEST_ROOT/readiness.py"
    [[ "$SCENARIO" != unhealthy && "$SCENARIO" != rollback-fail ]]
    ;;
  *) exit 91 ;;
esac
"""


class InstallerLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tautweekly-installer-test-")
        self.root = Path(self.temp.name)
        self.host = self.root / "host"
        self.package = self.root / "package"
        self.bin = self.root / "stubs"
        self.original_private = {"config.json": "private-config", "state.json": "private-state", "output/preview.html": "private-preview", "assets/custom.png": "private-asset"}
        for name in ("pwsh", "chown", "chmod", "runuser", "sleep", "getent", "id", "groupadd", "useradd", "install", "flock", "systemctl", "convert", "identify", "curl", "python3"):
            write(self.bin / name, STUB)
        self.transformed = INSTALLER.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', 'if false; then')
        for prefix in ("/opt", "/etc", "/usr/local", "/var/lib", "/var/backups", "/run/systemd", "/proc"):
            self.transformed = self.transformed.replace(prefix, bash_path(self.host) + prefix)
        write(self.package / "install-linux.sh", self.transformed)
        write(self.package / "app/TautWeekly.ps1", "candidate\n")
        write(self.package / "app/run-service.sh", "#!/bin/sh\nexit 0\n")
        write(self.package / "app/bin/helper.sh", "#!/bin/sh\nexit 0\n")
        write(self.package / "app/config.example.json", "{}\n")
        write(self.package / "app/refresh-assets.py", "# stubbed service-account asset refresh\n")
        write(self.package / "RELEASE-METADATA.txt", "Repository version: 0.28.0\n")
        for architecture in ("amd64", "arm64"):
            write(self.package / f"manager/tautweekly-manager-linux-{architecture}", "#!/usr/bin/env bash\nprintf 'TautWeekly Manager 0.28.0\\n'\n")
        for name in ("tautweekly", "check-release.sh", "package-update.sh"):
            write(self.package / name, "#!/bin/sh\n# candidate host file\n")
        for name in ("tautweekly.service", "tautweekly-remote-access.socket", "tautweekly-remote-access@.service"):
            write(self.package / "systemd" / name, "# candidate unit\n")
        write(self.package / "tautweekly.env.example", "TAUTWEEKLY_MANAGER_LISTEN=127.0.0.1:8788\n")
        (self.host / "run/systemd/system").mkdir(parents=True)
        for name, contents in self.original_private.items():
            write(self.host / "var/lib/tautweekly" / name, contents)
        write(self.host / "var/lib/tautweekly/.tautweekly-operation.lock", "")
        self.seed_existing()

    def tearDown(self):
        self.temp.cleanup()

    def seed_existing(self, active=True, enabled=True):
        write(self.host / "opt/tautweekly/TautWeekly.ps1", "previous\n")
        write(self.host / "opt/tautweekly/retired.txt", "old-payload\n")
        write(self.host / "opt/tautweekly/RELEASE-METADATA.txt", "Repository version: 0.27.2\n")
        write(self.host / "usr/local/bin/tautweekly", "previous wrapper\n")
        write(self.host / "etc/systemd/system/tautweekly.service", "previous unit\n")
        write(self.host / "etc/tautweekly/tautweekly.env", "TAUTWEEKLY_MANAGER_LISTEN=127.0.0.1:8788\n# administrator settings\n")
        write(self.root / "active", str(active).lower())
        write(self.root / "enabled", str(enabled).lower())

    def invoke(self, scenario="normal", mode="--upgrade"):
        environment = dict(os.environ, TEST_ROOT=bash_path(self.root), SCENARIO=scenario)
        # Keep POSIX utilities first after our stubs; Windows PATH entries are not
        # meaningful when supplied verbatim to a Bash subprocess.
        environment["PATH"] = bash_path(self.bin) + ":/usr/bin:/bin"
        result = subprocess.run([BASH, "-c", 'export PATH="$TEST_ROOT/stubs:/usr/bin:/bin"; exec bash "$@"', "test", bash_path(self.package / "install-linux.sh"), mode], env=environment, text=True, capture_output=True, timeout=30)
        self.assertNotIn("DEADLOCK", result.stdout + result.stderr)
        for name, content in self.original_private.items():
            self.assertEqual(content, (self.host / "var/lib/tautweekly" / name).read_text())
        return result

    def assert_restored(self, active=True, enabled=True):
        self.assertEqual("previous\n", (self.host / "opt/tautweekly/TautWeekly.ps1").read_text())
        self.assertEqual("old-payload\n", (self.host / "opt/tautweekly/retired.txt").read_text())
        self.assertEqual("previous wrapper\n", (self.host / "usr/local/bin/tautweekly").read_text())
        self.assertEqual("previous unit\n", (self.host / "etc/systemd/system/tautweekly.service").read_text())
        self.assertEqual(str(active).lower(), (self.root / "active").read_text().strip())
        self.assertEqual(str(enabled).lower(), (self.root / "enabled").read_text().strip())
        self.assertFalse((self.host / "usr/local/libexec/tautweekly-check-release").exists())

    def test_upgrade_releases_lock_before_stop_and_start(self):
        result = self.invoke()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("candidate\n", (self.host / "opt/tautweekly/TautWeekly.ps1").read_text())
        self.assertTrue((self.root / "readiness.py").exists())
        self.assertEqual("true", (self.root / "active").read_text().strip())
        self.assertTrue(list((self.host / "var/backups/tautweekly").glob("program-*/program.tar.gz")))

    def test_stopped_disabled_service_stays_stopped_disabled(self):
        self.seed_existing(active=False, enabled=False)
        result = self.invoke()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("false", (self.root / "active").read_text().strip())
        self.assertEqual("false", (self.root / "enabled").read_text().strip())
        self.assertFalse((self.root / "readiness.py").exists())

    def test_fresh_install_starts_and_enables(self):
        shutil.rmtree(self.host / "opt/tautweekly")
        write(self.root / "active", "false")
        write(self.root / "enabled", "false")
        result = self.invoke(mode="install")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("true", (self.root / "active").read_text().strip())
        self.assertEqual("true", (self.root / "enabled").read_text().strip())

    def test_failed_candidate_restores_program_host_files_and_service(self):
        for scenario in ("copy-fail", "start-fail", "unhealthy"):
            with self.subTest(scenario=scenario):
                result = self.invoke(scenario)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Previous installation and service state restored", result.stderr)
                self.assert_restored()

    def test_failed_restoration_reports_retained_root_owned_backup(self):
        result = self.invoke("rollback-fail")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Automatic restoration needs administrator attention", result.stderr)
        self.assertNotIn("Previous installation and service state restored", result.stderr)
        self.assertTrue(list((self.host / "var/backups/tautweekly").glob("program-*/program.tar.gz")))

    def test_stopped_failed_copy_retains_stopped_disabled_state(self):
        self.seed_existing(active=False, enabled=False)
        result = self.invoke("copy-fail")
        self.assertNotEqual(0, result.returncode)
        self.assert_restored(active=False, enabled=False)

    def test_stop_failure_and_raced_operation_restore_active_service(self):
        for scenario in ("stop-fail", "operation-race"):
            with self.subTest(scenario=scenario):
                # Reset counters while retaining the existing fixture.
                for name in ("lock-count", "failed-stop"):
                    (self.root / name).unlink(missing_ok=True)
                result = self.invoke(scenario)
                self.assertNotEqual(0, result.returncode)
                self.assert_restored()

    def test_busy_operation_or_installer_refuses_before_stop(self):
        for scenario in ("operation-busy", "installer-busy"):
            with self.subTest(scenario=scenario):
                (self.root / "lock-count").unlink(missing_ok=True)
                result = self.invoke(scenario)
                self.assertEqual(75, result.returncode, result.stderr)
                self.assert_restored()

    def test_metadata_mismatch_refuses_before_stop(self):
        write(self.package / "RELEASE-METADATA.txt", "Repository version: 0.99.0\n")
        result = self.invoke()
        self.assertEqual(65, result.returncode)
        self.assert_restored()

    def test_default_install_refuses_existing_deployment(self):
        result = self.invoke(mode="install")
        self.assertEqual(64, result.returncode)
        self.assert_restored()


class UpdateNoOp(unittest.TestCase):
    def test_current_or_newer_does_not_stage_or_install(self):
        compare = UPDATER[UPDATER.index("version_greater_than() {"):UPDATER.index("download_file() {")]
        apply = UPDATER[UPDATER.index("apply_update() {"):UPDATER.index("install_candidate() {")]
        for current in ("0.28.0", "0.29.0"):
            script = "set -eu\n" + compare + apply + f"""
update_strategy=native-linux
package_kind=linux
package_root=/unused
package_name=TautWeekly-linux
current_package_version() {{ printf '{current}'; }}
latest_release_version() {{ printf '0.28.0'; }}
run_runtime_updater() {{ printf 'runtime no-op\\n'; }}
mktemp() {{ echo 'UNEXPECTED STAGING' >&2; exit 73; }}
apply_update
"""
            result = subprocess.run([BASH, "-s"], input=script, text=True, capture_output=True, timeout=5)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertNotIn("UNEXPECTED STAGING", result.stderr)
            self.assertEqual(1, result.stdout.count("runtime no-op"))


class ReadinessPredicate(unittest.TestCase):
    def test_fresh_owned_processes_and_exact_liveness_are_required(self):
        code = INSTALLER.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        now = datetime.datetime.now(datetime.timezone.utc)
        for scenario in ("healthy", "stale", "wrong-supervisor", "wrong-scheduler", "foreign-exe", "bad-health"):
            with self.subTest(scenario=scenario):
                observed = now - datetime.timedelta(seconds=100 if scenario == "stale" else 0)
                heartbeats = {
                    "service-heartbeat.json": {"Utc": observed.isoformat(), "ProcessId": 999 if scenario == "wrong-supervisor" else 1234, "ManagerProcessId": 1235, "SchedulerProcessId": 1236},
                    "scheduler-heartbeat.json": {"Utc": observed.isoformat(), "ProcessId": 999 if scenario == "wrong-scheduler" else 1236},
                }
                def read_text(path, *args, **kwargs):
                    if path.name in heartbeats:
                        return json.dumps(heartbeats[path.name])
                    return "PPid:\t1234\n"
                class Response(io.BytesIO):
                    status = 200
                class Opener:
                    def open(self, url, timeout):
                        self.assert_url = url
                        return Response(json.dumps({"status": "dead" if scenario == "bad-health" else "alive"}).encode())
                with patch.object(sys, "argv", ["-", str(int(now.timestamp())), "127.0.0.1:8788", "1234"]), patch.object(Path, "read_text", read_text), patch("os.path.samefile", return_value=scenario != "foreign-exe"), patch("urllib.request.build_opener", return_value=Opener()):
                    if scenario == "healthy":
                        exec(compile(code, "installer-readiness", "exec"), {})
                    else:
                        with self.assertRaises(SystemExit) as failure:
                            exec(compile(code, "installer-readiness", "exec"), {})
                        self.assertEqual(1, failure.exception.code)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bash", default=BASH, help="Bash executable (Git Bash is supported for mocked lifecycle tests)")
    arguments, unittest_arguments = parser.parse_known_args()
    BASH = arguments.bash
    if not BASH:
        parser.error("Bash is required")
    unittest.main(argv=[sys.argv[0], *unittest_arguments])
