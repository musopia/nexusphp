#!/usr/bin/env bash
# 仅更新开发站代码，沿用现有 .env；不迁移数据库、不安装依赖、不更新镜像。
set -Eeuo pipefail
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy.sh" dev "$@"
