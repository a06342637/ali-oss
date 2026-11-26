#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d /tmp/dujiao-backup-workflow.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
export TEST_ROOT="$fixture" TEST_REPO="$repo_dir" TEST_SUBJECT="$fixture/subject.sh"
export FAKE_OSS_ROOT="$fixture/oss"
sed -e '$d' \
  -e "s|readonly INSTALL_DIR=.*|readonly INSTALL_DIR=\"$fixture/runtime\"|" \
  -e "s|readonly LOCK_FILE=.*|readonly LOCK_FILE=\"$fixture/backup.lock\"|" \
  -e "s|readonly SERVICE_FILE=.*|readonly SERVICE_FILE=\"$fixture/service\"|" \
  -e "s|readonly TIMER_FILE=.*|readonly TIMER_FILE=\"$fixture/timer\"|" \
  "$repo_dir/dujiao-backup.sh" > "$TEST_SUBJECT"

cat > "$fixture/helpers.sh" <<'HELPERS'
# shellcheck disable=SC1090
source "$TEST_SUBJECT"
require_root() { :; }
require_tty() { :; }
chown() { :; }
ensure_runtime_dirs() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$BACKUP_DIR" "$KEY_DIR" "$STATE_DIR" "$TMP_DIR"
  touch "$LOG_FILE" "$HISTORY_FILE"
}
start_log_capture() { :; }
flock() { [[ "${TEST_LOCKED:-0}" == 0 ]]; }
systemd_available() { return 0; }
systemctl() { printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.log"; }
curl() {
  local destination=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi
  done
  cp -- "$TEST_ROOT/update.sh" "$destination"
}
prompt_yes_no() { printf -v "$1" '%s' 1; }
ossutil() { bash "$TEST_REPO/tests/fake-ossutil" "$@"; }
sftp_ssh() { sh -c "$1"; }
sftp() {
  local batch="" line source_file target
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -b ]]; then batch="$2"; shift 2; else shift; fi
  done
  line="$(cat "$batch")"
  [[ "$line" =~ ^put\ \"([^\"]+)\"\ \"([^\"]+)\"$ ]]
  source_file="${BASH_REMATCH[1]}"
  target="${BASH_REMATCH[2]}"
  cp -- "$source_file" "$target"
  [[ "${TEST_CORRUPT_UPLOAD:-0}" != 1 ]] || printf 'corrupted\n' > "$target"
}
ensure_runtime_dirs
HELPERS

mkdir -p "$fixture/source/nested" "$fixture/remote"
printf 'business-data\n' > "$fixture/source/nested/data.txt"
printf 'file with spaces\n' > "$fixture/source/report final.txt"
printf 'payload\n' > "$fixture/payload"

# Save/reload through the actual configuration functions in an isolated runtime.
bash -c 'source "$TEST_ROOT/helpers.sh"; BACKUP_TYPE=directory; CUSTOM_DIR="$TEST_ROOT/source"; CUSTOM_DIR_NAME="业务附件"; MAX_BACKUPS=1; save_config'

expect_failure() {
  local label="$1" code="$2"
  if bash -c "source \"\$TEST_ROOT/helpers.sh\"; $code" > "$fixture/$label.log" 2>&1; then
    printf '%s unexpectedly succeeded.\n' "$label" >&2
    cat "$fixture/$label.log" >&2
    exit 1
  fi
}

# A bad upload must preserve the previous remote backup and never write a marker.
remote_name=directory-20260101-000001.tar
printf 'previous-good-backup\n' > "$fixture/remote/$remote_name"
expect_failure corrupt-sftp 'TEST_CORRUPT_UPLOAD=1; SFTP_REMOTE_DIR="$TEST_ROOT/remote"; sync_archive_to_sftp "$TEST_ROOT/payload"'
[[ "$(cat "$fixture/remote/$remote_name")" == previous-good-backup ]]
[[ ! -f "$fixture/runtime/state/payload.sftp.ok" ]]

# Use the correct archive basename for the same overwrite scenario.
cp "$fixture/payload" "$fixture/$remote_name"
expect_failure corrupt-sftp-archive 'TEST_CORRUPT_UPLOAD=1; SFTP_REMOTE_DIR="$TEST_ROOT/remote"; sync_archive_to_sftp "$TEST_ROOT/directory-20260101-000001.tar"'
[[ "$(cat "$fixture/remote/$remote_name")" == previous-good-backup ]]
[[ ! -f "$fixture/runtime/state/$remote_name.sftp.ok" ]]
bash -c 'source "$TEST_ROOT/helpers.sh"; SFTP_REMOTE_DIR="$TEST_ROOT/remote"; sync_archive_to_sftp "$TEST_ROOT/directory-20260101-000001.tar"'
cmp "$fixture/$remote_name" "$fixture/remote/$remote_name"
[[ -f "$fixture/runtime/state/$remote_name.sftp.ok" ]]

# New invalid archives must stop before upload or retention.
expect_failure invalid-archive 'create_archive() { CREATED_ARCHIVE="$BACKUP_DIR/directory-20260101-000002.tar"; printf broken > "$CREATED_ARCHIVE"; }; sync_all_archives() { touch "$TEST_ROOT/upload-called"; }; apply_retention() { touch "$TEST_ROOT/retention-called"; }; backup_command'
[[ ! -e "$fixture/upload-called" && ! -e "$fixture/retention-called" ]]
[[ ! -f "$fixture/runtime/backups/directory-20260101-000002.tar" ]]

# An old invalid archive cannot be blindly uploaded while enabling a new target.
printf 'broken old archive\n' > "$fixture/runtime/backups/directory-20200101-000000.tar"
expect_failure invalid-old-archive 'load_config; OSS_ENABLED=1; OSS_ACCESS_KEY_ID=test; OSS_ACCESS_KEY_SECRET=test; OSS_REGION=cn-hangzhou; OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com; OSS_BUCKET=test-bucket; OSS_PREFIX=workflow; sync_all_archives'
[[ ! -f "$FAKE_OSS_ROOT/test-bucket/workflow/directory-20200101-000000.tar" ]]
rm -f -- "$fixture/runtime/backups/directory-20200101-000000.tar"

# Offline SFTP must be reported as failure rather than an empty successful list.
expect_failure offline-sftp 'load_config() { set_config_defaults; BACKUP_TYPE=directory; SFTP_ENABLED=1; SFTP_HOST=test.example; SFTP_REMOTE_DIR="$TEST_ROOT/remote"; }; sftp_ssh() { return 255; }; list_remote_backups'

# Two full local runs: archive restoration, retention, history and status.
bash -c 'source "$TEST_ROOT/helpers.sh"; backup_command'
first="$(find "$fixture/runtime/backups" -maxdepth 1 -name 'directory-*.tar' -print -quit)"
mkdir -p "$fixture/restore"
tar -xf "$first" -C "$fixture/restore"
tar -xzf "$fixture/restore/directory.tar.gz" -C "$fixture/restore"
cmp "$fixture/source/nested/data.txt" "$fixture/restore/nested/data.txt"
cmp "$fixture/source/report final.txt" "$fixture/restore/report final.txt"
bash -c 'source "$TEST_ROOT/helpers.sh"; backup_command'
[[ "$(find "$fixture/runtime/backups" -maxdepth 1 -name 'directory-*.tar' | wc -l)" -eq 1 ]]
[[ "$(awk -F '\t' '$5 == "success" {n++} END {print n+0}' "$fixture/runtime/state/backup-history.tsv")" -eq 2 ]]
bash -c 'source "$TEST_ROOT/helpers.sh"; status_command; show_backup_history' > "$fixture/status.log"
grep -Fq '业务附件' "$fixture/status.log"

# A busy lock skips without creating an archive or a new execution record.
before="$(wc -l < "$fixture/runtime/state/backup-history.tsv")"
bash -c 'source "$TEST_ROOT/helpers.sh"; TEST_LOCKED=1; backup_command'
[[ "$(wc -l < "$fixture/runtime/state/backup-history.tsv")" -eq "$before" ]]

# Failed synchronization must leave the old archive and record a failed run.
old="$(find "$fixture/runtime/backups" -maxdepth 1 -name 'directory-*.tar' -print -quit)"
expect_failure upload-failure 'sync_all_archives() { return 7; }; backup_command'
[[ -f "$old" ]]
[[ "$(tail -n 1 "$fixture/runtime/state/backup-history.tsv" | cut -f5)" == failed ]]

# Timer units and saved flags agree on a two-minute interval.
bash -c 'source "$TEST_ROOT/helpers.sh"; load_config; TIMER_DAYS=0; TIMER_HOURS=0; TIMER_MINUTES=2; enable_timer_interactive; load_config; [[ "$TIMER_ENABLED" == 1 && "$(timer_total_seconds)" == 120 ]]; disable_timer; load_config; [[ "$TIMER_ENABLED" == 0 ]]'
grep -qx 'OnActiveSec=120s' "$fixture/timer"
grep -qx 'OnUnitInactiveSec=120s' "$fixture/timer"
for databases in 'app,' ',app' 'app,,other'; do
  export TEST_DATABASES="$databases"
  expect_failure invalid-database-list 'valid_mysql_database_selection "$TEST_DATABASES"'
done

# A failed update write must preserve the complete old installed script.
current_version="$(bash "$repo_dir/dujiao-backup.sh" version)"
IFS=. read -r major minor patch <<< "$current_version"
future_version="$major.$minor.$((patch + 1))"
printf '#!/usr/bin/env bash\nreadonly VERSION="%s"\nprintf upgraded\\n\n' "$future_version" > "$fixture/update.sh"
printf '#!/usr/bin/env bash\nprintf previous\\n\n' > "$fixture/runtime/dujiao-backup.sh"
cp "$fixture/runtime/dujiao-backup.sh" "$fixture/old-script"
expect_failure failed-update 'install() { printf truncated > "${@: -1}"; return 23; }; update_command'
cmp "$fixture/old-script" "$fixture/runtime/dujiao-backup.sh"
bash -c 'source "$TEST_ROOT/helpers.sh"; install() { local -a args=(); while [[ "$#" -gt 0 ]]; do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done; command install "${args[@]}"; }; update_command'
cmp "$fixture/update.sh" "$fixture/runtime/dujiao-backup.sh"
printf 'workflow: OK\n'
