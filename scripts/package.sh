#!/usr/bin/env bash
#
# 打包当前工作区代码，供上传部署使用（CI 与本地共用）。
# 上传的包只含代码：不含 .git、依赖、密钥、运行期数据。
#
#   ./scripts/package.sh <output.tar.gz> [ref]
#
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:?usage: package.sh <output.tar.gz>}
ref=${2:-}

case "$out" in
  /*) ;;
  *) out="$root/$out" ;;
esac
mkdir -p "$(dirname -- "$out")"
rm -f -- "$out"

# 先写到临时目录再移动：避免打包产物落在被归档的目录里导致 tar 报 "file changed as we read it"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/$(basename -- "$out")"
tree="$tmp/tree"
mkdir -p "$tree"

tar cf - -C "$root" \
  --exclude=./.git \
  --exclude=./.github \
  --exclude=./.idea \
  --exclude=./.vscode \
  --exclude=./.history \
  --exclude=./vendor \
  --exclude=./node_modules \
  --exclude=./.env \
  --exclude=./.env-dev \
  --exclude=./.env.bak \
  --exclude=./storage \
  --exclude=./attachments \
  --exclude=./torrents \
  --exclude=./subs \
  --exclude=./plugins \
  --exclude=./bitbucket \
  --exclude=./resources/geoip \
  --exclude=./resources/upload \
  --exclude=./imdb/cache \
  --exclude=./imdb/images \
  --exclude=./public/install \
  --exclude=./public/update \
  --exclude=./public/attachments \
  --exclude=./public/bitbucket \
  --exclude=./public/torrents \
  --exclude=./public/hot \
  --exclude=./public/storage \
  --exclude=./public/dev.php \
  --exclude=./deploy \
  --exclude=./deploy-mention \
  --exclude=./mention-demo \
  --exclude=./*.tar.gz \
  --exclude=./*.zip \
  . | tar xf - -C "$tree"

# Windows 工作区默认 CRLF，直接打包会把 CR 带进 Linux 容器（sh 脚本会直接报错）。
# grep 无匹配时退出码为 1；在 set -Eeuo pipefail 下不能直接放进管道/命令替换，否则 CI 静默失败。
crlf_list="$tmp/crlf.list"
: >"$crlf_list"
grep -rlI $'\r' "$tree" >"$crlf_list" 2>/dev/null || true
changed=$(wc -l <"$crlf_list" | tr -d ' ')
if [ "$changed" != "0" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -i 's/\r$//' "$f"
  done <"$crlf_list"
fi

# 权限归一：目录 0755、文件 0644、脚本可执行（Windows 挂载点会全部报 0777）
find "$tree" -type d -exec chmod 0755 {} +
find "$tree" -type f -exec chmod 0644 {} +
find "$tree" -type f -name '*.sh' -exec chmod 0755 {} +
if [ -f "$tree/artisan" ]; then chmod 0755 "$tree/artisan"; fi

tar czf "$stage" -C "$tree" .

mv -f -- "$stage" "$out"

printf 'package: %s\n' "$out"
printf 'size:    %s\n' "$(du -h "$out" | cut -f1)"
printf 'files:   %s\n' "$(tar tzf "$out" | wc -l | tr -d ' ')"
printf 'crlf fixed: %s\n' "$changed"
