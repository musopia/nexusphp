#!/usr/bin/env bash
# 仅更新生产站代码，沿用现有 .env；要求 APP_ENV=production。
set -Eeuo pipefail
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/deploy.sh" prod "$@"
