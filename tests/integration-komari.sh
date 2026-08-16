#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${DUJIAO_INTEGRATION_TEST:-}" == "1" ]] || {
  printf 'Refusing to modify /opt/dujiao-backup outside the integration-test environment.\n' >&2
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="/tmp/komari-backup-test/data"
fake_bin="/tmp/komari-backup-test-bin"
config_tmp="/tmp/komari-backup-test-config"
restore_dir="/tmp/komari-backup-restore"
release_file="/tmp/komari-backup-release"
install_transcript="/tmp/komari-install.typescript"
install_output="/tmp/komari-install.output"
writer_pid=""

cleanup_test() {
  touch "$release_file" 2>/dev/null || true
  if [[ -n "$writer_pid" ]]; then
    wait "$writer_pid" 2>/dev/null || true
  fi
  if [[ -L /usr/local/bin/dujiao-backup ]] \
    && [[ "$(readlink -f /usr/local/bin/dujiao-backup)" == "/opt/dujiao-backup/dujiao-backup.sh" ]]; then
    rm -f -- /usr/local/bin/dujiao-backup
  fi
}
trap cleanup_test EXIT

rm -rf -- /tmp/komari-backup-test /tmp/komari-backup-test-bin /tmp/komari-backup-restore
rm -f -- "$config_tmp" "$release_file" "$install_transcript" "$install_output"
rm -rf -- /opt/dujiao-backup
mkdir -p "$data_dir/theme/Emerald" "$fake_bin" "$restore_dir"
printf 'theme-data\n' > "$data_dir/theme/Emerald/komari-theme.json"
sqlite3 "$data_dir/komari.db" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA wal_autocheckpoint=0;
CREATE TABLE nodes(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO nodes(name) VALUES ('committed');
SQL

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'if [[ "${1:-}" != "inspect" ]]; then exit 1; fi' \
  'if [[ "${2:-}" == "--format" || "${2:-}" == "-f" ]]; then' \
  '  case "${3:-}" in' \
  '    *Mounts*) printf "%s\n" "${FAKE_KOMARI_DATA_DIR:?}" ;;' \
  '    *Config.Image*) printf "ghcr.io/komari-monitor/komari:latest\n" ;;' \
  '    *State.Running*) printf "true\n" ;;' \
  '    *Name*) printf "/komari\n" ;;' \
  '    *) exit 1 ;;' \
  '  esac' \
  'fi' \
  'exit 0' > "$fake_bin/docker"
chmod 0755 "$fake_bin/docker"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'exit 0' > "$fake_bin/apt-get"
chmod 0755 "$fake_bin/apt-get"

export PATH="$fake_bin:$PATH"
export FAKE_KOMARI_DATA_DIR="$data_dir"
printf '%s\n' \
  '' \
  '   ' \
  4 \
  '' \
  '   ' \
  2 \
  '' \
  '   ' \
  komari \
  '' \
  '   ' \
  y \
  '' \
  '   ' \
  2 \
  '' \
  '   ' \
  n \
  '' \
  '   ' \
  n | timeout 90s script -qec "bash '$repo_dir/dujiao-backup.sh' install" "$install_transcript"
tr -d '\r' < "$install_transcript" > "$install_output"

grep -Fq '安装 Dujiao-Next / Komari Backup Manager v1.2.1' "$install_output"
grep -Fq '选择备份目标' "$install_output"
grep -Fq '选择要备份的业务' "$install_output"
grep -Fq '识别 Komari 探针面板 Docker 部署' "$install_output"
grep -Fq '设置备份保留数量' "$install_output"
grep -Fq '配置自动备份' "$install_output"
grep -Fq '安装成功' "$install_output"
install_line="$(awk 'index($0, "安装 Dujiao-Next / Komari Backup Manager v1.2.1") { print NR; exit }' "$install_output")"
target_line="$(awk 'index($0, "选择备份目标") { print NR; exit }' "$install_output")"
business_line="$(awk 'index($0, "选择要备份的业务") { print NR; exit }' "$install_output")"
komari_line="$(awk 'index($0, "识别 Komari 探针面板 Docker 部署") { print NR; exit }' "$install_output")"
retention_line="$(awk 'index($0, "设置备份保留数量") { print NR; exit }' "$install_output")"
timer_line="$(awk 'index($0, "配置自动备份") { print NR; exit }' "$install_output")"
success_line="$(awk 'index($0, "安装成功") { print NR; exit }' "$install_output")"
(( install_line < target_line \
  && target_line < business_line \
  && business_line < komari_line \
  && komari_line < retention_line \
  && retention_line < timer_line \
  && timer_line < success_line ))
invalid_count="$(grep -oF '空值或纯空格无效' "$install_output" | wc -l | tr -d ' ')"
test "$invalid_count" -ge 14
if grep -E '(请选择|Komari 容器名|确认使用|最多保留|是否启用|是否现在).*\[(INFO|WARN|SUCCESS|ERROR)\]' "$install_output"; then
  printf 'Interactive prompt and log output were joined on one line.\n' >&2
  exit 1
fi
grep -Fq '基础依赖安装完成。' /opt/dujiao-backup/logs/dujiao-backup.log
grep -Fq 'start_log_capture interactive' "$repo_dir/dujiao-backup.sh"

printf '%s\n' \
  'CONFIG_VERSION=1' \
  'BACKUP_TYPE=komari' \
  'KOMARI_CONTAINER=komari' \
  "KOMARI_DATA_DIR=$data_dir" \
  'MAX_BACKUPS=1' \
  'OSS_ENABLED=0' \
  'SFTP_ENABLED=0' > "$config_tmp"
install -m 0600 "$config_tmp" /opt/dujiao-backup/config.conf

run_backup() {
  env "PATH=$fake_bin:$PATH" FAKE_KOMARI_DATA_DIR="$data_dir" \
    bash "$repo_dir/dujiao-backup.sh" backup
}

sqlite3 "$data_dir/komari.db" <<SQL &
PRAGMA journal_mode=WAL;
PRAGMA wal_autocheckpoint=0;
BEGIN IMMEDIATE;
INSERT INTO nodes(name) VALUES ('not-yet-committed');
.shell while [ ! -e '$release_file' ]; do sleep 0.1; done
COMMIT;
SQL
writer_pid="$!"

for _attempt in $(seq 1 100); do
  [[ -f "$data_dir/komari.db-wal" && -f "$data_dir/komari.db-shm" ]] && break
  sleep 0.1
done
test -f "$data_dir/komari.db-wal"
test -f "$data_dir/komari.db-shm"

run_backup
first_archive="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'komari-*.tar' -print -quit)"
test -n "$first_archive"
tar -xf "$first_archive" -C "$restore_dir"
tar -xzf "$restore_dir/data.tar.gz" -C "$restore_dir"
test "$(sqlite3 "$restore_dir/data/komari.db" 'SELECT count(*) FROM nodes;')" = "1"
test -f "$restore_dir/data/theme/Emerald/komari-theme.json"
test ! -e "$restore_dir/data/komari.db-wal"
test ! -e "$restore_dir/data/komari.db-shm"

touch "$release_file"
wait "$writer_pid"
writer_pid=""
sleep 1
run_backup
bash "$repo_dir/dujiao-backup.sh" verify

test "$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'komari-*.tar' | wc -l)" -eq 1
latest="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'komari-*.tar' -print -quit)"
rm -rf -- "$restore_dir"
mkdir -p "$restore_dir"
tar -xf "$latest" -C "$restore_dir"
tar -xzf "$restore_dir/data.tar.gz" -C "$restore_dir"
test "$(sqlite3 "$restore_dir/data/komari.db" 'SELECT count(*) FROM nodes;')" = "2"

printf '%s\n' \
  2 \
  1 \
  '' \
  '   ' \
  komari \
  '' \
  '   ' \
  y \
  '' \
  0 \
  0 | timeout 60s script -qec "bash '$repo_dir/dujiao-backup.sh' configure" /dev/null
(
  # shellcheck disable=SC1091
  source /opt/dujiao-backup/config.conf
  test "$BACKUP_TYPE" = "komari"
  test "$KOMARI_CONTAINER" = "komari"
  test "$KOMARI_DATA_DIR" = "$data_dir"
)

printf 'Komari integration: OK\n'
