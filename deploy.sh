#!/usr/bin/env bash
# Code-only updates. No migrations, dependency installation, image builds or config replacement.
set -Eeuo pipefail

main() {
    local mode=${1:-} ref=${2:-} branch target old_commit env_mode service id
    local -a containers=()
    if [[ "$mode" == -h || "$mode" == --help || -z "$mode" ]]; then
        echo 'Usage: ./deploy-dev.sh [Git ref] | ./deploy-prod.sh [Git ref]'
        echo 'Updates Git code and restarts existing PHP application containers only.'
        return 0
    fi
    [[ "$mode" == dev || "$mode" == prod ]] && [[ $# -le 2 ]] || { echo 'Invalid arguments.' >&2; return 1; }
    root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    cd "$root"
    for tool in git docker python3 flock; do
        command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; return 1; }
    done
    git() { command git -c safe.directory="$root" "$@"; }
    [[ -d .git && -f .env && -f vendor/autoload.php ]] || {
        echo 'Complete the initial installation first; this script only updates installed sites.' >&2; return 1;
    }
    # Both modes use the site's existing .env. Never copy or rewrite environment files.
    env_mode=$(python3 - <<'PY'
from pathlib import Path
for line in Path('.env').read_text().splitlines():
    if line.startswith('APP_ENV='):
        print(line.split('=', 1)[1].strip().strip('"\''))
        break
PY
)
    if [[ "$mode" == prod && "$env_mode" != production ]] || [[ "$mode" == dev && "$env_mode" == production ]]; then
        echo "Selected mode does not match APP_ENV in the existing .env." >&2; return 1
    fi
    exec 9>"$root/.deploy.lock"
    flock -n 9 || { echo 'Another deployment is running.' >&2; return 1; }
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || {
        echo 'Tracked files have local changes. Resolve them first; no changes will be discarded.' >&2; return 1;
    }
    old_commit=$(git rev-parse HEAD)
    git fetch origin --tags
    if [[ -z "$ref" ]]; then
        branch=$(git symbolic-ref --quiet --short HEAD) || {
            echo 'Detached HEAD: specify a Git tag/commit or switch back to a branch first.' >&2; return 1;
        }
        target=$(git rev-parse --verify "refs/remotes/origin/$branch^{commit}")
        git merge-base --is-ancestor "$old_commit" "$target" || {
            echo 'Branch diverged from origin; resolve it before updating.' >&2; return 1;
        }
    else
        [[ "$ref" != -* ]] || { echo 'Invalid Git ref.' >&2; return 1; }
        target=$(git rev-parse --verify "$ref^{commit}")
    fi
    if [[ "$old_commit" == "$target" ]]; then
        echo "Code is already at $target; nothing restarted."
        return 0
    fi
    # Refuse versions that explicitly require dependency/schema work. Never perform it automatically.
    if ! git diff --quiet "$old_commit" "$target" -- composer.json composer.lock package.json package-lock.json database/migrations; then
        echo 'Target changes dependency definitions or database migrations. Code-only deployment stopped; select a compatible version.' >&2
        return 1
    fi
    # Application config and local data must never be overwritten by a Git update.
    if ! git diff --quiet "$old_commit" "$target" -- .env .env.dev .env.prod mysql_data redis_data backup_data storage attachments public/attachments public/torrents; then
        echo 'Target changes protected environment/data files. Code-only deployment stopped.' >&2
        return 1
    fi
    # Capture current IDs before checkout; do not apply the target Compose configuration.
    for service in php queue scheduler cleanup; do
        id=$(docker compose --env-file "$root/.env" ps -q "$service")
        [[ -n "$id" ]] || { echo "Existing $service container is not running; fix the deployment first." >&2; return 1; }
        containers+=("$id")
    done
    echo "Updating code: $old_commit -> $target"
    # Stop writers during checkout. MySQL, Redis, OpenResty and phpMyAdmin are untouched.
    stopped_containers=("${containers[@]}")
    trap 'rc=$?; if (( rc != 0 )); then echo "Code update failed. No database migration, dependency installation or image update was performed." >&2; echo "Check Git status and application logs, then start the existing application containers when ready." >&2; fi' EXIT
    docker stop --time 30 "${containers[@]}"
    if [[ -z "$ref" ]]; then
        git merge --ff-only "$target"
    else
        git checkout --detach "$target"
    fi
    # Start these exact containers, retaining their images, mounts and environment.
    docker start "${containers[@]}"
    for id in "${containers[@]}"; do
        [[ $(docker inspect --format '{{.State.Status}}' "$id") == running ]] || {
            echo "Application container failed to start: $id" >&2; return 1;
        }
    done
    trap - EXIT
    printf 'Code updated (%s): %s\nPrevious commit: %s\n' "$mode" "$target" "$old_commit"
    echo 'Existing application containers restarted. Check application logs for runtime compatibility.'
}

main "$@"
