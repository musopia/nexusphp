# dev 发布流程

代码以「CI 打包上传 → 服务器备份并部署」的方式发布，服务器上不再执行 git 操作。

## 触发

GitHub → Actions → **Deploy Dev**（仅手动 `workflow_dispatch`）

- `ref`：要部署的分支 / tag / commit，默认 `dev`
- `run_install`：是否执行幂等的 auto-install，默认 `true`

同一条流水线也可在本地跑：`./deploy-dev.sh [ref]`。
本地跑之前先在仓库根目录建一个 gitignored 的 `.deploy-dev.env` 放服务器地址：

```bash
SSH_HOST=你的服务器IP
# 可选：SSH_USER / SSH_KEY / SSH_PORT
```

## 步骤

1. **打包**：`scripts/package.sh` 把当前代码打成 tar.gz——不含 `.git`、`vendor`、密钥、运行期数据，换行统一为 LF、权限归一（目录 755 / 文件 644 / `*.sh` 755）。
2. **上传**：scp 到服务器 `/opt/nexusphp-packages/`（保留最近 5 个包）。
3. **服务器**：`/opt/nexusphp-deploy/deploy.sh <package.tar.gz> <ref>`
   - 备份 `.env`、`.env-dev` → `/opt/nexusphp-config-backup/`
   - 备份当前代码 → `/opt/nexusphp-backups/<时间戳>/code.tar.gz`（保留最近 5 份）
   - 停 `php` / `queue` / `scheduler` / `cleanup`，避免同步时半新半旧对外服务
   - 解包覆盖，并删除包中已不存在的文件（`.env`、`vendor`、`storage`、`bootstrap/cache`、`attachments` 等路径受保护，永不被删）
   - 用包里的 `scripts/deploy.sh` 更新自身（新逻辑下次部署生效）
   - `composer install`：仅当 `composer.lock` 变化或 `vendor/autoload.php` 缺失
   - 先起 `mysql`/`redis` 并等就绪，再起其余服务，最后重建 `openresty`
   - `RUN_INSTALL=true` 时执行 `scripts/auto-install.php`（幂等）
   - 健康检查 `http://127.0.0.1:$NP_PORT/login.php`（200/301/302 通过，失败打印 compose 状态与日志）

## 回滚

```bash
/opt/nexusphp-deploy/deploy.sh --rollback /opt/nexusphp-backups/<时间戳>
```

回滚会先给当前代码留一份备份，且默认不执行 auto-install（`RUN_INSTALL` 未显式指定时视为 false）。

## 服务器目录

| 路径 | 用途 |
| --- | --- |
| `/opt/nexusphp` | 代码（compose 以 bind mount 挂进容器） |
| `/opt/nexusphp-config-backup` | `.env` / `.env-dev` 备份 |
| `/opt/nexusphp-backups` | 代码备份（可回滚） |
| `/opt/nexusphp-packages` | 上传的代码包 |
| `/opt/nexusphp-deploy/deploy.sh` | 部署脚本本体 |
| `/opt/nexusphp-data` | mysql / redis / backup 数据 |

`.env` 与 `.env-dev` 只存在于服务器，不进代码包、不进仓库（已在 `.gitignore`）。

## 新服务器首次部署

1. 放好 `/opt/nexusphp/.env-dev`（含 `APP_KEY`、`DB_*`、`REDIS_*`、`NP_*`）。
2. 上传一个代码包，然后 bootstrap 一次：

   ```bash
   bash scripts/bootstrap-dev.sh <package.tar.gz> --runner /opt/nexusphp-deploy/deploy.sh
   ```

   runner 已存在时跳过即可；CI 在 runner 缺失时也会自动 bootstrap。
3. 之后走 CI 或 `./deploy-dev.sh`。

## CI 配置

- secrets：`DEPLOY_HOST`、`DEPLOY_USER`、`DEPLOY_KEY`、`DEPLOY_PORT`（可选）、`DEV_ADMIN_PASSWORD`（可选）
- vars：`DEV_ADMIN_USERNAME`、`DEV_ADMIN_EMAIL`（可选，默认 `admin` / `admin@example.com`）

未提供 `DEV_ADMIN_PASSWORD` 时，auto-install 会生成随机管理员密码并打印在部署日志里。
