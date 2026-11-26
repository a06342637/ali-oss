#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d /tmp/dujiao-backup-discovery.XXXXXX)"
# Isolate every write and feed the real prompt functions through a test FD.
sed -e '$d' \
  -e "s|readonly INSTALL_DIR=.*|readonly INSTALL_DIR=\"$fixture/runtime\"|" \
  -e 's|< /dev/tty|<\&9|g' \
  "$repo_dir/dujiao-backup.sh" > "$fixture/subject.sh"
# shellcheck disable=SC1091
source "$fixture/subject.sh"
trap 'rm -rf -- "$fixture"' EXIT
require_tty() { :; }
mkdir -p "$BACKUP_DIR" "$TMP_DIR"

official="$fixture/official"
binary="$fixture/binary"
other="$fixture/other"
mkdir -p "$official/config" "$official/data/db" "$official/data/uploads" \
  "$binary/db" "$binary/uploads" "$other/config" "$other/data/uploads"
printf 'database:\n  driver: "sqlite" # active\n  dsn: /app/db/dujiao.db\nqueue:\n  driver: postgres\n' > "$official/config/config.yml"
printf 'services: {}\n' > "$official/docker-compose.sqlite.yml"
printf 'services: {}\n' > "$official/docker-compose.postgres.yml"
printf 'TAG=latest\n' > "$official/.env"
printf "database:\n  driver: 'sqlite'\n  dsn: ./db/dujiao.db\n" > "$binary/config.yml"
printf 'database:\n  driver: postgres\n' > "$other/config/config.yml"
printf 'image-data\n' > "$official/data/uploads/item.jpg"
printf 'binary-image\n' > "$binary/uploads/item.jpg"
sqlite3 "$official/data/db/dujiao.db" 'CREATE TABLE seed(id INTEGER);'
sqlite3 "$binary/db/dujiao.db" 'CREATE TABLE seed(id INTEGER);'

# Docker metadata uses custom names and an unrelated PostgreSQL instance.
docker() {
  if [[ "$1" == ps ]]; then printf '%s\n' app database unrelated; return; fi
  [[ "$1" == inspect ]] || return 1
  [[ "${2:-}" == -f || "${2:-}" == --format ]] || return 0
  local format="$3" id="$4"
  case "$format" in
    *Config.Image*)
      [[ "$id" != app && "$id" != shop-api ]] || { printf 'dujiaonext/dujiao-next:latest\n'; return; }
      printf 'postgres:16-alpine\n' ;;
    *Config.WorkingDir*) printf '/app\n' ;;
    *project.working_dir*)
      [[ "$id" != unrelated ]] || { printf '%s\n' "$other"; return; }
      printf '%s\n' "$official" ;;
    *project.config_files*) printf '%s\n' "$official/docker-compose.sqlite.yml" ;;
    *com.docker.compose.project*)
      [[ "$id" != unrelated ]] || { printf 'other-shop\n'; return; }
      printf 'shop\n' ;;
    *Mounts*)
      if [[ "$format" == *printf* ]]; then
        printf '%s\t%s\n' "$official/config/config.yml" /app/config.yml \
          "$official/data/db" /app/db "$official/data/uploads" /app/uploads
      elif [[ "$format" == *'/app/config.yml'* ]]; then
        [[ "$id" != app && "$id" != shop-api ]] || printf '%s\n' "$official/config/config.yml"
      elif [[ "$format" == *'/app/uploads'* ]]; then
        printf '%s\n' "$official/data/uploads"
      elif [[ "$format" == *'/var/lib/postgresql/data'* ]]; then
        [[ "$id" != unrelated ]] || { printf '%s\n' "$other/data/postgres"; return; }
        printf '%s\n' "$official/data/postgres"
      fi ;;
    *State.Running*) printf 'true\n' ;;
    *Name*)
      case "$id" in
        app|shop-api) printf '/shop-api\n' ;;
        database|shop-db) printf '/shop-db\n' ;;
        unrelated) printf '/dujiaonext-postgres\n' ;;
      esac ;;
    *) return 1 ;;
  esac
}
systemctl() { return 1; }

[[ "$(detect_deployment_mode "$official")" == sqlite ]]
[[ "$(detect_deployment_mode "$binary")" == sqlite ]]
[[ "$(detect_deployment_mode "$other")" == postgres ]]
[[ "$(detect_dujiao_app_container "$official")" == shop-api ]]
[[ "$(detect_dujiao_postgres_container "$official" shop-api)" == shop-db ]]
[[ "$(dujiao_container_database_source shop-api "$official/config/config.yml")" == "$official/data/db/dujiao.db" ]]
[[ "$(detect_dujiao_compose_file "$official" sqlite)" == "$official/docker-compose.sqlite.yml" ]]
[[ "$(detect_dujiao_compose_file "$official" postgres)" == "$official/docker-compose.postgres.yml" ]]
APP_DIR="$official"
dujiao_directory_candidates | grep -Fxq "$official"

# Blank/whitespace accepts the detected value; typed values replace it.
answer=""
exec 9<<< ''
prompt_text answer '目录' "$official" 0
[[ "$answer" == "$official" ]]
exec 9<<< "  $binary  "
prompt_text answer '目录' "$official" 0
[[ "$answer" == "$binary" ]]
exec 9<<< '   '
prompt_choice answer '部署模式' 1 2 1 1
[[ "$answer" == 1 ]]
exec 9<<< 2
prompt_choice answer '部署模式' 1 2 1 1
[[ "$answer" == 2 ]]
exec 9<<< $'\n2'
prompt_choice answer '未识别的部署模式' 1 2 1
[[ "$answer" == 2 ]]

# Real wizard: accepting one discovery and overriding it to the binary layout.
dujiao_directory_candidates() { printf '%s\n' "$official"; }
exec 9<<< "$binary"$'\n'
choose_deployment_interactive
[[ "$APP_DIR" == "$binary" && "$DEPLOY_MODE" == sqlite ]]
[[ -z "$DUJIAO_CONTAINER" && -z "$COMPOSE_FILE" ]]
[[ "$DB_FILE" == "$binary/db/dujiao.db" && "$DUJIAO_UPLOAD_DIR" == "$binary/uploads" ]]

# PostgreSQL defaults come from this project's custom container name.
cp "$official/config/config.yml" "$fixture/sqlite-config.yml"
printf 'database:\n  driver: postgres\n' > "$official/config/config.yml"
exec 9<<< $'\n\n'
choose_deployment_interactive
[[ "$APP_DIR" == "$official" && "$DEPLOY_MODE" == postgres && "$PG_CONTAINER" == shop-db ]]
cp "$fixture/sqlite-config.yml" "$official/config/config.yml"

# Relative container paths also resolve through the database mount.
printf 'database:\n  driver: sqlite\n  dsn: ./db/custom.db?cache=shared\n' > "$fixture/relative-config.yml"
[[ "$(dujiao_container_database_source shop-api "$fixture/relative-config.yml")" == "$official/data/db/custom.db" ]]
# Multiple generic Compose files must not silently discard part of the setup.
printf 'services: {}\n' > "$binary/compose.yml"
printf 'services: {}\n' > "$binary/compose.yaml"
DUJIAO_CONTAINER=""
if detect_dujiao_compose_file "$binary" sqlite; then
  printf 'Ambiguous Compose files were accepted.\n' >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
rm -f -- "$binary/compose.yml" "$binary/compose.yaml"
# An unrelated container cannot decide an ambiguous deployment.
printf 'queue:\n  driver: postgres\n' > "$official/config/config.yml"
if detect_deployment_mode "$official"; then
  printf 'Unrelated PostgreSQL instance decided the deployment.\n' >&2
  exit 1
fi
cp "$fixture/sqlite-config.yml" "$official/config/config.yml"

# Build and restore actual SQLite archives for both official layouts.
for app_dir in "$official" "$binary"; do
  set_config_defaults
  APP_DIR="$app_dir"
  DEPLOY_MODE=sqlite
  set_deployment_paths
  sqlite3 "$DB_FILE" "CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO products(name) VALUES ('restored');"
  validate_deployment
  create_dujiao_archive
  verify_dujiao_archive_file "$CREATED_ARCHIVE"
  extract="$fixture/extract-$(basename "$app_dir")"
  mkdir -p "$extract"
  tar -xf "$CREATED_ARCHIVE" -C "$extract"
  [[ "$(sqlite3 "$extract/database.sqlite" 'SELECT name FROM products;')" == restored ]]
  tar -xzf "$extract/uploads.tar.gz" -C "$extract"
  cmp "$app_dir/${DUJIAO_UPLOAD_DIR#"$app_dir/"}/item.jpg" "$extract/uploads/item.jpg"
  tar -xzf "$extract/config.tar.gz" -C "$extract"
  config_member="${DUJIAO_CONFIG_FILE#"$app_dir/"}"
  cmp "$DUJIAO_CONFIG_FILE" "$extract/$config_member"
done

# Saved choices must survive reload, including custom SQLite paths.
APP_DIR="$binary"
DEPLOY_MODE=sqlite
DUJIAO_CONFIG_FILE="$binary/config.yml"
DUJIAO_UPLOAD_DIR="$binary/uploads"
DB_FILE="$binary/db/custom.db"
COMPOSE_FILE=""
{
  for key in APP_DIR DEPLOY_MODE DUJIAO_CONFIG_FILE DUJIAO_UPLOAD_DIR DB_FILE COMPOSE_FILE; do
    write_config_value "$key"
  done
} > "$CONFIG_FILE"
load_config
[[ "$DB_FILE" == "$binary/db/custom.db" && -z "$COMPOSE_FILE" ]]

# PostgreSQL must dump the application's current database, not the container's
# initial POSTGRES_DB. Quoted credentials may contain misleading dbname text.
[[ "$(dujiao_libpq_value "host=db password='text dbname=wrong' dbname='orders v2'" dbname)" == 'orders v2' ]]
postgres_app="$fixture/postgres"
mkdir -p "$postgres_app/uploads" "$fixture/pg-bin"
printf "database:\n  driver: postgres\n  dsn: host=db user=app password='text dbname=wrong' dbname=orders_v2\n" > "$postgres_app/config.yml"
cat > "$fixture/pg-bin/pg_dump" <<'DUMP'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_PG_ARGS"
printf 'PGDMP-test-payload\n'
DUMP
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/pg-bin/pg_restore"
chmod 0755 "$fixture/pg-bin/pg_dump" "$fixture/pg-bin/pg_restore"
export TEST_PG_ARGS="$fixture/pg-args"
export PATH="$fixture/pg-bin:$PATH"
docker() {
  if [[ "$1" == inspect ]]; then
    [[ "${2:-}" != -f ]] || printf 'true\n'
    return 0
  fi
  [[ "$1" == exec ]] || return 1
  shift
  [[ "${1:-}" != -i ]] || shift
  shift
  POSTGRES_USER=postgres POSTGRES_DB=initial_database "$@"
}
set_config_defaults
APP_DIR="$postgres_app"
DEPLOY_MODE=postgres
set_deployment_paths
validate_deployment
create_dujiao_archive
grep -qx -- '--dbname=orders_v2' "$TEST_PG_ARGS"
! grep -q 'initial_database' "$TEST_PG_ARGS"
before_type="$BACKUP_TYPE"
verify_dujiao_archive_file "$CREATED_ARCHIVE"
[[ "$BACKUP_TYPE" == "$before_type" && "$APP_DIR" == "$postgres_app" ]]
printf 'database:\n  driver: postgres\n  dsn: postgresql://app:secret@db/old?dbname=orders%%5Fv3\n' > "$postgres_app/config.yml"
[[ "$(dujiao_postgres_database_name)" == orders_v3 ]]
printf '\ndujiao-discovery: OK\n'
