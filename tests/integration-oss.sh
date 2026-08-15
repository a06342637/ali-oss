#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${DUJIAO_INTEGRATION_TEST:-}" == "1" ]] || {
  printf 'Refusing to modify /opt/dujiao-backup outside the integration-test environment.\n' >&2
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="/tmp/dujiao-next-oss-test"
fake_bin="/tmp/dujiao-backup-oss-bin"
remote_root="/tmp/dujiao-backup-fake-oss"
config_tmp="/tmp/dujiao-backup-oss-config"

rm -rf -- "$app_dir" "$fake_bin" "$remote_root"
rm -f -- "$config_tmp"
rm -rf -- /opt/dujiao-backup
install -d -m 0700 /opt/dujiao-backup
mkdir -p "$app_dir/config" "$app_dir/data/db" "$app_dir/data/uploads"
mkdir -p "$fake_bin" "$remote_root"
printf 'TAG=latest\n' > "$app_dir/.env"
printf 'database:\n  driver: sqlite\n' > "$app_dir/config/config.yml"
printf 'services: {}\n' > "$app_dir/docker-compose.sqlite.yml"
printf 'image-data\n' > "$app_dir/data/uploads/product.jpg"
sqlite3 "$app_dir/data/db/dujiao.db" \
  'CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO products(name) VALUES ("one");'

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$1" == "inspect" ]]; then' \
  '  [[ "${2:-}" == "--format" ]] && printf "dujiaonext/dujiao-next:latest\n"' \
  '  exit 0' \
  'fi' \
  'exit 1' > "$fake_bin/docker"
chmod 0755 "$fake_bin/docker"
install -m 0755 "$repo_dir/tests/fake-ossutil" "$fake_bin/ossutil"

printf '%s\n' \
  "APP_DIR=$app_dir" \
  'DEPLOY_MODE=sqlite' \
  'MAX_BACKUPS=2' \
  'OSS_ENABLED=1' \
  'OSS_ACCESS_KEY_ID=test-id' \
  'OSS_ACCESS_KEY_SECRET=test-secret' \
  'OSS_REGION=cn-hangzhou' \
  'OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com' \
  'OSS_BUCKET=test-bucket' \
  'OSS_PREFIX=dujiao-next/test-host' \
  'OSS_DELETE_ALL_VERSIONS=1' \
  'SFTP_ENABLED=0' > "$config_tmp"
install -m 0600 "$config_tmp" /opt/dujiao-backup/config.conf

run_backup() {
  env "PATH=$fake_bin:$PATH" FAKE_OSS_ROOT="$remote_root" \
    bash "$repo_dir/dujiao-backup.sh" backup
}

run_backup
first_archive="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' -printf '%f\n' | sort | head -n 1)"
remote_dir="$remote_root/test-bucket/dujiao-next/test-host"
rm -f -- "$remote_dir/$first_archive" "$remote_dir/$first_archive.dujiao-sha256"

sleep 1
sqlite3 "$app_dir/data/db/dujiao.db" 'INSERT INTO products(name) VALUES ("two");'
run_backup
test -f "$remote_dir/$first_archive"
grep -q 'OSS 中缺少本地保留备份，正在自动补传' /opt/dujiao-backup/logs/dujiao-backup.log

printf 'remote-only\n' > "$remote_dir/dujiao-next-20000101-000000.tar"
printf 'remote-only-sha\n' > "$remote_dir/dujiao-next-20000101-000000.tar.dujiao-sha256"
sleep 1
sqlite3 "$app_dir/data/db/dujiao.db" 'INSERT INTO products(name) VALUES ("three");'
run_backup

test "$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' | wc -l)" -eq 2
test "$(find "$remote_dir" -maxdepth 1 -name 'dujiao-next-*.tar' | wc -l)" -eq 2
test ! -e "$remote_dir/dujiao-next-20000101-000000.tar"
while IFS= read -r local_name; do
  test -f "$remote_dir/$local_name"
  test "$(sha256sum "/opt/dujiao-backup/backups/$local_name" | awk '{print $1}')" \
    = "$(< "$remote_dir/$local_name.dujiao-sha256")"
done < <(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' -printf '%f\n' | sort)

export PATH="$fake_bin:$PATH"
export FAKE_OSS_ROOT="$remote_root"
printf '%s\n' \
  4 \
  8 \
  'dujiao-next/menu-host' \
  '' \
  2 \
  y \
  '' \
  1 \
  '' \
  0 \
  3 \
  3 \
  '' \
  6 \
  2 \
  0 \
  1 \
  15 \
  '' \
  0 \
  0 | timeout 90s script -qec "bash '$repo_dir/dujiao-backup.sh' configure" /dev/null
(
  # shellcheck disable=SC1091
  source /opt/dujiao-backup/config.conf
  test "$OSS_ENABLED" = "1"
  test "$SFTP_ENABLED" = "0"
  test "$OSS_PREFIX" = "dujiao-next/menu-host"
  test "$OSS_VERSIONING_ENABLED" = "1"
  test "$OSS_DELETE_ALL_VERSIONS" = "1"
  test "$MAX_BACKUPS" = "3"
  test "$TIMER_ENABLED" = "0"
  test "$TIMER_DAYS" = "0"
  test "$TIMER_HOURS" = "1"
  test "$TIMER_MINUTES" = "15"
)

cp /opt/dujiao-backup/config.conf /tmp/dujiao-backup-config-good
printf 'TIMER_HOURS=08\n' >> /opt/dujiao-backup/config.conf
if env "PATH=$fake_bin:$PATH" FAKE_OSS_ROOT="$remote_root" \
  bash "$repo_dir/dujiao-backup.sh" status; then
  printf 'Invalid leading-zero timer value was unexpectedly accepted.\n' >&2
  exit 1
fi
mv -f -- /tmp/dujiao-backup-config-good /opt/dujiao-backup/config.conf
chmod 0600 /opt/dujiao-backup/config.conf

printf 'do-not-touch\n' > /tmp/dujiao-log-symlink-target
mv /opt/dujiao-backup/logs/dujiao-backup.log /opt/dujiao-backup/logs/dujiao-backup.log.real
ln -s /tmp/dujiao-log-symlink-target /opt/dujiao-backup/logs/dujiao-backup.log
if bash "$repo_dir/dujiao-backup.sh" status; then
  printf 'Symlinked log file was unexpectedly accepted.\n' >&2
  exit 1
fi
test "$(< /tmp/dujiao-log-symlink-target)" = 'do-not-touch'
rm -f -- /opt/dujiao-backup/logs/dujiao-backup.log
mv /opt/dujiao-backup/logs/dujiao-backup.log.real /opt/dujiao-backup/logs/dujiao-backup.log

printf 'OSS integration: OK\n'
