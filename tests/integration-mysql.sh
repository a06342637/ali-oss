#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${DUJIAO_INTEGRATION_TEST:-0}" == "1" ]] || {
  printf 'Refusing to run destructive integration test without DUJIAO_INTEGRATION_TEST=1.\n' >&2
  exit 1
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="server-backup-mariadb-test"
port="23306"
password="integration-secret-42"
config_tmp="/tmp/server-backup-mysql-config"
extract_dir="/tmp/server-backup-mysql-extract"
status_output="/tmp/server-backup-mysql-status"
history_output="/tmp/server-backup-mysql-history"

cleanup_test() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf -- "$extract_dir" /opt/dujiao-backup
  rm -f -- "$config_tmp" "$status_output" "$history_output"
}
trap cleanup_test EXIT
cleanup_test
install -d -m 0700 /opt/dujiao-backup/logs "$extract_dir"

docker run -d --name "$container" \
  -p "127.0.0.1:$port:3306" \
  -e MARIADB_ROOT_PASSWORD="$password" \
  -e MARIADB_ROOT_HOST='%' \
  -e MARIADB_DATABASE=shop \
  mariadb:11 >/dev/null
for _attempt in $(seq 1 120); do
  if docker exec "$container" mariadb -uroot -p"$password" -Nse 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
test "$(docker exec "$container" mariadb -uroot -p"$password" -Nse 'SELECT 1')" = "1"

docker exec "$container" mariadb -uroot -p"$password" shop -e \
  "CREATE TABLE orders(id INT PRIMARY KEY, note VARCHAR(100)); INSERT INTO orders VALUES (1, 'backup-row');"

write_config() {
  local mode="$1"
  {
    printf 'CONFIG_VERSION=1\n'
    printf 'BACKUP_TYPE=mysql\n'
    printf 'MYSQL_TASK_NAME=%q\n' '订单数据库'
    printf 'MYSQL_MODE=%q\n' "$mode"
    if [[ "$mode" == "host" ]]; then
      printf 'MYSQL_CONNECTION=tcp\n'
      printf 'MYSQL_HOST=127.0.0.1\n'
      printf 'MYSQL_PORT=%s\n' "$port"
      printf 'MYSQL_CONTAINER=%q\n' ''
    else
      printf 'MYSQL_CONNECTION=socket\n'
      printf 'MYSQL_HOST=127.0.0.1\n'
      printf 'MYSQL_PORT=3306\n'
      printf 'MYSQL_CONTAINER=%q\n' "$container"
    fi
    printf 'MYSQL_SOCKET=/run/mysqld/mysqld.sock\n'
    printf 'MYSQL_USER=root\n'
    printf 'MYSQL_PASSWORD=%q\n' "$password"
    printf 'MYSQL_DATABASE_MODE=selected\n'
    printf 'MYSQL_DATABASES=shop\n'
    printf 'MAX_BACKUPS=3\n'
    printf 'OSS_ENABLED=0\n'
    printf 'SFTP_ENABLED=0\n'
  } > "$config_tmp"
  install -m 0600 "$config_tmp" /opt/dujiao-backup/config.conf
}

write_config host
bash "$repo_dir/dujiao-backup.sh" backup
first_archive="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'mysql-*.tar' -print -quit)"
test -n "$first_archive"
bash "$repo_dir/dujiao-backup.sh" verify "$first_archive"
tar -xf "$first_archive" -C "$extract_dir"
gzip -cd "$extract_dir/database.sql.gz" > "$extract_dir/database.sql"
grep -Fq 'backup-row' "$extract_dir/database.sql"
grep -qx 'application=mysql' "$extract_dir/manifest.txt"
grep -qx 'databases=shop' "$extract_dir/manifest.txt"

# Perform a real restore check from the generated logical dump.
docker exec "$container" mariadb -uroot -p"$password" -e 'DROP DATABASE shop;'
gzip -cd "$extract_dir/database.sql.gz" \
  | docker exec -i "$container" mariadb -uroot -p"$password"
test "$(docker exec "$container" mariadb -uroot -p"$password" -Nse 'SELECT note FROM shop.orders WHERE id=1')" = 'backup-row'

# Exercise the password-safe Docker execution path as well.
sleep 1
write_config docker
# Ensure the configured account works over the container-local Unix socket as well.
docker exec "$container" mariadb -uroot -p"$password" -Nse 'SELECT VERSION()' >/dev/null
bash "$repo_dir/dujiao-backup.sh" backup
latest="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'mysql-*.tar' | sort | tail -n 1)"
bash "$repo_dir/dujiao-backup.sh" verify "$latest"
test "$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'mysql-*.tar' | wc -l)" -eq 2
test "$(awk -F '\t' '$5 == "success" {count++} END {print count+0}' /opt/dujiao-backup/state/backup-history.tsv)" -eq 2
test "$(stat -c %a /opt/dujiao-backup/config.conf)" = 600
if grep -Fq "$password" /opt/dujiao-backup/logs/dujiao-backup.log; then
  printf 'MySQL password leaked into the backup log.\n' >&2
  exit 1
fi
bash "$repo_dir/dujiao-backup.sh" status > "$status_output"
grep -Fq '订单数据库' "$status_output"
bash "$repo_dir/dujiao-backup.sh" history > "$history_output"
grep -Fq 'MySQL（订单数据库）' "$history_output"

printf 'MySQL integration: OK\n'
