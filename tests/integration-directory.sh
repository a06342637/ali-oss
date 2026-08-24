#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${DUJIAO_INTEGRATION_TEST:-0}" == "1" ]] || {
  printf 'Refusing to run destructive integration test without DUJIAO_INTEGRATION_TEST=1.\n' >&2
  exit 1
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="/tmp/server-backup-directory source"
restore_dir="/tmp/server-backup-directory-restore"
config_tmp="/tmp/server-backup-directory-config"
status_output="/tmp/server-backup-directory-status"
history_output="/tmp/server-backup-directory-history"

cleanup_test() {
  rm -rf -- "$source_dir" "$restore_dir"
  rm -f -- "$config_tmp" "$status_output" "$history_output"
  rm -rf -- /opt/dujiao-backup
}
trap cleanup_test EXIT
cleanup_test
install -d -m 0700 /opt/dujiao-backup/logs "$source_dir/nested" "$restore_dir"
printf 'first-version\n' > "$source_dir/nested/data.txt"
printf 'file with spaces\n' > "$source_dir/report final.txt"

{
  printf 'CONFIG_VERSION=1\n'
  printf 'BACKUP_TYPE=directory\n'
  printf 'CUSTOM_DIR_NAME=%q\n' '业务附件目录'
  printf 'CUSTOM_DIR=%q\n' "$source_dir"
  printf 'MAX_BACKUPS=1\n'
  printf 'OSS_ENABLED=0\n'
  printf 'SFTP_ENABLED=0\n'
} > "$config_tmp"
install -m 0600 "$config_tmp" /opt/dujiao-backup/config.conf

bash "$repo_dir/dujiao-backup.sh" backup
first_archive="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'directory-*.tar' -print -quit)"
test -n "$first_archive"
bash "$repo_dir/dujiao-backup.sh" verify "$first_archive"

tar -xf "$first_archive" -C "$restore_dir"
tar -xzf "$restore_dir/directory.tar.gz" -C "$restore_dir"
test "$(cat "$restore_dir/nested/data.txt")" = "first-version"
test "$(cat "$restore_dir/report final.txt")" = "file with spaces"
grep -qx 'application=custom-directory' "$restore_dir/manifest.txt"
grep -Fqx "source_directory=$source_dir" "$restore_dir/manifest.txt"

sleep 1
printf 'second-version\n' > "$source_dir/nested/data.txt"
bash "$repo_dir/dujiao-backup.sh" backup
test "$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'directory-*.tar' | wc -l)" -eq 1
latest="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'directory-*.tar' -print -quit)"
bash "$repo_dir/dujiao-backup.sh" verify "$latest"

test "$(awk -F '\t' '$5 == "success" {count++} END {print count+0}' /opt/dujiao-backup/state/backup-history.tsv)" -eq 2
bash "$repo_dir/dujiao-backup.sh" status > "$status_output"
grep -Fq '业务附件目录' "$status_output"
bash "$repo_dir/dujiao-backup.sh" history > "$history_output"
grep -Fq '最近备份执行记录' "$history_output"
grep -Fq '本地归档历史' "$history_output"
grep -Fq '自定义目录（业务附件目录）' "$history_output"

ln -s /etc/passwd "$source_dir/unsafe-link"
if bash "$repo_dir/dujiao-backup.sh" backup; then
  printf 'Directory backup unexpectedly accepted a symbolic link.\n' >&2
  exit 1
fi
rm -f -- "$source_dir/unsafe-link"
test "$(awk -F '\t' '$5 == "failed" {count++} END {print count+0}' /opt/dujiao-backup/state/backup-history.tsv)" -eq 1

printf 'Directory integration: OK\n'
