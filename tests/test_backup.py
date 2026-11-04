"""Verify that upload and verification failures cannot trigger backup pruning."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "backupNextcloud.sh"


class BackupTests(unittest.TestCase):
    def run_shell(self, code):
        with tempfile.TemporaryDirectory() as root:
            result = subprocess.run(
                ["bash", "-c", 'source "$SCRIPT"\n' + code],
                env={**os.environ, "SCRIPT": str(SCRIPT), "TEST_ROOT": root},
                text=True, capture_output=True,
            )
            events = Path(root, "events")
            return result, events.read_text() if events.exists() else ""

    def workflow(self, mode):
        return self.run_shell(r'''
NC_ROOT="$TEST_ROOT/nextcloud"
BACKUP_DIR="$TEST_ROOT/backups"
SECOND_BACKUP_DIR=""
FULL_LOG_DIR="$TEST_ROOT/logs"
LOG_STATE="$TEST_ROOT/rotate.state"
LOG_ROTATE_CONF="$TEST_ROOT/missing.conf"
INCLUDE_DATA=1
mkdir -p "$NC_ROOT/config" "$NC_ROOT/data"
printf 'sample\n' > "$NC_ROOT/config/config.php"
oc_cfg() { printf 'test\n'; }
configure_openlist() { REMOTE_ROOT="openlist:/test"; }
docker() {
  printf 'docker %s\n' "$*" >> "$TEST_ROOT/events"
  [[ "$*" != *mysqldump* ]] || printf 'SQL dump\n'
}
rsync() {
  local src="${@: -2:1}" dst="${@: -1}"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
}
prune_local() { echo prune_local >> "$TEST_ROOT/events"; }
prune_remote() { echo prune_remote >> "$TEST_ROOT/events"; }
openlist() {
  echo "$1" >> "$TEST_ROOT/events"
  case "$1:$MODE" in
    lsf:offline) return 1 ;;
    copy:upload_fail) return 7 ;;
    check:check_fail) return 1 ;;
  esac
  return 0
}
if [ "$MODE" = log_fail ]; then
  tee() { cat >/dev/null; return 1; }
fi
main
'''.replace('NC_ROOT=', f'MODE={mode}\nNC_ROOT=', 1))

    def test_success_prunes_only_after_check(self):
        result, events = self.workflow("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(events.index("check\n"), events.index("prune_local\n"))
        self.assertLess(events.index("check\n"), events.index("prune_remote\n"))

    def test_failures_preserve_old_backups_and_disable_maintenance(self):
        for mode in ("upload_fail", "check_fail", "log_fail"):
            with self.subTest(mode=mode):
                result, events = self.workflow(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("prune_", events)
                self.assertIn("maintenance:mode --off", events)
                self.assertIn("保留全部旧备份", result.stdout)

    def test_offline_preflight_does_not_start_maintenance(self):
        result, events = self.workflow("offline")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, "lsf\n")

    def test_prune_matches_only_snapshot_directories(self):
        result, events = self.run_shell(r'''
REMOTE_ROOT="openlist:/test"
startTime_s=400
openlist() {
  case "$1" in
    lsf) printf '%s\n' nextcloud-400/ nextcloud-300/ nextcloud-100/ \
      nextcloud-200/ nextcloud-1-extra/ notes-nextcloud-2/ nextcloud-3 ;;
    purge) printf '%s\n' "$2" >> "$TEST_ROOT/events" ;;
  esac
}
prune_remote 2
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, "openlist:/test/nextcloud-100\nopenlist:/test/nextcloud-200\n")

    def test_prune_stops_on_delete_failure(self):
        result, events = self.run_shell(r'''
REMOTE_ROOT="openlist:/test"
startTime_s=400
openlist() {
  if [ "$1" = lsf ]; then
    printf '%s\n' nextcloud-100/ nextcloud-200/ nextcloud-300/ nextcloud-400/
  else
    printf '%s\n' "$2" >> "$TEST_ROOT/events"
    return 1
  fi
}
prune_remote 2
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, "openlist:/test/nextcloud-100\n")
        self.assertNotIn("已删除云端旧备份", result.stdout)

    def test_prune_aborts_on_listing_failure(self):
        result, events = self.run_shell(r'''
REMOTE_ROOT="openlist:/test"
openlist() { echo "$1" >> "$TEST_ROOT/events"; return 1; }
prune_remote 2
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, "lsf\n")


if __name__ == "__main__":
    unittest.main()
