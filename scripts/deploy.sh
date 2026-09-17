#!/usr/bin/env bash
#
# NexusPHP 部署：安装 CI 上传的代码包 → 备份上一版 → 拉起容器 → 初始化 → 健康检查。
#
#   ./scripts/deploy.sh <package.tar.gz> [ref]
#   ./scripts/deploy.sh --rollback <backup-dir>
#
# 环境变量：
#   MODE=dev|prod            默认 dev
#   RUN_INSTALL=true|false   默认 true（幂等执行 auto-install）
#   SYNC_ENV=true|false      默认 false（仅 dev：用 .env-dev 覆盖 .env）
#   ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD  auto-install 用
#   TARGET_DIR=/opt/nexusphp
#   BACKUP_DIR=/opt/nexusphp-backups
#   CONFIG_BACKUP_DIR=/opt/nexusphp-config-backup
#   PACKAGE_DIR=/opt/nexusphp-packages
#   KEEP_BACKUPS=5  KEEP_PACKAGES=5  HEALTH_RETRIES=20
set -Eeuo pipefail

TARGET_DIR=${TARGET_DIR:-/opt/nexusphp}
BACKUP_DIR=${BACKUP_DIR:-/opt/nexusphp-backups}
CONFIG_BACKUP_DIR=${CONFIG_BACKUP_DIR:-/opt/nexusphp-config-backup}
PACKAGE_DIR=${PACKAGE_DIR:-/opt/nexusphp-packages}
RUNNER=${RUNNER:-/opt/nexusphp-deploy/deploy.sh}
LOCK_FILE=${LOCK_FILE:-/var/lock/nexusphp-deploy.lock}

MODE=${MODE:-dev}
# 记录是否显式传入：回滚默认不跑 auto-install
RUN_INSTALL_SET=${RUN_INSTALL+x}
RUN_INSTALL=${RUN_INSTALL:-true}
SYNC_ENV=${SYNC_ENV:-false}
KEEP_BACKUPS=${KEEP_BACKUPS:-5}
KEEP_PACKAGES=${KEEP_PACKAGES:-5}
HEALTH_RETRIES=${HEALTH_RETRIES:-20}

log()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy:warn] %s\n' "$*" >&2; }
die()  { printf '[deploy:error] %s\n' "$*" >&2; exit 1; }

# 代码包里没有、必须保留在服务器上的路径（相对 TARGET_DIR）
PROTECTED=(
  .env .env-dev .env.bak .git .deployed-ref .deployed-composer-lock
  dont_delete_install.lock install.lock update.lock
  vendor node_modules storage bootstrap/cache
  attachments torrents subs plugins bitbucket
  resources/geoip resources/upload
  imdb/cache imdb/images
  public/install public/update public/storage public/hot public/dev.php
  public/attachments public/bitbucket public/torrents
  backup_data mysql_data redis_data
)

protected_regex() { local IFS='|'; printf '%s' "${PROTECTED[*]}"; }

compose() {
  docker compose --env-file "$TARGET_DIR/.env" -f "$TARGET_DIR/docker-compose.yml" "$@"
}

env_get() {
  local key=$1 default=${2-} line value
  line=$(grep -E "^${key}=" "$TARGET_DIR/.env" 2>/dev/null | tail -n1 || true)
  if [ -z "$line" ]; then
    printf '%s' "$default"
    return 0
  fi
  value=${line#*=}
  value=${value%$'\r'}
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}

service_id() { compose ps -q "$1" 2>/dev/null | head -n1 || true; }

backup_config() {
  mkdir -p "$CONFIG_BACKUP_DIR"
  local f
  for f in .env .env-dev; do
    if [ -f "$TARGET_DIR/$f" ]; then
      cp -a "$TARGET_DIR/$f" "$CONFIG_BACKUP_DIR/$f"
      log "backup config: $f"
    fi
  done
}

backup_code() {
  local stamp dir
  stamp=$(date +%Y%m%d%H%M%S)
  dir="$BACKUP_DIR/$stamp"
  mkdir -p "$dir"
  tar czf "$dir/code.tar.gz" -C "$TARGET_DIR" \
    --exclude=./.git --exclude=./vendor --exclude=./node_modules \
    --exclude=./.env --exclude=./.env-dev --exclude=./.env.bak \
    --exclude=./storage --exclude=./attachments --exclude=./torrents --exclude=./subs \
    --exclude=./plugins --exclude=./bitbucket \
    --exclude=./resources/upload --exclude=./resources/geoip \
    --exclude=./imdb/cache --exclude=./imdb/images \
    --exclude=./public/install --exclude=./public/attachments \
    --exclude=./public/bitbucket --exclude=./public/torrents \
    . 2>/dev/null || true
  printf '%s\n' "${REF:-unknown}" > "$dir/ref.txt"
  printf '%s\n' "$(date -Is)" > "$dir/deployed-at.txt"
  log "backup code: $dir ($(du -h "$dir/code.tar.gz" 2>/dev/null | cut -f1))"
  prune_backups
}

prune_backups() {
  local n=$((KEEP_BACKUPS + 1))
  ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n "+$n" | while read -r d; do
    rm -rf "$d"
    log "prune backup: $d"
  done
}

prune_packages() {
  local n=$((KEEP_PACKAGES + 1))
  ls -1dt "$PACKAGE_DIR"/*.tar.gz 2>/dev/null | tail -n "+$n" | while read -r f; do
    rm -f "$f"
    log "prune package: $(basename "$f")"
  done
}

# 停止应用容器，避免同步代码时半新半旧地对外服务
stop_app() {
  [ -f "$TARGET_DIR/.env" ] && [ -f "$TARGET_DIR/docker-compose.yml" ] || return 0
  local ids
  ids=$(compose ps -q php queue scheduler cleanup 2>/dev/null | tr '\n' ' ' || true)
  if [ -n "${ids// /}" ]; then
    log "stop app containers"
    compose stop -t 30 php queue scheduler cleanup >/dev/null 2>&1 || warn "stop 部分容器失败"
  fi
}

# 解包覆盖 + 删除包里已不存在的文件（等价 rsync --delete，但不碰 PROTECTED）
sync_code() {
  local pkg=$1 list cur del n
  [ -f "$pkg" ] || die "找不到代码包: $pkg"
  tar tzf "$pkg" >/dev/null 2>&1 || die "代码包不是有效的 tar.gz: $pkg"

  list=$(mktemp) ; cur=$(mktemp) ; del=$(mktemp)
  tar tzf "$pkg" | sed -e 's|^\./||' -e '/\/$/d' | grep -v '^$' | sort -u > "$list"
  mkdir -p "$TARGET_DIR"
  find "$TARGET_DIR" \( -type f -o -type l \) -printf '%P\n' 2>/dev/null | sort > "$cur"
  comm -23 "$cur" "$list" | grep -v -E "^($(protected_regex))(/|$)" > "$del" || true

  log "extract $(basename "$pkg")"
  tar xzf "$pkg" -C "$TARGET_DIR" --no-same-owner

  n=$(wc -l < "$del" | tr -d ' ')
  if [ "$n" != "0" ]; then
    log "remove $n stale files"
    while IFS= read -r f; do rm -f -- "$TARGET_DIR/$f"; done < "$del"
  fi
  rm -f "$list" "$cur" "$del"
}

install_runner() {
  local src="$TARGET_DIR/scripts/deploy.sh"
  [ -f "$src" ] || { warn "包里没有 scripts/deploy.sh，部署脚本保持原样"; return 0; }
  mkdir -p "$(dirname "$RUNNER")"
  if [ -f "$RUNNER" ] && [ "$(sha256sum "$src" | cut -d' ' -f1)" = "$(sha256sum "$RUNNER" | cut -d' ' -f1)" ]; then
    log "deploy script unchanged"
  else
    install -m 0755 "$src" "$RUNNER"
    log "deploy script updated -> $RUNNER（新逻辑下次部署生效）"
  fi
}

# 包内不含运行期目录（storage/attachments/...），首次部署或清理后需要补齐
ensure_dirs() {
  mkdir -p \
    "$TARGET_DIR/storage/framework/cache/data" \
    "$TARGET_DIR/storage/framework/sessions" \
    "$TARGET_DIR/storage/framework/views" \
    "$TARGET_DIR/storage/logs" \
    "$TARGET_DIR/bootstrap/cache" \
    "$TARGET_DIR/attachments" \
    "$TARGET_DIR/torrents" \
    "$TARGET_DIR/subs" \
    "$TARGET_DIR/imdb/cache" \
    "$TARGET_DIR/imdb/images" \
    "$TARGET_DIR/resources/upload" \
    "$TARGET_DIR/resources/geoip" \
    "$TARGET_DIR/public/attachments" \
    "$TARGET_DIR/public/torrents"
  mkdir -p \
    "$(env_get NP_MYSQL_DATA_PATH /opt/nexusphp-data/mysql)" \
    "$(env_get NP_REDIS_DATA_PATH /opt/nexusphp-data/redis)" \
    "$(env_get NP_BACKUP_DATA_PATH /opt/nexusphp-data/backup)"
}

ensure_env() {
  if [ ! -f "$TARGET_DIR/.env" ]; then
    if [ "$MODE" = "dev" ] && [ -f "$TARGET_DIR/.env-dev" ]; then
      cp -a "$TARGET_DIR/.env-dev" "$TARGET_DIR/.env"
      log "bootstrap .env from .env-dev"
    else
      die "$TARGET_DIR/.env 不存在：先运行 scripts/bootstrap-dev.sh 或手动放置 .env"
    fi
  elif [ "$MODE" = "dev" ] && [ "$SYNC_ENV" = "true" ] && [ -f "$TARGET_DIR/.env-dev" ]; then
    cp -a "$TARGET_DIR/.env-dev" "$TARGET_DIR/.env"
    log "sync .env <- .env-dev (SYNC_ENV=true)"
  fi
  [ -f "$TARGET_DIR/docker-compose.yml" ] || die "代码包里缺少 docker-compose.yml"
}

ensure_images() {
  local svc img
  for svc in php openresty; do
    img=$([ "$svc" = php ] && echo nexusphp_php || echo nexusphp-openresty)
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      log "build image: $svc"
      compose build "$svc"
    fi
  done
}

composer_install() {
  local hash saved
  hash=$(sha256sum "$TARGET_DIR/composer.lock" | cut -d' ' -f1)
  saved=$(cat "$TARGET_DIR/.deployed-composer-lock" 2>/dev/null || true)
  if [ ! -f "$TARGET_DIR/vendor/autoload.php" ] || [ "$hash" != "$saved" ]; then
    log "composer install"
    compose run --rm --no-deps --entrypoint composer php \
      install --working-dir=/var/www/html --no-interaction --prefer-dist || die "composer install 失败"
    printf '%s\n' "$hash" > "$TARGET_DIR/.deployed-composer-lock"
  else
    log "composer dependencies unchanged"
  fi
}

wait_for_db() {
  local i id pass
  id=$(service_id mysql)
  if [ -n "$id" ]; then
    log "wait for mysql"
    for i in $(seq 1 90); do
      docker exec "$id" mysqladmin ping -h127.0.0.1 --silent >/dev/null 2>&1 && break
      [ "$i" = "90" ] && die "MySQL 90s 内未就绪"
      sleep 2
    done
  else
    warn "compose 中没有运行中的 mysql 服务，跳过等待"
  fi

  id=$(service_id redis)
  if [ -n "$id" ]; then
    log "wait for redis"
    pass=$(env_get REDIS_PASSWORD '')
    for i in $(seq 1 30); do
      if [ -n "$pass" ]; then
        docker exec "$id" redis-cli -a "$pass" --no-auth-warning ping >/dev/null 2>&1 && break
      else
        docker exec "$id" redis-cli ping >/dev/null 2>&1 && break
      fi
      [ "$i" = "30" ] && die "Redis 60s 内未就绪"
      sleep 2
    done
  fi
}

auto_install() {
  if [ "$RUN_INSTALL" != "true" ]; then
    log "skip auto-install (RUN_INSTALL=$RUN_INSTALL)"
    return 0
  fi
  if [ ! -f "$TARGET_DIR/scripts/auto-install.php" ]; then
    warn "scripts/auto-install.php 不在代码包中，跳过 auto-install"
    return 0
  fi
  local id
  id=$(service_id php)
  [ -n "$id" ] || die "php 容器未运行，无法执行 auto-install"
  log "auto-install (idempotent)"
  docker exec -w /var/www/html \
    -e ADMIN_USERNAME="${ADMIN_USERNAME:-admin}" \
    -e ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}" \
    -e ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
    "$id" php scripts/auto-install.php || die "auto-install 失败"
}

refresh_install_dir() {
  if [ -f "$TARGET_DIR/dont_delete_install.lock" ]; then
    log "dont_delete_install.lock 存在，保留 public/install"
    return 0
  fi
  if [ -d "$TARGET_DIR/nexus/Install/install" ]; then
    rm -rf "$TARGET_DIR/public/install"
    cp -a "$TARGET_DIR/nexus/Install/install" "$TARGET_DIR/public/install"
    log "refresh public/install"
  fi
}

up_stack() {
  log "compose up -d (mysql redis first)"
  compose up -d mysql redis
  wait_for_db
  log "compose up -d"
  compose up -d --remove-orphans
  # openresty 的 entrypoint.sh / nginx.conf 是单文件 bind mount，重建才能拿到新内容
  compose up -d --force-recreate --no-deps openresty >/dev/null
}

health_check() {
  local port code i
  port=$(env_get NP_PORT '80')
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/login.php" 2>/dev/null || true)
    case "$code" in
      200 | 301 | 302) log "health ok: HTTP $code"; return 0 ;;
    esac
    sleep 3
  done
  printf '\n--- compose ps ---\n' >&2
  compose ps >&2 || true
  printf '\n--- openresty logs ---\n' >&2
  compose logs --tail=30 openresty >&2 || true
  printf '\n--- php logs ---\n' >&2
  compose logs --tail=30 php >&2 || true
  die "健康检查失败: HTTP ${code:-none} (http://127.0.0.1:$port/login.php)"
}

activate() {
  ensure_env
  ensure_dirs
  ensure_images
  composer_install
  up_stack
  auto_install
  refresh_install_dir
  health_check
  printf '%s\n' "${REF:-unknown}" > "$TARGET_DIR/.deployed-ref"
}

deploy_package() {
  local pkg=$1
  backup_config
  [ -d "$TARGET_DIR" ] && backup_code
  stop_app
  sync_code "$pkg"
  install_runner
  activate
  prune_packages
}

rollback() {
  local dir=$1
  [ -f "$dir/code.tar.gz" ] || die "备份目录里没有 code.tar.gz: $dir"
  [ -n "$RUN_INSTALL_SET" ] || RUN_INSTALL=false
  backup_config
  [ -d "$TARGET_DIR" ] && backup_code
  stop_app
  sync_code "$dir/code.tar.gz"
  log "rollback from $dir"
  activate
}

main() {
  if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ] || [ -z "${1-}" ]; then
    cat <<'USAGE'
用法:
  scripts/deploy.sh <package.tar.gz> [ref]     # 部署代码包
  scripts/deploy.sh --rollback <backup-dir>    # 回滚到某次备份
环境变量: MODE RUN_INSTALL SYNC_ENV ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD
USAGE
    exit 0
  fi
  command -v docker >/dev/null || die "缺少 docker"
  command -v flock  >/dev/null || die "缺少 flock"
  mkdir -p "$BACKUP_DIR" "$PACKAGE_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有部署在运行（$LOCK_FILE）"

  if [ "$1" = "--rollback" ]; then
    [ -n "${2-}" ] || die "--rollback 需要备份目录参数"
    REF="rollback:$(basename "$2")"
    rollback "$2"
  else
    REF=${2:-$(basename "$1")}
    deploy_package "$1"
  fi

  log "done ref=$REF mode=$MODE env=$(env_get APP_ENV unknown)"
  log "backups: $BACKUP_DIR   config: $CONFIG_BACKUP_DIR"
  log "rollback: $RUNNER --rollback $BACKUP_DIR/<timestamp>"
}

main "$@"
