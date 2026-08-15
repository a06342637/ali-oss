#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly PROGRAM_NAME="Dujiao-Next Backup Manager"
readonly VERSION="1.1.4"
readonly REPOSITORY_URL="https://github.com/a06342637/ali-oss"
readonly RAW_SCRIPT_URL="https://raw.githubusercontent.com/a06342637/ali-oss/main/dujiao-backup.sh"
readonly INSTALL_DIR="/opt/dujiao-backup"
readonly INSTALLED_SCRIPT="$INSTALL_DIR/dujiao-backup.sh"
readonly CONFIG_FILE="$INSTALL_DIR/config.conf"
readonly LOG_DIR="$INSTALL_DIR/logs"
readonly LOG_FILE="$LOG_DIR/dujiao-backup.log"
readonly BACKUP_DIR="$INSTALL_DIR/backups"
readonly KEY_DIR="$INSTALL_DIR/keys"
readonly STATE_DIR="$INSTALL_DIR/state"
readonly TMP_DIR="$INSTALL_DIR/tmp"
readonly LOCK_FILE="/run/lock/dujiao-backup.lock"
readonly COMMAND_LINK="/usr/local/bin/dujiao-backup"
readonly SERVICE_FILE="/etc/systemd/system/dujiao-backup.service"
readonly TIMER_FILE="/etc/systemd/system/dujiao-backup.timer"
readonly OSSUTIL_VERSION="2.3.0"
readonly LOG_MAX_BYTES="10485760"
readonly LOG_ROTATIONS="5"

SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRENT_STEP="启动程序"
LOG_CAPTURED=0
ERROR_HANDLED=0
ACTIVE_PARTIAL=""
declare -a TEMP_PATHS=()

CONFIG_VERSION="1"
APP_DIR="/opt/dujiao-next"
DEPLOY_MODE=""
COMPOSE_FILE=""
DB_FILE=""
PG_CONTAINER="dujiaonext-postgres"
MAX_BACKUPS="100"
OSS_ENABLED="0"
OSS_ACCESS_KEY_ID=""
OSS_ACCESS_KEY_SECRET=""
OSS_REGION=""
OSS_ENDPOINT=""
OSS_BUCKET=""
OSS_PREFIX=""
OSS_DELETE_ALL_VERSIONS="0"
SFTP_ENABLED="0"
SFTP_HOST=""
SFTP_PORT="22"
SFTP_USER="root"
SFTP_REMOTE_DIR="/root/dujiao-backups"
SFTP_KEY_FILE="$KEY_DIR/sftp_ed25519"
SFTP_KNOWN_HOSTS="$KEY_DIR/known_hosts"
TIMER_ENABLED="0"
TIMER_DAYS="0"
TIMER_HOURS="6"
TIMER_MINUTES="0"

now() { date --iso-8601=seconds; }

write_log_only() {
  local line="$1"
  if [[ "$LOG_CAPTURED" -eq 0 && -d "$LOG_DIR" && ! -L "$LOG_DIR" \
    && -f "$LOG_FILE" && ! -L "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log_message() {
  local level="$1"
  local line
  shift
  line="[$(now)] [$level] $*"
  printf '%s\n' "$line"
  write_log_only "$line"
}

info() { log_message "INFO" "$*"; }
warn() { log_message "WARN" "$*"; }
success() { log_message "SUCCESS" "$*"; }
error() { log_message "ERROR" "$*" >&2; }

heading() {
  printf '\n============================================================\n'
  printf '%s\n' "$*"
  printf '============================================================\n'
}

die() {
  ERROR_HANDLED=1
  error "失败原因：$*"
  exit 1
}

on_error() {
  local rc="$1"
  local line_no="$2"
  local failed_command="$3"
  set +e
  if [[ "$ERROR_HANDLED" -eq 0 ]]; then
    ERROR_HANDLED=1
    error "失败原因：$CURRENT_STEP"
    error "详细信息：退出码 $rc，第 $line_no 行，命令：$failed_command"
  fi
  exit "$rc"
}

cleanup() {
  local path
  set +e
  if [[ -n "$ACTIVE_PARTIAL" && "$ACTIVE_PARTIAL" == "$BACKUP_DIR"/.*.partial ]]; then
    rm -f -- "$ACTIVE_PARTIAL"
  fi
  for path in "${TEMP_PATHS[@]:-}"; do
    case "$path" in
      "$TMP_DIR"/*|/tmp/dujiao-backup-*) rm -rf -- "$path" ;;
    esac
  done
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

register_temp() { TEMP_PATHS+=("$1"); }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行。"
}

require_tty() {
  [[ -r /dev/tty ]] || die "此操作需要交互式终端，请直接在 SSH 或宝塔终端中运行。"
}

ensure_runtime_dirs() {
  local path
  for path in "$INSTALL_DIR" "$LOG_DIR" "$BACKUP_DIR" "$KEY_DIR" "$STATE_DIR" "$TMP_DIR"; do
    [[ ! -L "$path" ]] || die "运行目录不能是符号链接：$path"
  done
  install -d -o root -g root -m 0700 \
    "$INSTALL_DIR" "$LOG_DIR" "$BACKUP_DIR" "$KEY_DIR" "$STATE_DIR" "$TMP_DIR"
  [[ ! -L "$LOG_FILE" ]] || die "日志文件不能是符号链接：$LOG_FILE"
  touch "$LOG_FILE"
  chown root:root "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

rotate_logs_if_needed() {
  local size index
  [[ -f "$LOG_FILE" ]] || return 0
  size="$(stat -c %s "$LOG_FILE")"
  [[ "$size" -ge "$LOG_MAX_BYTES" ]] || return 0
  rm -f -- "$LOG_FILE.$LOG_ROTATIONS"
  for ((index = LOG_ROTATIONS - 1; index >= 1; index--)); do
    if [[ -f "$LOG_FILE.$index" ]]; then
      mv -f -- "$LOG_FILE.$index" "$LOG_FILE.$((index + 1))"
    fi
  done
  mv -f -- "$LOG_FILE" "$LOG_FILE.1"
  touch "$LOG_FILE"
  chown root:root "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

start_log_capture() {
  ensure_runtime_dirs
  if [[ "$LOG_CAPTURED" -eq 0 ]]; then
    rotate_logs_if_needed
    exec > >(tee -a "$LOG_FILE") 2>&1
    LOG_CAPTURED=1
  fi
}

pause_for_enter() {
  if [[ -r /dev/tty ]]; then
    printf '\n按回车键继续...' > /dev/tty
    IFS= read -r _ < /dev/tty || true
  fi
}

prompt_text() {
  local variable_name="$1"
  local prompt="$2"
  local default_value="$3"
  local required="$4"
  local value
  require_tty
  while true; do
    if [[ -n "$default_value" ]]; then
      printf '%s [%s]: ' "$prompt" "$default_value" > /dev/tty
    else
      printf '%s: ' "$prompt" > /dev/tty
    fi
    IFS= read -r value < /dev/tty
    [[ -n "$value" ]] || value="$default_value"
    if [[ "$required" -eq 1 && -z "$value" ]]; then
      printf '此项不能为空，请重新输入。\n' > /dev/tty
      continue
    fi
    printf -v "$variable_name" '%s' "$value"
    return 0
  done
}

prompt_secret() {
  local variable_name="$1"
  local prompt="$2"
  local existing_value="$3"
  local value
  require_tty
  while true; do
    if [[ -n "$existing_value" ]]; then
      printf '%s（直接回车保留现有值）: ' "$prompt" > /dev/tty
    else
      printf '%s: ' "$prompt" > /dev/tty
    fi
    IFS= read -r -s value < /dev/tty
    printf '\n' > /dev/tty
    [[ -n "$value" ]] || value="$existing_value"
    if [[ -z "$value" ]]; then
      printf '此项不能为空，请重新输入。\n' > /dev/tty
      continue
    fi
    printf -v "$variable_name" '%s' "$value"
    return 0
  done
}

prompt_yes_no() {
  local variable_name="$1"
  local prompt="$2"
  local default_value="$3"
  local suffix answer
  require_tty
  [[ "$default_value" == "1" ]] && suffix="Y/n" || suffix="y/N"
  while true; do
    printf '%s [%s]: ' "$prompt" "$suffix" > /dev/tty
    IFS= read -r answer < /dev/tty
    answer="${answer,,}"
    if [[ -z "$answer" ]]; then
      printf -v "$variable_name" '%s' "$default_value"
      return 0
    fi
    case "$answer" in
      y|yes|1|是)
        printf -v "$variable_name" '%s' "1"
        return 0
        ;;
      n|no|0|否)
        printf -v "$variable_name" '%s' "0"
        return 0
        ;;
      *) printf '请输入 y 或 n。\n' > /dev/tty ;;
    esac
  done
}

prompt_choice() {
  local variable_name="$1"
  local prompt="$2"
  local minimum="$3"
  local maximum="$4"
  local default_value="$5"
  local value
  require_tty
  while true; do
    printf '%s [%s]: ' "$prompt" "$default_value" > /dev/tty
    IFS= read -r value < /dev/tty
    value="${value:-$default_value}"
    if validate_uint_between "$value" "$minimum" "$maximum"; then
      printf -v "$variable_name" '%s' "$value"
      return 0
    fi
    printf '请输入 %s 到 %s 之间的数字。\n' "$minimum" "$maximum" > /dev/tty
  done
}

prompt_uint_range() {
  local variable_name="$1"
  local prompt="$2"
  local default_value="$3"
  local maximum="$4"
  local value
  require_tty
  while true; do
    printf '%s [%s]: ' "$prompt" "$default_value" > /dev/tty
    IFS= read -r value < /dev/tty
    value="${value:-$default_value}"
    if validate_uint_between "$value" 0 "$maximum"; then
      printf -v "$variable_name" '%s' "$value"
      return 0
    fi
    printf '请输入 0 到 %s 之间的整数。\n' "$maximum" > /dev/tty
  done
}

set_config_defaults() {
  CONFIG_VERSION="1"
  APP_DIR="/opt/dujiao-next"
  DEPLOY_MODE=""
  COMPOSE_FILE=""
  DB_FILE=""
  PG_CONTAINER="dujiaonext-postgres"
  MAX_BACKUPS="100"
  OSS_ENABLED="0"
  OSS_ACCESS_KEY_ID=""
  OSS_ACCESS_KEY_SECRET=""
  OSS_REGION=""
  OSS_ENDPOINT=""
  OSS_BUCKET=""
  OSS_PREFIX=""
  OSS_DELETE_ALL_VERSIONS="0"
  SFTP_ENABLED="0"
  SFTP_HOST=""
  SFTP_PORT="22"
  SFTP_USER="root"
  SFTP_REMOTE_DIR="/root/dujiao-backups"
  SFTP_KEY_FILE="$KEY_DIR/sftp_ed25519"
  SFTP_KNOWN_HOSTS="$KEY_DIR/known_hosts"
  TIMER_ENABLED="0"
  TIMER_DAYS="0"
  TIMER_HOURS="6"
  TIMER_MINUTES="0"
}

load_config() {
  set_config_defaults
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || return 1
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
  fi
  # shellcheck disable=SC1090
  if ! source "$CONFIG_FILE"; then
    return 1
  fi
  APP_DIR="$(normalize_absolute_path "$APP_DIR")"
  SFTP_REMOTE_DIR="$(normalize_absolute_path "$SFTP_REMOTE_DIR")"
  # 密钥文件属于管理器内部状态，不接受配置文件改写到任意系统路径。
  SFTP_KEY_FILE="$KEY_DIR/sftp_ed25519"
  SFTP_KNOWN_HOSTS="$KEY_DIR/known_hosts"
  validate_loaded_config
  set_deployment_paths
}

write_config_value() {
  local name="$1"
  printf '%s=%q\n' "$name" "${!name}"
}

save_config() {
  ensure_runtime_dirs
  local temporary="$CONFIG_FILE.new.$$"
  CURRENT_STEP="写入配置文件"
  {
    printf '# Dujiao-Next Backup Manager v%s\n' "$VERSION"
    printf '# 本文件含 OSS 密钥，只允许 root 读取。请优先通过管理菜单修改。\n'
    printf '# SFTP 登录密码不会保存；这里只保存专用 SSH 私钥路径。\n\n'
    printf 'CONFIG_VERSION=%q\n' "$CONFIG_VERSION"
    write_config_value APP_DIR
    write_config_value DEPLOY_MODE
    write_config_value COMPOSE_FILE
    write_config_value DB_FILE
    write_config_value PG_CONTAINER
    write_config_value MAX_BACKUPS
    write_config_value OSS_ENABLED
    write_config_value OSS_ACCESS_KEY_ID
    write_config_value OSS_ACCESS_KEY_SECRET
    write_config_value OSS_REGION
    write_config_value OSS_ENDPOINT
    write_config_value OSS_BUCKET
    write_config_value OSS_PREFIX
    write_config_value OSS_DELETE_ALL_VERSIONS
    write_config_value SFTP_ENABLED
    write_config_value SFTP_HOST
    write_config_value SFTP_PORT
    write_config_value SFTP_USER
    write_config_value SFTP_REMOTE_DIR
    write_config_value SFTP_KEY_FILE
    write_config_value SFTP_KNOWN_HOSTS
    write_config_value TIMER_ENABLED
    write_config_value TIMER_DAYS
    write_config_value TIMER_HOURS
    write_config_value TIMER_MINUTES
  } > "$temporary"
  chmod 0600 "$temporary"
  chown root:root "$temporary"
  mv -f -- "$temporary" "$CONFIG_FILE"
}

is_safe_absolute_path() {
  local path="$1"
  [[ "$path" == /* ]] || return 1
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$path" != "/" && "$path" != *"/../"* && "$path" != *"/.." \
    && "$path" != *"/./"* && "$path" != *"/." && "$path" != *"//"* ]]
}

validate_uint_between() {
  local value="$1"
  local minimum="$2"
  local maximum="$3"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ && "${#value}" -le 10 ]] || return 1
  (( value >= minimum && value <= maximum ))
}

validate_loaded_config() {
  [[ "$CONFIG_VERSION" == "1" ]] || die "CONFIG_VERSION 配置无效。"
  is_safe_absolute_path "$APP_DIR" || die "APP_DIR 必须是安全的绝对路径。"
  [[ "$PG_CONTAINER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "PG_CONTAINER 配置无效。"
  if ! validate_uint_between "$MAX_BACKUPS" 1 10000; then
    die "MAX_BACKUPS 必须是 1 到 10000。"
  fi
  [[ "$OSS_ENABLED" == "0" || "$OSS_ENABLED" == "1" ]] || die "OSS_ENABLED 配置无效。"
  [[ "$SFTP_ENABLED" == "0" || "$SFTP_ENABLED" == "1" ]] || die "SFTP_ENABLED 配置无效。"
  [[ "$OSS_DELETE_ALL_VERSIONS" == "0" || "$OSS_DELETE_ALL_VERSIONS" == "1" ]] || die "OSS_DELETE_ALL_VERSIONS 配置无效。"
  [[ "$TIMER_ENABLED" == "0" || "$TIMER_ENABLED" == "1" ]] || die "TIMER_ENABLED 配置无效。"
  validate_uint_between "$TIMER_DAYS" 0 3650 || die "TIMER_DAYS 配置无效。"
  validate_uint_between "$TIMER_HOURS" 0 23 || die "TIMER_HOURS 配置无效。"
  validate_uint_between "$TIMER_MINUTES" 0 59 || die "TIMER_MINUTES 配置无效。"
  validate_uint_between "$SFTP_PORT" 1 65535 || die "SFTP_PORT 配置无效。"
  case "$DEPLOY_MODE" in
    sqlite|postgres) ;;
    *) die "DEPLOY_MODE 配置必须是 sqlite 或 postgres。" ;;
  esac
  if [[ "$TIMER_ENABLED" -eq 1 ]]; then
    [[ "$((TIMER_DAYS * 86400 + TIMER_HOURS * 3600 + TIMER_MINUTES * 60))" -ge 60 ]] || die "启用定时时，间隔不能全部为 0。"
  fi
}

normalize_oss_prefix() {
  local prefix="$1"
  while [[ "$prefix" == /* ]]; do prefix="${prefix#/}"; done
  while [[ "$prefix" == */ ]]; do prefix="${prefix%/}"; done
  printf '%s' "$prefix"
}

normalize_absolute_path() {
  local path="$1"
  while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done
  printf '%s' "$path"
}

validate_oss_settings() {
  [[ -n "$OSS_ACCESS_KEY_ID" ]] || die "OSS AccessKey ID 不能为空。"
  [[ -n "$OSS_ACCESS_KEY_SECRET" ]] || die "OSS AccessKey Secret 不能为空。"
  [[ "$OSS_REGION" =~ ^[a-z0-9-]+$ ]] || die "OSS Region ID 格式不正确，例如 cn-hangzhou。"
  [[ "$OSS_ENDPOINT" =~ ^[A-Za-z0-9.-]+$ ]] || die "OSS Endpoint 格式不正确，不要填写 https:// 或路径。"
  [[ "$OSS_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "OSS Bucket 名称格式不正确。"
  OSS_PREFIX="$(normalize_oss_prefix "$OSS_PREFIX")"
  [[ -n "$OSS_PREFIX" ]] || die "OSS 保存目录不能为空。"
  [[ "$OSS_PREFIX" != *".."* && "$OSS_PREFIX" != *"//"* ]] || die "OSS 保存目录不能含有 .. 或连续斜杠。"
  [[ "$OSS_PREFIX" != *[[:cntrl:]]* ]] || die "OSS 保存目录含有不可见控制字符。"
  [[ "$OSS_DELETE_ALL_VERSIONS" == "0" || "$OSS_DELETE_ALL_VERSIONS" == "1" ]] || die "OSS 版本删除设置无效。"
}

validate_sftp_settings() {
  [[ "$SFTP_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "SFTP 主机只能填写 IPv4 地址或普通域名。"
  validate_uint_between "$SFTP_PORT" 1 65535 || die "SFTP 端口必须为 1 到 65535。"
  [[ "$SFTP_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || die "SFTP 用户名格式不正确。"
  is_safe_absolute_path "$SFTP_REMOTE_DIR" || die "SFTP 远端目录必须是安全的绝对路径，不能含空格或 ..。"
  [[ "$SFTP_REMOTE_DIR" != "/root" && "$SFTP_REMOTE_DIR" != "/home" ]] || die "SFTP 远端目录范围过大，请填写专用子目录。"
  is_safe_absolute_path "$SFTP_KEY_FILE" || die "SFTP 私钥路径无效。"
  is_safe_absolute_path "$SFTP_KNOWN_HOSTS" || die "SFTP known_hosts 路径无效。"
}

set_deployment_paths() {
  case "$DEPLOY_MODE" in
    sqlite)
      COMPOSE_FILE="$APP_DIR/docker-compose.sqlite.yml"
      DB_FILE="$APP_DIR/data/db/dujiao.db"
      ;;
    postgres)
      COMPOSE_FILE="$APP_DIR/docker-compose.postgres.yml"
      DB_FILE=""
      ;;
    *) die "部署模式必须是 sqlite 或 postgres。" ;;
  esac
}

detect_deployment_mode() {
  local app_dir="$1"
  local config_yml="$app_dir/config/config.yml"
  local has_sqlite=0
  local has_postgres=0
  [[ -f "$app_dir/docker-compose.sqlite.yml" ]] && has_sqlite=1
  [[ -f "$app_dir/docker-compose.postgres.yml" ]] && has_postgres=1

  if [[ -f "$config_yml" ]]; then
    if grep -Eq '^[[:space:]]*driver:[[:space:]]*postgres([[:space:]]|$)' "$config_yml"; then
      printf 'postgres'
      return 0
    fi
    if grep -Eq '^[[:space:]]*driver:[[:space:]]*sqlite([[:space:]]|$)' "$config_yml"; then
      printf 'sqlite'
      return 0
    fi
  fi
  if command -v docker >/dev/null 2>&1 && docker inspect dujiaonext-postgres >/dev/null 2>&1; then
    printf 'postgres'
    return 0
  fi
  if [[ "$has_postgres" -eq 1 && "$has_sqlite" -eq 0 ]]; then
    printf 'postgres'
    return 0
  fi
  if [[ "$has_sqlite" -eq 1 && "$has_postgres" -eq 0 ]]; then
    printf 'sqlite'
    return 0
  fi
  if [[ -f "$app_dir/data/db/dujiao.db" && "$has_sqlite" -eq 1 ]]; then
    printf 'sqlite'
    return 0
  fi
  return 1
}

validate_deployment() {
  is_safe_absolute_path "$APP_DIR" || die "Dujiao-Next 目录必须是安全的绝对路径，不能含空格或 ..。"
  [[ -d "$APP_DIR" ]] || die "没有找到 Dujiao-Next 目录：$APP_DIR"
  [[ -f "$APP_DIR/.env" ]] || die "没有找到 $APP_DIR/.env"
  [[ -f "$APP_DIR/config/config.yml" ]] || die "没有找到 $APP_DIR/config/config.yml"
  [[ -d "$APP_DIR/data/uploads" ]] || die "没有找到 $APP_DIR/data/uploads"
  [[ -f "$COMPOSE_FILE" ]] || die "没有找到 Compose 文件：$COMPOSE_FILE"
  command -v docker >/dev/null 2>&1 || die "没有找到 Docker；请先完成 Dujiao-Next Docker Compose 部署。"
  case "$DEPLOY_MODE" in
    sqlite)
      command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 尚未安装。"
      [[ -f "$DB_FILE" ]] || die "没有找到 SQLite 数据库：$DB_FILE"
      ;;
    postgres)
      docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "没有找到 PostgreSQL 容器：$PG_CONTAINER"
      [[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER")" == "true" ]] || die "PostgreSQL 容器没有运行：$PG_CONTAINER"
      ;;
    *) die "未知部署模式：$DEPLOY_MODE" ;;
  esac
}

choose_deployment_interactive() {
  local input_dir detected choice container_name
  heading "识别 Dujiao-Next 部署方式"
  prompt_text input_dir "Dujiao-Next 安装目录" "$APP_DIR" 1
  input_dir="$(normalize_absolute_path "$input_dir")"
  is_safe_absolute_path "$input_dir" || die "安装目录只能使用不含空格和 .. 的绝对路径。"
  APP_DIR="$input_dir"
  if detected="$(detect_deployment_mode "$APP_DIR")"; then
    DEPLOY_MODE="$detected"
    if [[ "$DEPLOY_MODE" == "postgres" ]]; then
      info "已自动识别：方案 B（PostgreSQL + Redis）"
    else
      info "已自动识别：方案 A（SQLite + Redis）"
    fi
  else
    warn "无法可靠自动识别，请手动选择。"
    printf '  1) 方案 A：SQLite + Redis\n'
    printf '  2) 方案 B：PostgreSQL + Redis\n'
    prompt_choice choice "请选择部署模式" 1 2 2
    [[ "$choice" -eq 1 ]] && DEPLOY_MODE="sqlite" || DEPLOY_MODE="postgres"
  fi
  set_deployment_paths
  if [[ "$DEPLOY_MODE" == "postgres" ]]; then
    prompt_text container_name "PostgreSQL 容器名" "$PG_CONTAINER" 1
    [[ "$container_name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "PostgreSQL 容器名格式不正确。"
    PG_CONTAINER="$container_name"
  fi
  CURRENT_STEP="检查 Dujiao-Next 部署"
  validate_deployment
  success "Dujiao-Next 部署检查通过。"
}

install_base_dependencies() {
  CURRENT_STEP="安装 Debian 基础依赖"
  command -v apt-get >/dev/null 2>&1 || die "当前系统不支持 apt-get；本脚本面向 Debian/Ubuntu。"
  info "正在更新软件索引并安装所需组件..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl unzip tar gzip coreutils findutils util-linux \
    sqlite3 openssh-client sshpass
  success "基础依赖安装完成。"
}

ossutil_arch_details() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s %s\n' "amd64" "3ae4d9fc85a7a6e9f5654d1599766f1a3a42a3692870887b5ae9338d582ef65a"
      ;;
    aarch64|arm64)
      printf '%s %s\n' "arm64" "f6c95ba0c2d2ef30290af686ce4d706c701f4734ce8090bee4288a77e3f1d764"
      ;;
    *) return 1 ;;
  esac
}

install_ossutil() {
  local details arch expected_hash url work binary
  if command -v ossutil >/dev/null 2>&1 && ossutil version 2>/dev/null | grep -q "$OSSUTIL_VERSION"; then
    info "ossutil $OSSUTIL_VERSION 已安装。"
    return 0
  fi
  CURRENT_STEP="下载并校验阿里云 ossutil"
  details="$(ossutil_arch_details)" || die "ossutil 不支持当前 CPU 架构：$(uname -m)"
  read -r arch expected_hash <<< "$details"
  url="https://gosspublic.alicdn.com/ossutil/v2/$OSSUTIL_VERSION/ossutil-$OSSUTIL_VERSION-linux-$arch.zip"
  work="$(mktemp -d /tmp/dujiao-backup-ossutil.XXXXXX)"
  register_temp "$work"
  info "正在下载 ossutil $OSSUTIL_VERSION（$arch）..."
  curl -fL --retry 3 --connect-timeout 15 "$url" -o "$work/ossutil.zip"
  printf '%s  %s\n' "$expected_hash" "$work/ossutil.zip" | sha256sum -c -
  unzip -q "$work/ossutil.zip" -d "$work/unpacked"
  binary="$(find "$work/unpacked" -type f -name ossutil -print -quit)"
  [[ -n "$binary" ]] || die "下载包内没有找到 ossutil。"
  install -o root -g root -m 0755 "$binary" /usr/local/bin/ossutil
  ossutil version | grep -q "$OSSUTIL_VERSION" || die "ossutil 版本校验失败。"
  success "ossutil $OSSUTIL_VERSION 安装完成。"
}

configure_oss_interactive() {
  local value default_prefix versioning
  heading "配置阿里云 OSS"
  printf 'Region ID 可在阿里云 OSS 控制台 -> Bucket 概览/基本信息中查看。\n'
  printf '示例：华东1（杭州）为 cn-hangzhou，Endpoint 为 oss-cn-hangzhou.aliyuncs.com。\n\n'
  prompt_text value "AccessKey ID" "$OSS_ACCESS_KEY_ID" 1
  OSS_ACCESS_KEY_ID="$value"
  prompt_secret value "AccessKey Secret（输入时不会显示）" "$OSS_ACCESS_KEY_SECRET"
  OSS_ACCESS_KEY_SECRET="$value"
  while true; do
    prompt_text value "Region ID，例如 cn-hangzhou" "$OSS_REGION" 1
    if [[ "$value" =~ ^[a-z0-9-]+$ ]]; then
      OSS_REGION="$value"
      break
    fi
    warn "Region ID 格式不正确。"
  done
  [[ -n "$OSS_ENDPOINT" ]] || OSS_ENDPOINT="oss-$OSS_REGION.aliyuncs.com"
  while true; do
    prompt_text value "公网 Endpoint（不要写 https://）" "$OSS_ENDPOINT" 1
    value="${value#https://}"
    value="${value#http://}"
    if [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
      OSS_ENDPOINT="$value"
      break
    fi
    warn "Endpoint 格式不正确。"
  done
  while true; do
    prompt_text value "Bucket 名称" "$OSS_BUCKET" 1
    if [[ "$value" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
      OSS_BUCKET="$value"
      break
    fi
    warn "Bucket 名称格式不正确。"
  done
  default_prefix="${OSS_PREFIX:-dujiao-next/$(hostname -s)}"
  while true; do
    prompt_text value "OSS 内保存目录（可自定义）" "$default_prefix" 1
    value="$(normalize_oss_prefix "$value")"
    if [[ -n "$value" && "$value" != *".."* && "$value" != *"//"* && "$value" != *[[:cntrl:]]* ]]; then
      OSS_PREFIX="$value"
      break
    fi
    warn "OSS 目录不能为空，也不能含有 ..、连续斜杠或控制字符。"
  done
  prompt_yes_no versioning "这个 Bucket 是否开启了版本控制" 0
  if [[ "$versioning" -eq 1 ]]; then
    printf '普通删除只会生成 DeleteMarker，历史版本仍占用空间。\n'
    printf '如果不永久删除，请在 OSS 控制台配置“历史版本生命周期”。\n'
    prompt_yes_no OSS_DELETE_ALL_VERSIONS "超过保留数时，是否永久删除该备份的所有历史版本" "$OSS_DELETE_ALL_VERSIONS"
  else
    OSS_DELETE_ALL_VERSIONS="0"
  fi
  validate_oss_settings
}

ensure_sftp_key() {
  install -d -o root -g root -m 0700 "$KEY_DIR"
  if [[ ! -f "$SFTP_KEY_FILE" ]]; then
    CURRENT_STEP="生成 SFTP 专用 SSH 密钥"
    rm -f -- "$SFTP_KEY_FILE.pub"
    ssh-keygen -q -t ed25519 -N '' -C "dujiao-backup@$(hostname -s)" -f "$SFTP_KEY_FILE"
    success "已生成 SFTP 专用密钥：$SFTP_KEY_FILE"
  elif [[ ! -f "$SFTP_KEY_FILE.pub" ]]; then
    CURRENT_STEP="从 SFTP 私钥恢复公钥"
    ssh-keygen -y -f "$SFTP_KEY_FILE" > "$SFTP_KEY_FILE.pub"
    success "SFTP 公钥缺失，已从现有私钥安全恢复。"
  fi
  chown root:root "$SFTP_KEY_FILE" "$SFTP_KEY_FILE.pub"
  chmod 0600 "$SFTP_KEY_FILE"
  chmod 0644 "$SFTP_KEY_FILE.pub"
  touch "$SFTP_KNOWN_HOSTS"
  chown root:root "$SFTP_KNOWN_HOSTS"
  chmod 0600 "$SFTP_KNOWN_HOSTS"
}

pin_sftp_host_key() {
  local scan fingerprint accepted lookup
  CURRENT_STEP="获取并确认 SFTP 服务器指纹"
  scan="$(mktemp "$TMP_DIR/host-key.XXXXXX")"
  register_temp "$scan"
  ssh-keyscan -T 10 -p "$SFTP_PORT" "$SFTP_HOST" > "$scan" 2>/dev/null
  [[ -s "$scan" ]] || die "无法获取 SFTP 主机密钥，请检查 IP、端口和防火墙。"
  fingerprint="$(ssh-keygen -lf "$scan")"
  printf '\n请核对远端服务器 SSH 主机指纹：\n%s\n' "$fingerprint"
  prompt_yes_no accepted "确认信任以上主机指纹" 0
  [[ "$accepted" -eq 1 ]] || die "用户没有确认 SFTP 主机指纹。"
  lookup="$SFTP_HOST"
  [[ "$SFTP_PORT" -eq 22 ]] || lookup="[$SFTP_HOST]:$SFTP_PORT"
  ssh-keygen -R "$lookup" -f "$SFTP_KNOWN_HOSTS" >/dev/null 2>&1 || true
  rm -f -- "$SFTP_KNOWN_HOSTS.old"
  cat "$scan" >> "$SFTP_KNOWN_HOSTS"
  chmod 0600 "$SFTP_KNOWN_HOSTS"
}

sftp_ssh() {
  ssh \
    -i "$SFTP_KEY_FILE" \
    -p "$SFTP_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$SFTP_KNOWN_HOSTS" \
    -o ConnectTimeout=15 \
    "$SFTP_USER@$SFTP_HOST" "$@"
}

setup_sftp_authentication() {
  local password
  ensure_sftp_key
  pin_sftp_host_key
  if sftp_ssh "true" >/dev/null 2>&1; then
    info "现有专用密钥已可登录 SFTP 服务器。"
  else
    prompt_secret password "请输入 $SFTP_USER@$SFTP_HOST 的 SSH 登录密码（仅本次使用，不保存）" ""
    CURRENT_STEP="向 SFTP 服务器部署专用公钥"
    export SSHPASS="$password"
    sshpass -e ssh-copy-id \
      -i "$SFTP_KEY_FILE.pub" \
      -p "$SFTP_PORT" \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$SFTP_KNOWN_HOSTS" \
      "$SFTP_USER@$SFTP_HOST"
    unset SSHPASS
    password=""
  fi
  CURRENT_STEP="创建 SFTP 远端备份目录"
  sftp_ssh "umask 077; mkdir -p -- '$SFTP_REMOTE_DIR'; chmod 700 -- '$SFTP_REMOTE_DIR'"
  sftp_ssh "true"
  success "SFTP 密钥登录与远端目录配置完成；登录密码未保存。"
}

configure_sftp_interactive() {
  local value
  heading "配置 SFTP/SSH 异地备份"
  printf '首次配置需要远端 SSH 密码；脚本会下发专用密钥，之后不保存密码。\n'
  while true; do
    prompt_text value "远端服务器 IP 或域名" "$SFTP_HOST" 1
    if [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then SFTP_HOST="$value"; break; fi
    warn "主机格式不正确。"
  done
  while true; do
    prompt_text value "SSH/SFTP 端口" "$SFTP_PORT" 1
    if validate_uint_between "$value" 1 65535; then SFTP_PORT="$value"; break; fi
    warn "端口必须为 1 到 65535。"
  done
  while true; do
    prompt_text value "SSH 用户名" "$SFTP_USER" 1
    if [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]]; then SFTP_USER="$value"; break; fi
    warn "用户名格式不正确。"
  done
  while true; do
    prompt_text value "远端保存目录（可自定义）" "$SFTP_REMOTE_DIR" 1
    value="$(normalize_absolute_path "$value")"
    if is_safe_absolute_path "$value" && [[ "$value" != "/root" && "$value" != "/home" ]]; then
      SFTP_REMOTE_DIR="$value"
      break
    fi
    warn "请填写专用绝对路径，例如 /root/dujiao-backups，不能含空格或 ..。"
  done
  validate_sftp_settings
  setup_sftp_authentication
}

configure_targets_interactive() {
  local choice
  heading "选择备份目标"
  printf '  1) 阿里云 OSS\n'
  printf '  2) SFTP/SSH 远程服务器\n'
  printf '  3) OSS + SFTP 双目标\n'
  printf '  4) 仅本地（以后可在管理菜单开启远端）\n'
  prompt_choice choice "请选择" 1 4 1
  case "$choice" in
    1)
      OSS_ENABLED="1"; SFTP_ENABLED="0"
      install_ossutil
      configure_oss_interactive
      ;;
    2)
      OSS_ENABLED="0"; SFTP_ENABLED="1"
      configure_sftp_interactive
      ;;
    3)
      OSS_ENABLED="1"; SFTP_ENABLED="1"
      install_ossutil
      configure_oss_interactive
      configure_sftp_interactive
      ;;
    4)
      OSS_ENABLED="0"; SFTP_ENABLED="0"
      warn "当前只保存在本机；服务器磁盘损坏时本地备份也会丢失。"
      ;;
  esac
}

configure_retention_interactive() {
  local value
  heading "设置备份保留数量"
  while true; do
    prompt_text value "本地及已启用远端最多保留多少个完整备份" "$MAX_BACKUPS" 1
    if validate_uint_between "$value" 1 10000; then
      MAX_BACKUPS="$value"
      break
    fi
    warn "请输入 1 到 10000 之间的整数。"
  done
}

timer_total_seconds() {
  printf '%s' "$((TIMER_DAYS * 86400 + TIMER_HOURS * 3600 + TIMER_MINUTES * 60))"
}

format_interval() {
  printf '%s天 %s小时 %s分钟' "$TIMER_DAYS" "$TIMER_HOURS" "$TIMER_MINUTES"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

write_systemd_units() {
  local seconds
  seconds="$(timer_total_seconds)"
  [[ "$seconds" -ge 60 ]] || die "定时间隔必须至少为 1 分钟。"
  CURRENT_STEP="写入 systemd 定时任务"
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Dujiao-Next complete backup
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT backup --scheduled
User=root
Group=root
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=infinity
SERVICE
  cat > "$TIMER_FILE" <<TIMER
[Unit]
Description=Run Dujiao-Next backup every $(format_interval)

[Timer]
OnActiveSec=${seconds}s
OnUnitInactiveSec=${seconds}s
AccuracySec=1s
RandomizedDelaySec=0
Unit=dujiao-backup.service

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
}

activate_timer() {
  systemd_available || die "当前系统没有运行 systemd；可改用宝塔计划任务。"
  write_systemd_units
  systemctl daemon-reload
  systemctl enable dujiao-backup.timer
  systemctl restart dujiao-backup.timer
  success "定时备份已启用：每 $(format_interval) 执行一次（上一轮结束后重新计时）。"
}

disable_timer() {
  if systemd_available; then
    systemctl disable --now dujiao-backup.timer >/dev/null 2>&1 || true
    systemctl daemon-reload
  fi
  TIMER_ENABLED="0"
  save_config
  success "脚本内置的 systemd 定时备份已停用。"
}

set_timer_interactive() {
  local days hours minutes seconds
  heading "设置定时备份"
  printf '三个数表示“间隔”，不是固定钟点；0 表示该项不参与。\n'
  printf '例如：0天 0小时 2分钟 = 每2分钟；1天 2小时 30分钟 = 每26小时30分钟。\n'
  printf '小时限定 0-23，分钟限定 0-59；三个数不能全部为 0。\n\n'
  while true; do
    prompt_uint_range days "天数" "$TIMER_DAYS" 3650
    prompt_uint_range hours "小时" "$TIMER_HOURS" 23
    prompt_uint_range minutes "分钟" "$TIMER_MINUTES" 59
    TIMER_DAYS="$days"
    TIMER_HOURS="$hours"
    TIMER_MINUTES="$minutes"
    seconds="$(timer_total_seconds)"
    [[ "$seconds" -ge 60 ]] && break
    warn "三个数不能全部为 0，最短间隔为 1 分钟，请重新输入。"
  done
  TIMER_ENABLED="1"
  activate_timer
  save_config
}

configure_timer_during_install() {
  local enabled
  heading "配置自动备份"
  prompt_yes_no enabled "是否启用脚本内置的 systemd 定时备份" 1
  if [[ "$enabled" -eq 1 ]]; then
    set_timer_interactive
  else
    TIMER_ENABLED="0"
    save_config
    info "未启用内置定时；之后可运行 dujiao-backup 打开管理菜单。"
  fi
}

oss_export_environment() {
  export OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_REGION OSS_ENDPOINT
}

oss_destination_id() {
  printf 'oss://%s/%s' "$OSS_BUCKET" "$OSS_PREFIX"
}

oss_archive_uri() {
  printf '%s/%s' "$(oss_destination_id)" "$1"
}

sftp_destination_id() {
  printf 'sftp://%s@%s:%s%s' "$SFTP_USER" "$SFTP_HOST" "$SFTP_PORT" "$SFTP_REMOTE_DIR"
}

json_string_field() {
  local field="$1"
  awk -F'"' -v key="$field" '$2 == key {print $4; exit}'
}

oss_upload_and_verify() {
  local local_file="$1"
  local uri="$2"
  local local_size local_sha stat_json remote_size remote_sha
  local_size="$(stat -c %s "$local_file")"
  local_sha="$(sha256sum "$local_file" | awk '{print $1}')"
  # 不使用 ossutil --checksum：该选项会跳过同内容对象，无法为旧对象补写校验元数据。
  ossutil cp "$local_file" "$uri" -f --no-progress \
    --metadata "dujiao-sha256=$local_sha"
  stat_json="$(ossutil stat "$uri" --output-format json)"
  remote_size="$(printf '%s\n' "$stat_json" | json_string_field 'Content-Length')"
  remote_sha="$(printf '%s\n' "$stat_json" | json_string_field 'X-Oss-Meta-Dujiao-Sha256')"
  [[ "$remote_size" == "$local_size" ]] || die "OSS 上传后大小不一致：本地 $local_size，远端 ${remote_size:-未知}。"
  [[ "$remote_sha" == "$local_sha" ]] || die "OSS 上传后 SHA256 元数据校验失败。"
}

test_oss_connection() {
  local probe name uri
  validate_oss_settings
  install_ossutil
  oss_export_environment
  probe="$(mktemp "$TMP_DIR/oss-test.XXXXXX")"
  register_temp "$probe"
  printf 'Dujiao backup connection test: %s\n' "$(now)" > "$probe"
  name=".dujiao-backup-connection-test"
  uri="$(oss_destination_id)/$name"
  CURRENT_STEP="测试 OSS 上传"
  oss_upload_and_verify "$probe" "$uri"
  if [[ "$OSS_DELETE_ALL_VERSIONS" -eq 1 ]]; then
    ossutil rm "$uri" -f --all-versions
  else
    ossutil rm "$uri" -f
  fi
  success "OSS 连接、上传、校验和删除测试通过：$(oss_destination_id)/"
}

sftp_upload_file() {
  local local_file="$1"
  local remote_name="$2"
  local remote_final remote_partial expected batch
  [[ "$remote_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "拒绝上传不安全的远端文件名。"
  remote_final="$SFTP_REMOTE_DIR/$remote_name"
  remote_partial="$remote_final.partial"
  expected="$(sha256sum "$local_file" | awk '{print $1}')"
  batch="$(mktemp "$TMP_DIR/sftp-batch.XXXXXX")"
  register_temp "$batch"
  printf 'put "%s" "%s"\n' "$local_file" "$remote_partial" > "$batch"
  sftp \
    -q \
    -b "$batch" \
    -P "$SFTP_PORT" \
    -i "$SFTP_KEY_FILE" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$SFTP_KNOWN_HOSTS" \
    -o ConnectTimeout=15 \
    "$SFTP_USER@$SFTP_HOST"
  sftp_ssh "actual=\$(sha256sum '$remote_partial'); actual=\${actual%% *}; test \"\$actual\" = '$expected'; mv -f -- '$remote_partial' '$remote_final'"
}

test_sftp_connection() {
  local probe name
  validate_sftp_settings
  [[ -f "$SFTP_KEY_FILE" ]] || die "SFTP 专用私钥不存在，请重新配置 SFTP。"
  [[ -f "$SFTP_KNOWN_HOSTS" ]] || die "SFTP 主机指纹文件不存在，请重新配置 SFTP。"
  probe="$(mktemp "$TMP_DIR/sftp-test.XXXXXX")"
  register_temp "$probe"
  printf 'Dujiao backup connection test: %s\n' "$(now)" > "$probe"
  name=".dujiao-backup-test-$(hostname -s)-$$"
  CURRENT_STEP="测试 SFTP 上传"
  sftp_upload_file "$probe" "$name"
  sftp_ssh "rm -f -- '$SFTP_REMOTE_DIR/$name' '$SFTP_REMOTE_DIR/$name.partial'"
  success "SFTP 密钥登录、上传、校验、原子改名和删除测试通过。"
}

test_targets_command() {
  require_root
  ensure_runtime_dirs
  load_config || die "尚未安装或配置。"
  validate_deployment
  [[ "$OSS_ENABLED" -eq 0 ]] || test_oss_connection
  [[ "$SFTP_ENABLED" -eq 0 ]] || test_sftp_connection
  if [[ "$OSS_ENABLED" -eq 0 && "$SFTP_ENABLED" -eq 0 ]]; then
    warn "当前仅本地备份，没有需要测试的远端目标。"
  fi
}

valid_archive_name() {
  [[ "$1" =~ ^dujiao-next-[0-9]{8}-[0-9]{6}[.]tar$ ]]
}

archive_marker() {
  printf '%s/%s.%s.ok' "$STATE_DIR" "$1" "$2"
}

marker_matches() {
  local marker="$1"
  local destination="$2"
  [[ -f "$marker" ]] || return 1
  [[ "$(< "$marker")" == "$destination" ]]
}

write_marker() {
  local marker="$1"
  local destination="$2"
  local temporary="$marker.new.$$"
  printf '%s\n' "$destination" > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$marker"
}

create_archive() {
  local stamp archive_name archive_path work database_name
  local app_image upload_files database_size partial
  local -a config_items
  CURRENT_STEP="创建本地一致性备份"
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive_name="dujiao-next-$stamp.tar"
  archive_path="$BACKUP_DIR/$archive_name"
  while [[ -e "$archive_path" ]]; do
    sleep 1
    stamp="$(date +%Y%m%d-%H%M%S)"
    archive_name="dujiao-next-$stamp.tar"
    archive_path="$BACKUP_DIR/$archive_name"
  done
  work="$(mktemp -d "$TMP_DIR/backup-$stamp.XXXXXX")"
  register_temp "$work"
  partial="$BACKUP_DIR/.$archive_name.partial"
  ACTIVE_PARTIAL="$partial"
  info "开始创建完整备份：$archive_name"

  if [[ "$DEPLOY_MODE" == "postgres" ]]; then
    database_name="database.dump"
    CURRENT_STEP="执行 PostgreSQL pg_dump"
    docker exec "$PG_CONTAINER" sh -eu -c \
      'exec pg_dump --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --format=custom --compress=6' \
      > "$work/$database_name"
    [[ -s "$work/$database_name" ]] || die "PostgreSQL 导出文件为空。"
    CURRENT_STEP="校验 PostgreSQL dump"
    docker exec -i "$PG_CONTAINER" pg_restore --list < "$work/$database_name" >/dev/null
  else
    database_name="database.sqlite"
    CURRENT_STEP="创建 SQLite 在线一致性快照"
    sqlite3 "$DB_FILE" ".timeout 30000" ".backup '$work/$database_name'"
    [[ -s "$work/$database_name" ]] || die "SQLite 快照为空。"
    [[ "$(sqlite3 "$work/$database_name" 'PRAGMA quick_check;')" == "ok" ]] || die "SQLite 快照完整性校验失败。"
  fi

  CURRENT_STEP="打包上传图片"
  tar -C "$APP_DIR/data" -czf "$work/uploads.tar.gz" -- uploads
  tar -tzf "$work/uploads.tar.gz" >/dev/null
  CURRENT_STEP="打包配置文件"
  config_items=(".env" "config/config.yml" "$(basename "$COMPOSE_FILE")")
  tar -C "$APP_DIR" -czf "$work/config.tar.gz" -- "${config_items[@]}"
  tar -tzf "$work/config.tar.gz" >/dev/null

  app_image="$(docker inspect --format '{{.Config.Image}}' dujiao-next 2>/dev/null || printf 'unknown')"
  upload_files="$(find "$APP_DIR/data/uploads" -type f | wc -l | tr -d ' ')"
  database_size="$(stat -c %s "$work/$database_name")"
  {
    printf 'backup_manager_version=%s\n' "$VERSION"
    printf 'created_at=%s\n' "$(now)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'application=dujiao-next\n'
    printf 'deploy_mode=%s\n' "$DEPLOY_MODE"
    printf 'database_file=%s\n' "$database_name"
    printf 'database_size=%s\n' "$database_size"
    printf 'app_image=%s\n' "$app_image"
    printf 'upload_files=%s\n' "$upload_files"
    printf 'compose_file=%s\n' "$(basename "$COMPOSE_FILE")"
  } > "$work/manifest.txt"

  CURRENT_STEP="生成并核对备份校验和"
  (
    cd "$work"
    sha256sum "$database_name" uploads.tar.gz config.tar.gz manifest.txt > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  )
  CURRENT_STEP="生成最终 TAR 备份包"
  tar -C "$work" -cf "$partial" \
    "$database_name" uploads.tar.gz config.tar.gz manifest.txt SHA256SUMS
  tar -tf "$partial" >/dev/null
  chmod 0600 "$partial"
  mv -f -- "$partial" "$archive_path"
  ACTIVE_PARTIAL=""
  success "本地完整备份已生成：$archive_path（$(stat -c %s "$archive_path") 字节）"
}

sync_archive_to_oss() {
  local archive="$1"
  local name marker destination uri
  name="$(basename "$archive")"
  marker="$(archive_marker "$name" oss)"
  destination="$(oss_destination_id)"
  if marker_matches "$marker" "$destination"; then
    info "OSS 已同步，跳过：$name"
    return 0
  fi
  CURRENT_STEP="上传 $name 到阿里云 OSS"
  uri="$(oss_archive_uri "$name")"
  info "正在上传到 OSS：$uri"
  oss_upload_and_verify "$archive" "$uri"
  write_marker "$marker" "$destination"
  success "OSS 上传并校验成功：$uri"
}

sync_archive_to_sftp() {
  local archive="$1"
  local name marker destination
  name="$(basename "$archive")"
  marker="$(archive_marker "$name" sftp)"
  destination="$(sftp_destination_id)"
  if marker_matches "$marker" "$destination"; then
    info "SFTP 已同步，跳过：$name"
    return 0
  fi
  CURRENT_STEP="上传 $name 到 SFTP"
  info "正在上传到 SFTP：$destination/$name"
  sftp_upload_file "$archive" "$name"
  write_marker "$marker" "$destination"
  success "SFTP 上传、SHA256 校验和原子改名成功：$name"
}

sync_all_archives() {
  local archive name
  local -a archives
  mapfile -d '' archives < <(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f \
      -name 'dujiao-next-????????-??????.tar' -print0 | sort -z
  )
  info "本地共有 ${#archives[@]} 个完整备份，开始检查远端同步状态。"
  if [[ "$OSS_ENABLED" -eq 1 ]]; then
    validate_oss_settings
    command -v ossutil >/dev/null 2>&1 || die "ossutil 未安装，请运行安装脚本修复依赖。"
    oss_export_environment
  fi
  if [[ "$SFTP_ENABLED" -eq 1 ]]; then
    validate_sftp_settings
    [[ -f "$SFTP_KEY_FILE" && -f "$SFTP_KNOWN_HOSTS" ]] || die "SFTP 密钥或主机指纹文件缺失，请重新配置。"
    chown root:root "$SFTP_KEY_FILE" "$SFTP_KNOWN_HOSTS"
    chmod 0600 "$SFTP_KEY_FILE" "$SFTP_KNOWN_HOSTS"
  fi
  for archive in "${archives[@]}"; do
    name="$(basename "$archive")"
    valid_archive_name "$name" || die "发现异常备份文件名：$name"
    [[ "$OSS_ENABLED" -eq 0 ]] || sync_archive_to_oss "$archive"
    [[ "$SFTP_ENABLED" -eq 0 ]] || sync_archive_to_sftp "$archive"
  done
}

delete_oss_archive() {
  local name="$1"
  local uri
  uri="$(oss_archive_uri "$name")"
  CURRENT_STEP="删除最旧 OSS 备份 $name"
  if [[ "$OSS_DELETE_ALL_VERSIONS" -eq 1 ]]; then
    ossutil rm "$uri" -f --all-versions
  else
    ossutil rm "$uri" -f
  fi
  info "已删除 OSS 最旧备份：$uri"
}

delete_sftp_archive() {
  local name="$1"
  CURRENT_STEP="删除最旧 SFTP 备份 $name"
  sftp_ssh "rm -f -- '$SFTP_REMOTE_DIR/$name' '$SFTP_REMOTE_DIR/$name.partial'"
  info "已删除 SFTP 最旧备份：$name"
}

parse_archive_names() {
  grep -oE 'dujiao-next-[0-9]{8}-[0-9]{6}[.]tar$' | sort -u || true
}

archive_array_contains() {
  local needle="$1"
  local item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

list_oss_archive_names() {
  local output
  CURRENT_STEP="清点 OSS 远端备份"
  output="$(ossutil ls "$(oss_destination_id)/" --short-format --output-format raw)"
  printf '%s\n' "$output" | parse_archive_names
}

list_sftp_archive_names() {
  local output
  CURRENT_STEP="清点 SFTP 远端备份"
  output="$(sftp_ssh "for f in '$SFTP_REMOTE_DIR'/dujiao-next-????????-??????.tar; do if test -f \"\$f\"; then basename -- \"\$f\"; fi; done; exit 0")"
  printf '%s\n' "$output" | parse_archive_names
}

prune_remote_extras() {
  local oldest listing_file archive name marker item
  local -a local_archives local_names remote_archives extras filtered
  mapfile -d '' local_archives < <(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f \
      -name 'dujiao-next-????????-??????.tar' -print0 | sort -z
  )
  for archive in "${local_archives[@]}"; do
    local_names+=("$(basename "$archive")")
  done

  if [[ "$OSS_ENABLED" -eq 1 ]]; then
    listing_file="$(mktemp "$TMP_DIR/oss-list.XXXXXX")"
    register_temp "$listing_file"
    list_oss_archive_names > "$listing_file"
    mapfile -t remote_archives < "$listing_file"
    for archive in "${local_archives[@]}"; do
      name="$(basename "$archive")"
      if ! archive_array_contains "$name" "${remote_archives[@]}"; then
        warn "OSS 中缺少本地保留备份，正在自动补传：$name"
        marker="$(archive_marker "$name" oss)"
        rm -f -- "$marker"
        sync_archive_to_oss "$archive"
        remote_archives+=("$name")
      fi
    done
    printf '%s\n' "${remote_archives[@]}" | sort -u > "$listing_file"
    mapfile -t remote_archives < "$listing_file"
    extras=()
    for item in "${remote_archives[@]}"; do
      archive_array_contains "$item" "${local_names[@]}" || extras+=("$item")
    done
    while [[ "${#remote_archives[@]}" -gt "$MAX_BACKUPS" ]]; do
      [[ "${#extras[@]}" -gt 0 ]] || die "OSS 数量超过上限，但没有可安全清理的远端额外备份。"
      oldest="${extras[0]}"
      valid_archive_name "$oldest" || die "拒绝删除异常 OSS 文件名：$oldest"
      delete_oss_archive "$oldest"
      rm -f -- "$(archive_marker "$oldest" oss)"
      filtered=()
      for item in "${remote_archives[@]}"; do
        [[ "$item" == "$oldest" ]] || filtered+=("$item")
      done
      remote_archives=("${filtered[@]}")
      extras=("${extras[@]:1}")
    done
    info "OSS 当前保留 ${#remote_archives[@]} 份标准备份。"
  fi

  if [[ "$SFTP_ENABLED" -eq 1 ]]; then
    listing_file="$(mktemp "$TMP_DIR/sftp-list.XXXXXX")"
    register_temp "$listing_file"
    list_sftp_archive_names > "$listing_file"
    mapfile -t remote_archives < "$listing_file"
    for archive in "${local_archives[@]}"; do
      name="$(basename "$archive")"
      if ! archive_array_contains "$name" "${remote_archives[@]}"; then
        warn "SFTP 中缺少本地保留备份，正在自动补传：$name"
        marker="$(archive_marker "$name" sftp)"
        rm -f -- "$marker"
        sync_archive_to_sftp "$archive"
        remote_archives+=("$name")
      fi
    done
    printf '%s\n' "${remote_archives[@]}" | sort -u > "$listing_file"
    mapfile -t remote_archives < "$listing_file"
    extras=()
    for item in "${remote_archives[@]}"; do
      archive_array_contains "$item" "${local_names[@]}" || extras+=("$item")
    done
    while [[ "${#remote_archives[@]}" -gt "$MAX_BACKUPS" ]]; do
      [[ "${#extras[@]}" -gt 0 ]] || die "SFTP 数量超过上限，但没有可安全清理的远端额外备份。"
      oldest="${extras[0]}"
      valid_archive_name "$oldest" || die "拒绝删除异常 SFTP 文件名：$oldest"
      delete_sftp_archive "$oldest"
      rm -f -- "$(archive_marker "$oldest" sftp)"
      filtered=()
      for item in "${remote_archives[@]}"; do
        [[ "$item" == "$oldest" ]] || filtered+=("$item")
      done
      remote_archives=("${filtered[@]}")
      extras=("${extras[@]:1}")
    done
    info "SFTP 当前保留 ${#remote_archives[@]} 份标准备份。"
  fi
}

apply_retention() {
  local oldest name oss_marker sftp_marker
  local oss_destination sftp_destination
  local -a archives
  mapfile -d '' archives < <(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f \
      -name 'dujiao-next-????????-??????.tar' -print0 | sort -z
  )
  oss_destination="$(oss_destination_id)"
  sftp_destination="$(sftp_destination_id)"
  while [[ "${#archives[@]}" -gt "$MAX_BACKUPS" ]]; do
    oldest="${archives[0]}"
    name="$(basename "$oldest")"
    valid_archive_name "$name" || die "拒绝删除异常文件名：$name"
    oss_marker="$(archive_marker "$name" oss)"
    sftp_marker="$(archive_marker "$name" sftp)"
    if [[ "$OSS_ENABLED" -eq 1 ]]; then
      marker_matches "$oss_marker" "$oss_destination" || die "最旧备份尚未同步到当前 OSS 目标，暂不清理：$name"
      delete_oss_archive "$name"
    fi
    if [[ "$SFTP_ENABLED" -eq 1 ]]; then
      marker_matches "$sftp_marker" "$sftp_destination" || die "最旧备份尚未同步到当前 SFTP 目标，暂不清理：$name"
      delete_sftp_archive "$name"
    fi
    CURRENT_STEP="删除最旧本地备份 $name"
    rm -f -- "$oldest" "$oss_marker" "$sftp_marker"
    info "已删除最旧本地备份：$oldest"
    archives=("${archives[@]:1}")
  done
  prune_remote_extras
  success "保留策略完成：当前 ${#archives[@]} 份，最大 $MAX_BACKUPS 份。"
}

backup_command() {
  require_root
  ensure_runtime_dirs
  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    warn "已有备份任务正在运行，本次安全跳过。"
    exit 0
  fi
  start_log_capture
  load_config || die "尚未安装或没有配置文件：$CONFIG_FILE"
  heading "Dujiao-Next 完整备份开始"
  info "管理器版本：$VERSION"
  info "部署模式：$DEPLOY_MODE；最多保留：$MAX_BACKUPS"
  CURRENT_STEP="检查备份前环境"
  validate_deployment
  create_archive
  sync_all_archives
  apply_retention
  success "本次完整备份全部成功。"
}

validate_tar_member_types() {
  local archive="$1"
  local compression="$2"
  local allowed_types="$3"
  {
    if [[ "$compression" == "gzip" ]]; then
      tar -tvzf "$archive"
    else
      tar -tvf "$archive"
    fi
  } | awk -v allowed="$allowed_types" '
    BEGIN { count = 0 }
    {
      count++
      if (index(allowed, substr($1, 1, 1)) == 0) exit 1
    }
    END { if (count == 0) exit 1 }
  '
}

validate_inner_tar_paths() {
  local archive="$1"
  local kind="$2"
  local listing member count=0
  local env_count=0 config_count=0 compose_count=0
  listing="$(mktemp "$TMP_DIR/tar-list.XXXXXX")"
  register_temp "$listing"
  tar -tzf "$archive" > "$listing"
  while IFS= read -r member; do
    count="$((count + 1))"
    [[ -n "$member" && "$member" != /* && "$member" != "." && "$member" != ./* \
      && "$member" != ".." && "$member" != ../* && "$member" != *"//"* \
      && "$member" != *"/./"* && "$member" != *"/." \
      && "$member" != *"/../"* && "$member" != *"/.." ]] || return 1
    case "$kind" in
      uploads)
        [[ "$member" == "uploads" || "$member" == "uploads/" || "$member" == uploads/* ]] || return 1
        ;;
      config)
        case "$member" in
          .env) env_count="$((env_count + 1))" ;;
          config/config.yml) config_count="$((config_count + 1))" ;;
          docker-compose.sqlite.yml|docker-compose.postgres.yml) compose_count="$((compose_count + 1))" ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done < "$listing"
  if [[ "$kind" == "config" ]]; then
    [[ "$count" -eq 3 && "$env_count" -eq 1 && "$config_count" -eq 1 && "$compose_count" -eq 1 ]]
  else
    [[ "$count" -gt 0 ]]
  fi
}

verify_archive_file() {
  local archive="$1"
  local work member database_found=0 database_file=""
  local uploads_found=0 config_found=0 manifest_found=0 checksums_found=0
  local expected checksum_name
  local -a members checksum_files expected_checksum_files
  [[ -f "$archive" ]] || die "备份文件不存在：$archive"
  work="$(mktemp -d "$TMP_DIR/verify.XXXXXX")"
  register_temp "$work"
  CURRENT_STEP="检查 TAR 目录结构"
  validate_tar_member_types "$archive" plain "-" || die "外层 TAR 含有非普通文件条目。"
  mapfile -t members < <(tar -tf "$archive")
  [[ "${#members[@]}" -eq 5 ]] || die "备份包应包含 5 个文件，实际为 ${#members[@]} 个。"
  for member in "${members[@]}"; do
    case "$member" in
      database.dump|database.sqlite)
        database_found="$((database_found + 1))"
        database_file="$member"
        ;;
      uploads.tar.gz) uploads_found="$((uploads_found + 1))" ;;
      config.tar.gz) config_found="$((config_found + 1))" ;;
      manifest.txt) manifest_found="$((manifest_found + 1))" ;;
      SHA256SUMS) checksums_found="$((checksums_found + 1))" ;;
      *) die "备份包含异常路径或文件：$member" ;;
    esac
  done
  [[ "$database_found" -eq 1 ]] || die "备份包必须且只能包含一个数据库文件。"
  [[ "$uploads_found" -eq 1 && "$config_found" -eq 1 && "$manifest_found" -eq 1 && "$checksums_found" -eq 1 ]] \
    || die "备份包内的固定文件必须各出现一次。"
  tar --no-same-owner --no-same-permissions -xf "$archive" -C "$work"
  expected_checksum_files=("$database_file" uploads.tar.gz config.tar.gz manifest.txt)
  if grep -Eqv '^[0-9a-fA-F]{64}  [A-Za-z0-9._-]+$' "$work/SHA256SUMS"; then
    die "SHA256SUMS 格式不安全或不受支持。"
  fi
  mapfile -t checksum_files < <(awk '{print $2}' "$work/SHA256SUMS")
  [[ "${#checksum_files[@]}" -eq 4 ]] || die "SHA256SUMS 必须正好包含 4 条记录。"
  for expected in "${expected_checksum_files[@]}"; do
    archive_array_contains "$expected" "${checksum_files[@]}" || die "SHA256SUMS 缺少文件：$expected"
  done
  for checksum_name in "${checksum_files[@]}"; do
    archive_array_contains "$checksum_name" "${expected_checksum_files[@]}" || die "SHA256SUMS 含有异常文件：$checksum_name"
  done
  CURRENT_STEP="核对备份 SHA256"
  (
    cd "$work"
    sha256sum -c SHA256SUMS
  )
  validate_tar_member_types "$work/uploads.tar.gz" gzip "-d" || die "uploads.tar.gz 含有链接或特殊文件。"
  validate_tar_member_types "$work/config.tar.gz" gzip "-" || die "config.tar.gz 含有链接或特殊文件。"
  validate_inner_tar_paths "$work/uploads.tar.gz" uploads || die "uploads.tar.gz 含有不安全路径。"
  validate_inner_tar_paths "$work/config.tar.gz" config || die "config.tar.gz 含有异常文件或路径。"
  if [[ -f "$work/database.sqlite" ]]; then
    [[ "$(sqlite3 "$work/database.sqlite" 'PRAGMA quick_check;')" == "ok" ]] || die "SQLite 数据库完整性校验失败。"
    success "SQLite 数据库 quick_check 通过。"
  elif load_config && [[ "$DEPLOY_MODE" == "postgres" ]] && docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
    docker exec -i "$PG_CONTAINER" pg_restore --list < "$work/database.dump" >/dev/null
    success "PostgreSQL custom dump 目录校验通过。"
  else
    warn "当前没有可用的 PostgreSQL pg_restore，仅完成了 dump 的 SHA256 校验。"
  fi
  success "备份包完整性校验通过：$archive"
}

verify_command() {
  local archive="${1:-}"
  require_root
  ensure_runtime_dirs
  if [[ -z "$archive" ]]; then
    archive="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f -name 'dujiao-next-????????-??????.tar' -print | sort | tail -n 1)"
  fi
  [[ -n "$archive" ]] || die "本地没有可校验的备份。"
  verify_archive_file "$archive"
}

list_local_backups() {
  local count total
  ensure_runtime_dirs
  count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f -name 'dujiao-next-????????-??????.tar' | wc -l | tr -d ' ')"
  total="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
  heading "本地备份（$count 份，目录占用 ${total:-0}）"
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f \
    -name 'dujiao-next-????????-??????.tar' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' | sort
  [[ "$count" -gt 0 ]] || printf '暂无本地备份。\n'
}

list_remote_backups() {
  require_root
  load_config || die "尚未安装。"
  if [[ "$OSS_ENABLED" -eq 1 ]]; then
    heading "阿里云 OSS：$(oss_destination_id)/"
    validate_oss_settings
    oss_export_environment
    ossutil ls "$(oss_destination_id)/"
  fi
  if [[ "$SFTP_ENABLED" -eq 1 ]]; then
    heading "SFTP：$(sftp_destination_id)"
    validate_sftp_settings
    sftp_ssh "for f in '$SFTP_REMOTE_DIR'/dujiao-next-????????-??????.tar; do test -f \"\$f\" && stat -c '%y  %s  %n' \"\$f\"; done" || true
  fi
  if [[ "$OSS_ENABLED" -eq 0 && "$SFTP_ENABLED" -eq 0 ]]; then
    warn "当前没有启用远端备份。"
  fi
}

mask_access_key() {
  local value="$1"
  if [[ "${#value}" -le 8 ]]; then
    printf '****'
  else
    printf '%s****%s' "${value:0:4}" "${value: -4}"
  fi
}

timer_status_text() {
  if [[ "$TIMER_ENABLED" -eq 1 ]]; then
    printf '已启用，每 %s' "$(format_interval)"
  else
    printf '未启用'
  fi
}

status_command() {
  local count total latest last_result targets=""
  require_root
  ensure_runtime_dirs
  load_config || die "尚未安装。"
  count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f -name 'dujiao-next-????????-??????.tar' | wc -l | tr -d ' ')"
  total="$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
  latest="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type f -name 'dujiao-next-????????-??????.tar' -printf '%f\n' | sort | tail -n 1)"
  last_result="$(grep -E '\[(SUCCESS|ERROR)\]' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ "$OSS_ENABLED" -eq 1 ]] && targets="${targets}OSS "
  [[ "$SFTP_ENABLED" -eq 1 ]] && targets="${targets}SFTP "
  [[ -n "$targets" ]] || targets="仅本地"
  heading "$PROGRAM_NAME 状态"
  printf '程序版本      : %s\n' "$VERSION"
  printf '安装目录      : %s\n' "$INSTALL_DIR"
  printf 'Dujiao 目录   : %s\n' "$APP_DIR"
  printf '部署模式      : %s\n' "$DEPLOY_MODE"
  printf '备份目标      : %s\n' "$targets"
  printf '最多保留      : %s 份\n' "$MAX_BACKUPS"
  printf '本地备份      : %s 份，占用 %s\n' "$count" "${total:-0}"
  printf '最新备份      : %s\n' "${latest:-无}"
  printf '内置定时      : %s\n' "$(timer_status_text)"
  if [[ "$OSS_ENABLED" -eq 1 ]]; then
    printf 'OSS AccessKey : %s\n' "$(mask_access_key "$OSS_ACCESS_KEY_ID")"
    printf 'OSS 位置      : %s/\n' "$(oss_destination_id)"
  fi
  if [[ "$SFTP_ENABLED" -eq 1 ]]; then
    printf 'SFTP 位置     : %s\n' "$(sftp_destination_id)"
  fi
  printf '最近结果      : %s\n' "${last_result:-暂无记录}"
  if systemd_available && [[ "$TIMER_ENABLED" -eq 1 ]]; then
    printf '\nsystemd 下一次运行：\n'
    systemctl list-timers dujiao-backup.timer --no-pager || true
  fi
}

show_logs() {
  ensure_runtime_dirs
  heading "最近 100 行日志：$LOG_FILE"
  tail -n 100 "$LOG_FILE"
}

show_baota_command() {
  heading "宝塔计划任务"
  printf '任务类型：Shell 脚本\n'
  printf '执行用户：root\n'
  printf '脚本内容：\n\n'
  printf '%s\n' "$COMMAND_LINK backup --scheduled"
  printf '\n运行周期请在宝塔中设置。脚本自身带互斥锁，重复触发不会并发执行。\n'
  printf '如果改用宝塔，请先在管理菜单停用内置 systemd 定时，避免两套定时重复触发。\n'
  printf '日志位置：%s\n' "$LOG_FILE"
}

extract_script_version() {
  awk -F'"' '/^readonly VERSION=/{print $2; exit}' "$1"
}

version_is_newer() {
  local remote="$1"
  local current="$2"
  [[ "$remote" != "$current" && "$(printf '%s\n%s\n' "$current" "$remote" | sort -V | tail -n 1)" == "$remote" ]]
}

update_command() {
  local temporary remote_version proceed
  require_root
  require_tty
  ensure_runtime_dirs
  CURRENT_STEP="从 GitHub 下载升级脚本"
  temporary="$(mktemp "$TMP_DIR/update.XXXXXX")"
  register_temp "$temporary"
  curl -fL --retry 3 --connect-timeout 15 "$RAW_SCRIPT_URL" -o "$temporary"
  bash -n "$temporary"
  remote_version="$(extract_script_version "$temporary")"
  [[ "$remote_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "无法识别远端脚本版本，已拒绝替换。"
  info "当前版本：$VERSION；GitHub 版本：$remote_version"
  if ! version_is_newer "$remote_version" "$VERSION"; then
    success "当前已是最新版本，无需升级。"
    return 0
  fi
  prompt_yes_no proceed "确认升级到 v$remote_version" 1
  if [[ "$proceed" -eq 0 ]]; then
    info "已取消升级。"
    return 0
  fi
  CURRENT_STEP="安装升级脚本"
  install -o root -g root -m 0700 "$temporary" "$INSTALLED_SCRIPT"
  bash -n "$INSTALLED_SCRIPT"
  success "升级完成：v$VERSION -> v$remote_version"
}

run_child_command() {
  local rc
  if "$INSTALLED_SCRIPT" "$@"; then
    return 0
  else
    rc="$?"
  fi
  printf '\n操作失败，退出码：%s。请查看上方原因或日志：%s\n' "$rc" "$LOG_FILE"
  return 0
}

configuration_menu() {
  local choice
  while true; do
    load_config || die "尚未安装。"
    heading "配置管理"
    printf '  1) 重新识别/选择 Dujiao 部署模式\n'
    printf '  2) 配置或切换 OSS/SFTP 目标\n'
    printf '  3) 修改保留数量\n'
    printf '  4) 完整配置向导\n'
    printf '  0) 返回\n'
    prompt_choice choice "请选择" 0 4 0
    case "$choice" in
      1)
        choose_deployment_interactive
        save_config
        success "部署配置已保存。"
        ;;
      2)
        configure_targets_interactive
        save_config
        test_targets_command
        ;;
      3)
        configure_retention_interactive
        save_config
        success "保留数量已保存。"
        ;;
      4)
        choose_deployment_interactive
        configure_retention_interactive
        configure_targets_interactive
        save_config
        test_targets_command
        ;;
      0) return 0 ;;
    esac
    pause_for_enter
  done
}

timer_menu() {
  local choice
  while true; do
    load_config || die "尚未安装。"
    heading "定时任务管理"
    printf '当前状态：%s\n\n' "$(timer_status_text)"
    printf '  1) 启用或修改执行间隔\n'
    printf '  2) 停用内置 systemd 定时\n'
    printf '  3) 查看 systemd 定时器状态\n'
    printf '  4) 显示宝塔计划任务命令\n'
    printf '  0) 返回\n'
    prompt_choice choice "请选择" 0 4 0
    case "$choice" in
      1) set_timer_interactive ;;
      2) disable_timer ;;
      3)
        if systemd_available; then
          systemctl status dujiao-backup.timer --no-pager || true
          systemctl list-timers dujiao-backup.timer --no-pager || true
        else
          warn "当前系统没有运行 systemd。"
        fi
        ;;
      4) show_baota_command ;;
      0) return 0 ;;
    esac
    pause_for_enter
  done
}

uninstall_command() {
  local confirmation delete_data
  require_root
  require_tty
  heading "卸载 $PROGRAM_NAME"
  printf '卸载会停用 systemd 定时并删除命令和程序文件。\n'
  printf '默认保留配置、日志、密钥和所有备份。\n'
  prompt_text confirmation "如确认卸载，请输入 UNINSTALL" "" 1
  [[ "$confirmation" == "UNINSTALL" ]] || die "确认文字不匹配，已取消卸载。"
  if systemd_available; then
    systemctl disable --now dujiao-backup.timer >/dev/null 2>&1 || true
  fi
  rm -f -- "$SERVICE_FILE" "$TIMER_FILE"
  if [[ -L "$COMMAND_LINK" && "$(readlink -f "$COMMAND_LINK")" == "$INSTALLED_SCRIPT" ]]; then
    rm -f -- "$COMMAND_LINK"
  fi
  systemd_available && systemctl daemon-reload
  prompt_yes_no delete_data "是否同时永久删除 $INSTALL_DIR 内的配置、密钥、日志和全部备份" 0
  if [[ "$delete_data" -eq 1 ]]; then
    prompt_text confirmation "此操作不可恢复，请输入 DELETE-ALL" "" 1
    if [[ "$confirmation" == "DELETE-ALL" && "$INSTALL_DIR" == "/opt/dujiao-backup" ]]; then
      rm -rf -- "$INSTALL_DIR"
      printf '卸载完成，所有本地数据已永久删除。\n'
    else
      die "二次确认不匹配；程序入口已卸载，但本地数据仍保留。"
    fi
  else
    rm -f -- "$INSTALLED_SCRIPT"
    printf '卸载完成；本地数据保留在 %s，可重新安装后继续使用。\n' "$INSTALL_DIR"
  fi
}

menu() {
  local choice archive
  require_root
  require_tty
  load_config || die "尚未完成安装，请先运行：bash dujiao-backup.sh install"
  while true; do
    heading "$PROGRAM_NAME v$VERSION"
    printf '  1) 立即执行完整备份\n'
    printf '  2) 查看运行状态\n'
    printf '  3) 配置部署/目标/保留数量\n'
    printf '  4) 定时任务管理\n'
    printf '  5) 查看本地备份\n'
    printf '  6) 查看远端备份\n'
    printf '  7) 校验备份包\n'
    printf '  8) 测试远端连接\n'
    printf '  9) 查看最近日志\n'
    printf ' 10) 检查并执行在线升级\n'
    printf ' 11) 显示宝塔计划任务命令\n'
    printf ' 12) 卸载管理器\n'
    printf '  0) 退出\n'
    prompt_choice choice "请选择" 0 12 0
    case "$choice" in
      1) run_child_command backup ;;
      2) run_child_command status ;;
      3) run_child_command configure ;;
      4) run_child_command timer-menu ;;
      5) list_local_backups ;;
      6) run_child_command list-remote ;;
      7)
        prompt_text archive "备份文件完整路径（直接回车校验最新一份）" "" 0
        if [[ -n "$archive" ]]; then
          run_child_command verify "$archive"
        else
          run_child_command verify
        fi
        ;;
      8) run_child_command test ;;
      9) show_logs ;;
      10) run_child_command update ;;
      11) show_baota_command ;;
      12)
        "$INSTALLED_SCRIPT" uninstall
        return 0
        ;;
      0)
        printf '已退出。\n'
        return 0
        ;;
    esac
    pause_for_enter
  done
}

install_program_files() {
  CURRENT_STEP="安装备份管理器文件"
  ensure_runtime_dirs
  if [[ "$SELF_PATH" != "$INSTALLED_SCRIPT" ]]; then
    install -o root -g root -m 0700 "$SELF_PATH" "$INSTALLED_SCRIPT"
  else
    chmod 0700 "$INSTALLED_SCRIPT"
    chown root:root "$INSTALLED_SCRIPT"
  fi
  bash -n "$INSTALLED_SCRIPT"
  if [[ -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]]; then
    die "$COMMAND_LINK 已存在且不是符号链接，请先人工确认该文件。"
  fi
  ln -sfn "$INSTALLED_SCRIPT" "$COMMAND_LINK"
}

restore_timer_after_install() {
  if [[ "$TIMER_ENABLED" -eq 1 ]]; then
    if systemd_available; then
      activate_timer
    else
      warn "配置要求启用定时，但当前没有运行 systemd；请使用宝塔计划任务。"
    fi
  fi
}

install_command() {
  local keep_existing run_now
  require_root
  require_tty
  start_log_capture
  heading "安装 $PROGRAM_NAME v$VERSION"
  info "程序、配置、日志、密钥与备份将统一放在：$INSTALL_DIR"
  install_base_dependencies
  install_program_files
  if [[ -f "$CONFIG_FILE" ]]; then
    if (load_config >/dev/null 2>&1); then
      load_config
      prompt_yes_no keep_existing "检测到现有配置，是否保留并继续使用" 1
    else
      warn "现有配置无法安全读取，将进入重新配置向导；旧文件会在成功保存时替换。"
      keep_existing="0"
    fi
  else
    keep_existing="0"
  fi
  if [[ "$keep_existing" -eq 0 ]]; then
    set_config_defaults
    choose_deployment_interactive
    configure_retention_interactive
    configure_targets_interactive
    save_config
    configure_timer_during_install
  else
    validate_deployment
    [[ "$OSS_ENABLED" -eq 0 ]] || install_ossutil
    restore_timer_after_install
  fi
  CURRENT_STEP="测试已启用的远端目标"
  test_targets_command
  prompt_yes_no run_now "是否现在立即生成第一份完整备份" 1
  [[ "$run_now" -eq 0 ]] || "$INSTALLED_SCRIPT" backup
  heading "安装成功"
  success "$PROGRAM_NAME v$VERSION 已安装并检查完成。"
  printf '管理菜单：%s\n' "$COMMAND_LINK"
  printf '立即备份：%s backup\n' "$COMMAND_LINK"
  printf '配置文件：%s\n' "$CONFIG_FILE"
  printf '日志文件：%s\n' "$LOG_FILE"
  printf '本地备份：%s\n' "$BACKUP_DIR"
  printf '\n宝塔 Shell 计划任务命令：\n%s backup --scheduled\n' "$COMMAND_LINK"
}

configure_command() {
  require_root
  require_tty
  ensure_runtime_dirs
  load_config || die "尚未安装。"
  configuration_menu
}

self_test() {
  local result
  DEPLOY_MODE="sqlite"
  APP_DIR="/opt/dujiao-next"
  set_deployment_paths
  [[ "$COMPOSE_FILE" == "/opt/dujiao-next/docker-compose.sqlite.yml" ]]
  [[ "$DB_FILE" == "/opt/dujiao-next/data/db/dujiao.db" ]]
  DEPLOY_MODE="postgres"
  set_deployment_paths
  [[ "$COMPOSE_FILE" == "/opt/dujiao-next/docker-compose.postgres.yml" ]]
  OSS_PREFIX="/dujiao-next/test/"
  result="$(normalize_oss_prefix "$OSS_PREFIX")"
  [[ "$result" == "dujiao-next/test" ]]
  result="$(normalize_oss_prefix '///dujiao-next/test///')"
  [[ "$result" == "dujiao-next/test" ]]
  valid_archive_name "dujiao-next-20260815-123456.tar"
  if valid_archive_name "dujiao-next-20260815-123456.tar.bad"; then return 1; fi
  TIMER_DAYS=0
  TIMER_HOURS=0
  TIMER_MINUTES=2
  [[ "$(timer_total_seconds)" -eq 120 ]]
  is_safe_absolute_path "/root/dujiao-backups"
  if is_safe_absolute_path "/root/../etc"; then return 1; fi
  if is_safe_absolute_path "/root/."; then return 1; fi
  validate_uint_between "8" 0 23
  if validate_uint_between "08" 0 23; then return 1; fi
  result="$(printf '%s\n' \
    'oss://bucket/prefix/dujiao-next-20260815-123457.tar' \
    'summary line' \
    'oss://bucket/prefix/dujiao-next-20260815-123456.tar' | parse_archive_names)"
  [[ "$result" == $'dujiao-next-20260815-123456.tar\ndujiao-next-20260815-123457.tar' ]]
  archive_array_contains "b" "a" "b" "c"
  if archive_array_contains "x" "a" "b" "c"; then return 1; fi
  result="$(printf '%s\n' '{' '  "Content-Length": "123",' '  "X-Oss-Meta-Dujiao-Sha256": "abc"' '}' | json_string_field 'Content-Length')"
  [[ "$result" == "123" ]]
  printf 'self-test: OK (v%s)\n' "$VERSION"
}

show_help() {
  cat <<HELP
$PROGRAM_NAME v$VERSION

用法：
  bash dujiao-backup.sh install    交互式安装
  dujiao-backup                    打开管理菜单
  dujiao-backup backup             立即完整备份
  dujiao-backup status             查看状态
  dujiao-backup test               测试远端目标
  dujiao-backup verify [文件]      校验备份包
  dujiao-backup update             在线升级
  dujiao-backup version            显示版本

项目：$REPOSITORY_URL
HELP
}

main() {
  local command="${1:-menu}"
  case "$command" in
    install) install_command ;;
    menu) menu ;;
    backup) backup_command ;;
    status) status_command ;;
    configure) configure_command ;;
    timer-menu)
      require_root
      require_tty
      timer_menu
      ;;
    test) test_targets_command ;;
    list-local) list_local_backups ;;
    list-remote) list_remote_backups ;;
    verify) verify_command "${2:-}" ;;
    logs) show_logs ;;
    update) update_command ;;
    baota) show_baota_command ;;
    uninstall) uninstall_command ;;
    version|--version|-v) printf '%s\n' "$VERSION" ;;
    self-test) self_test ;;
    help|--help|-h) show_help ;;
    *)
      show_help
      die "未知命令：$command"
      ;;
  esac
}

main "$@"
