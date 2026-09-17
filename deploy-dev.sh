#!/usr/bin/env bash
#
# 本地发布到 dev 服：打包工作区 → scp 上传 → 必要时 bootstrap → 备份并部署。
# 与 .github/workflows/deploy-dev.yml 走同一条路径，用于本地/应急发布。
#
#   ./deploy-dev.sh [ref]
#
# 环境变量：
#   SSH_USER   默认 root
#   SSH_KEY    默认 ~/.ssh/id_private.rsa.openssh
#   SSH_PORT   默认 22
#   RUN_INSTALL / SYNC_ENV / ADMIN_USERNAME / ADMIN_EMAIL / ADMIN_PASSWORD
#
# SSH_HOST 不进仓库，放在本地 .deploy-dev.env（已 gitignore），例如：
#   SSH_HOST=1.2.3.4
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ref=${1:-dev}

if [ -f "$root/.deploy-dev.env" ]; then
  # shellcheck disable=SC1090
  . "$root/.deploy-dev.env"
fi

SSH_HOST=${SSH_HOST:-}
SSH_USER=${SSH_USER:-root}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_private.rsa.openssh}
SSH_PORT=${SSH_PORT:-22}
REMOTE_PACKAGE_DIR=${REMOTE_PACKAGE_DIR:-/opt/nexusphp-packages}
REMOTE_RUNNER=${REMOTE_RUNNER:-/opt/nexusphp-deploy/deploy.sh}
MODE=${MODE:-dev}
RUN_INSTALL=${RUN_INSTALL:-true}

log() { printf '[deploy-dev] %s\n' "$*"; }
die() { printf '[deploy-dev:error] %s\n' "$*" >&2; exit 1; }

[ -n "$SSH_HOST" ] || die "未设置 SSH_HOST：写入 $root/.deploy-dev.env（SSH_HOST=x.x.x.x）或用环境变量传入"
[ -f "$SSH_KEY" ] || die "找不到 SSH 私钥: $SSH_KEY"

sha=$(cd "$root" && git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)
pkg="$root/nexusphp-$sha-$(date +%Y%m%d%H%M%S).tar.gz"
pkg_name=$(basename "$pkg")

log "package ref=$ref -> $pkg_name"
bash "$root/scripts/package.sh" "$pkg" "$ref" >/dev/null
log "size $(du -h "$pkg" | cut -f1)"

ssh_base=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SSH_HOST")
scp_base=(scp -i "$SSH_KEY" -P "$SSH_PORT" -o BatchMode=yes)

log "upload -> $SSH_HOST:$REMOTE_PACKAGE_DIR"
"${ssh_base[@]}" "mkdir -p '$REMOTE_PACKAGE_DIR'"
"${scp_base[@]}" "$pkg" "$SSH_USER@$SSH_HOST:$REMOTE_PACKAGE_DIR/$pkg_name" >/dev/null
rm -f "$pkg"

# 远端脚本：本地变量在 heredoc 里展开，密码用 %q 转义
admin_password_q=$(printf '%q' "${ADMIN_PASSWORD:-}")
"${ssh_base[@]}" bash -s <<REMOTE
set -Eeuo pipefail
PKG="$REMOTE_PACKAGE_DIR/$pkg_name"
RUNNER="$REMOTE_RUNNER"
[ -f "\$PKG" ] || { echo "远端代码包不存在: \$PKG" >&2; exit 1; }

if [ ! -x "\$RUNNER" ]; then
  echo ">> 首次部署：bootstrap 部署脚本"
  rm -rf /tmp/nexusphp-boot
  mkdir -p /tmp/nexusphp-boot
  tar xzf "\$PKG" -C /tmp/nexusphp-boot ./scripts ./docker-compose.yml
  bash /tmp/nexusphp-boot/scripts/bootstrap-dev.sh "\$PKG" --runner "\$RUNNER"
fi

RUN_INSTALL="$RUN_INSTALL" MODE="$MODE" SYNC_ENV="${SYNC_ENV:-false}" \
  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}" \
  ADMIN_EMAIL="${ADMIN_EMAIL:-}" \
  ADMIN_PASSWORD=$admin_password_q \
  "\$RUNNER" "\$PKG" "$ref"
REMOTE

log "done"
