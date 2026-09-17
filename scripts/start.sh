#!/usr/bin/env bash
#
# 本地/开发机一键启动：compose up + 初始化。
# 生产式发布请用 scripts/deploy.sh（走上传的代码包）。
#
#   ./scripts/start.sh
#   DEPLOY_ENV=dev ./scripts/start.sh        # 强制使用 .env-dev
#   ADMIN_PASSWORD=xxx ./scripts/start.sh
set -Eeuo pipefail

cd "$(dirname "$0")/.."

ADMIN_USERNAME=${ADMIN_USERNAME:-admin}
ADMIN_EMAIL=${ADMIN_EMAIL:-${ADMIN_USERNAME}@example.com}

log()  { printf '[start] %s\n' "$*"; }
warn() { printf '[start:warn] %s\n' "$*" >&2; }
die()  { printf '[start:error] %s\n' "$*" >&2; exit 1; }

if [ ! -f .env ] && [ -f .env-dev ]; then
  log "copy .env-dev -> .env (missing)"
  cp -a .env-dev .env
elif [ "${DEPLOY_ENV:-}" = "dev" ] && [ -f .env-dev ]; then
  log "copy .env-dev -> .env (dev)"
  cp -a .env-dev .env
fi

[ -f .env ] || die "缺少 .env 或 .env-dev"
[ -f docker-compose.yml ] || die "缺少 docker-compose.yml"

mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views \
  storage/logs bootstrap/cache attachments torrents subs imdb/cache imdb/images \
  resources/upload resources/geoip public/attachments public/torrents

compose() { docker compose --env-file .env "$@"; }
service_id() { compose ps -q "$1" 2>/dev/null | head -n1 || true; }

log "compose up -d mysql redis"
compose up -d mysql redis

log "wait mysql"
id=$(service_id mysql)
for i in $(seq 1 90); do
  [ -n "$id" ] && docker exec "$id" mysqladmin ping -h127.0.0.1 --silent >/dev/null 2>&1 && break
  [ "$i" = "90" ] && die "MySQL 未就绪"
  sleep 2
done

log "compose up -d"
compose up -d --remove-orphans

if [ -f scripts/auto-install.php ]; then
  id=$(service_id php)
  [ -n "$id" ] || die "php 容器未运行"
  log "auto-install (idempotent)"
  docker exec -w /var/www/html \
    -e ADMIN_USERNAME="$ADMIN_USERNAME" \
    -e ADMIN_EMAIL="$ADMIN_EMAIL" \
    -e ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
    "$id" php scripts/auto-install.php || die "auto-install 失败"
else
  warn "scripts/auto-install.php 不存在，跳过 auto-install"
fi

log "done $(grep -E '^APP_URL=' .env | cut -d= -f2-)"
