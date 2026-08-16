#!/usr/bin/env bash
# shellcheck disable=SC2029
set -Eeuo pipefail

[[ "${DUJIAO_INTEGRATION_TEST:-}" == "1" ]] || {
  printf 'Refusing to modify /opt/dujiao-backup outside the integration-test environment.\n' >&2
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="/tmp/dujiao-next-sftp-test"
fake_bin="/tmp/dujiao-backup-sftp-bin"
config_tmp="/tmp/dujiao-backup-sftp-config"
ssh_host="${TEST_SFTP_HOST:-127.0.0.1}"
ssh_port="${TEST_SFTP_PORT:-22222}"
ssh_user="${TEST_SFTP_USER:-backup}"
ssh_password="${TEST_SFTP_PASSWORD:-test-password}"
remote_dir="/config/dujiao-backups"
key_file="/opt/dujiao-backup/keys/sftp_ed25519"
known_hosts="/opt/dujiao-backup/keys/known_hosts"

rm -rf -- "$app_dir" "$fake_bin"
rm -f -- "$config_tmp"
rm -rf -- /opt/dujiao-backup
install -d -m 0700 /opt/dujiao-backup /opt/dujiao-backup/keys
install -d -m 0700 /root/.ssh
mkdir -p "$app_dir/config" "$app_dir/data/db" "$app_dir/data/uploads" "$fake_bin"
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

ssh-keygen -q -t ed25519 -N '' -f "$key_file"
for _attempt in $(seq 1 60); do
  if ssh-keyscan -T 2 -p "$ssh_port" "$ssh_host" > "$known_hosts" 2>/dev/null; then break; fi
  sleep 1
done
test -s "$known_hosts"
chmod 0600 "$key_file" "$known_hosts"
export SSHPASS="$ssh_password"
sshpass -e ssh-copy-id \
  -i "$key_file.pub" \
  -p "$ssh_port" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts" \
  "$ssh_user@$ssh_host"
unset SSHPASS

ssh_options=(
  -i "$key_file"
  -p "$ssh_port"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts"
)
ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "mkdir -p '$remote_dir'; chmod 700 '$remote_dir'"

printf '%s\n' \
  "APP_DIR=$app_dir" \
  'DEPLOY_MODE=sqlite' \
  'MAX_BACKUPS=2' \
  'OSS_ENABLED=0' \
  'SFTP_ENABLED=1' \
  "SFTP_HOST=$ssh_host" \
  "SFTP_PORT=$ssh_port" \
  "SFTP_USER=$ssh_user" \
  "SFTP_REMOTE_DIR=$remote_dir" \
  'SFTP_KEY_FILE=/etc/passwd' \
  'SFTP_KNOWN_HOSTS=/etc/group' > "$config_tmp"
install -m 0600 "$config_tmp" /opt/dujiao-backup/config.conf

passwd_mode_before="$(stat -c %a /etc/passwd)"
group_mode_before="$(stat -c %a /etc/group)"

run_backup() {
  env "PATH=$fake_bin:$PATH" bash "$repo_dir/dujiao-backup.sh" backup
}

run_backup
test "$(stat -c %a /etc/passwd)" = "$passwd_mode_before"
test "$(stat -c %a /etc/group)" = "$group_mode_before"
first_archive="$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' -printf '%f\n' | sort | head -n 1)"
ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "rm -f '$remote_dir/$first_archive'"

sleep 1
sqlite3 "$app_dir/data/db/dujiao.db" 'INSERT INTO products(name) VALUES ("two");'
run_backup
ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "test -f '$remote_dir/$first_archive'"
grep -q 'SFTP 中缺少本地保留备份，正在自动补传' /opt/dujiao-backup/logs/dujiao-backup.log

ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "printf remote-only > '$remote_dir/dujiao-next-20000101-000000.tar'"
sleep 1
sqlite3 "$app_dir/data/db/dujiao.db" 'INSERT INTO products(name) VALUES ("three");'
run_backup

test "$(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' | wc -l)" -eq 2
remote_count="$(ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" \
  "find '$remote_dir' -maxdepth 1 -name 'dujiao-next-*.tar' | wc -l")"
test "$remote_count" -eq 2
ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "test ! -e '$remote_dir/dujiao-next-20000101-000000.tar'"
while IFS= read -r local_name; do
  ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" "test -f '$remote_dir/$local_name'"
  local_sha="$(sha256sum "/opt/dujiao-backup/backups/$local_name" | awk '{print $1}')"
  remote_sha="$(ssh -n "${ssh_options[@]}" "$ssh_user@$ssh_host" \
    "sha256sum '$remote_dir/$local_name' | awk '{print \$1}'")"
  test "$local_sha" = "$remote_sha"
done < <(find /opt/dujiao-backup/backups -maxdepth 1 -name 'dujiao-next-*.tar' -printf '%f\n' | sort)

export PATH="$fake_bin:$PATH"
printf '%s\n' \
  5 \
  6 \
  '/config/dujiao-backups-menu' \
  '' \
  2 \
  y \
  '' \
  1 \
  '' \
  0 \
  0 | timeout 90s script -qec "bash '$repo_dir/dujiao-backup.sh' configure" /dev/null
(
  # shellcheck disable=SC1091
  source /opt/dujiao-backup/config.conf
  test "$OSS_ENABLED" = "0"
  test "$SFTP_ENABLED" = "1"
  test "$SFTP_REMOTE_DIR" = "/config/dujiao-backups-menu"
  test "$SFTP_KEY_FILE" = "/opt/dujiao-backup/keys/sftp_ed25519"
  test "$SFTP_KNOWN_HOSTS" = "/opt/dujiao-backup/keys/known_hosts"
)

printf 'SFTP integration: OK\n'
