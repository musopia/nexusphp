#!/usr/bin/env bash
#
# 服务器首次部署前的准备（幂等）：铺代码包 + 安装部署脚本。
# 之后所有发布都走 deploy.sh，本脚本无需再跑。
#
#   ./scripts/bootstrap-dev.sh <package.tar.gz>
#   ./scripts/bootstrap-dev.sh <package.tar.gz> --runner <path>
#
# 前置条件：.env-dev（或 .env）已放在 TARGET_DIR，bootstrap 不会生成密钥。
set -Eeuo pipefail

TARGET_DIR=${TARGET_DIR:-/opt/nexusphp}
RUNNER=${RUNNER:-/opt/nexusphp-deploy/deploy.sh}

log()  { printf '[bootstrap] %s\n' "$*"; }
die()  { printf '[bootstrap:error] %s\n' "$*" >&2; exit 1; }

pkg=${1-}
[ -n "$pkg" ] || die "用法: bootstrap-dev.sh <package.tar.gz>"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER=${2:?--runner 需要路径}; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done

command -v docker >/dev/null || die "缺少 docker"
[ -f "$pkg" ] || die "找不到代码包: $pkg"
tar tzf "$pkg" >/dev/null 2>&1 || die "代码包无效: $pkg"

log "target: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

log "extract package"
tar xzf "$pkg" -C "$TARGET_DIR" --no-same-owner

if [ ! -f "$TARGET_DIR/.env" ] && [ ! -f "$TARGET_DIR/.env-dev" ]; then
  die "$TARGET_DIR 里没有 .env / .env-dev：请先把服务器环境文件放好（含 APP_KEY、DB_*、REDIS_*、NP_*），再跑 deploy.sh"
fi

[ -f "$TARGET_DIR/scripts/deploy.sh" ] || die "代码包里缺少 scripts/deploy.sh"
mkdir -p "$(dirname "$RUNNER")"
install -m 0755 "$TARGET_DIR/scripts/deploy.sh" "$RUNNER"
log "install runner: $RUNNER"

log "bootstrap done; next: $RUNNER $(basename "$pkg") dev"
