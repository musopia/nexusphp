中文 | [English](/README-EN.md)

完整的 PT 建站解决方案。基于 NexusPHP + Laravel + FilamentPHP。

欢迎参与国际化工作，点击 [这里](https://github.com/xiaomlove/nexusphp/discussions/193) 了解详情

## 功能特性
- 发种
- 特别区  
- 求种
- 字幕
- 考核
- H&R
- 认领
- 审核  
- 签到
- 补签卡  
- 勋章
- 道具 
- 自定义标签
- 第三方全文搜索
- 盒子规则  
- 论坛 
- 申诉  
- 多语言
- 自动备份
- 插件支持  
- 管理后台  
- Json API
- ....

#### 以下功能由插件提供
- 帖子点赞
- 帖子奖励
- 置顶促销
- 自定义菜单
- 幸运大转盘
- 自定义角色权限
- 分区 H&R
- TGBot

## 系统要求
- PHP: 8.2|8.3|8.4|8.5，必须扩展：bcmath, ctype, curl, fileinfo, json, mbstring, openssl, pdo_mysql, tokenizer, xml, mysqli, gd, redis, pcntl, sockets, posix, gmp, zend opcache, zip, intl, pdo_sqlite, sqlite3, pdo_pgsql
- Database: MySQL 5.7 最新版或以上版本/PostgreSQL 16 或以上版本
- Redis：4.0.0 或以上版本
- 其他：supervisor, rsync

## 快速开始
安装 docker。  
其中 DOMAIN 是你要使用的域名，先做好解析。 没有域名使用 IP 亦可。   
端口按需要指定，如果本地 80 端口已经使用，请更换，保证端口对外开放。  
第 2 步创建 .env 选择正确的时区 TIMEZONE，其他默认即可。
```
docker pull xiaomlove/nexusphp:latest
docker run --name my-nexusphp -e DOMAIN=xxx.com -p 80:80 xiaomlove/nexusphp:latest
```
**生产环境建议参考文档实机安装。**

## Compose 开发部署与数据存储

本地 `.env.dev` 已提供开发配置（包含随机生成的应用密钥、MySQL 和 Redis 密码，已忽略 Git 跟踪）。应用读取项目根目录 `.env`，仅传 `--env-file` 不会切换应用配置。新开发部署执行：

```sh
cp .env.dev .env
docker compose config --quiet
docker compose up -d --build
```

已有 `.env` 时先保留原配置，特别是应用密钥和数据库密码。默认开发访问地址为 `http://108.186.129.34:8080`，其他主机需同步修改 `APP_URL` 和 `NP_DOMAIN`。首次部署仍需完成网站安装及管理员账户创建；数据库账户不是网站管理员。

容器之间的 PHP、phpMyAdmin、MySQL 和 Redis 连接通过 `extra_hosts` 的 `host.docker.internal:host-gateway` 访问宿主机映射端口，需要 Docker Engine 20.10+。`NP_HOST_BIND` 默认 `172.17.0.1`，启动前用 `docker network inspect bridge` 核对网关地址并按实际修改；该地址需与 `host-gateway` 一致且容器能访问。内部服务端口仅绑定此网桥地址，网站端口对外发布。MySQL/Redis 默认映射端口分别为 13306/16379，PHP/phpMyAdmin 为 19000/18081，可在环境变量中调整。

- `NP_MYSQL_DATA_PATH=./mysql_data`：宿主机 MySQL 数据目录。
- `NP_REDIS_DATA_PATH=./redis_data`：宿主机 Redis 数据目录，启用密码认证和 AOF，每秒同步。
- `NP_BACKUP_DATA_PATH=./backup_data`：宿主机备份目录。
- `NP_BACKUP_EXPORT_PATH=/tmp/nexusphp_backup`：容器内备份目录，必须与站点后台设置一致。需启用或手动执行应用备份才会生成文件。

相对路径以 Compose 文件所在目录为基准。种子、附件、`storage` 等仍通过项目目录挂载保存。开发邮件使用 log 驱动，不实际发送；需要邮件功能时配置 SMTP。phpMyAdmin 使用独立虚拟主机；IP 开发环境建议自行配置可解析的域名再访问。

已有部署从命名卷或其他目录切换前，须停止应用写入，备份并迁移 MySQL、Redis 数据，保留文件所有权。空目录会初始化空数据库，不会自动迁移。旧 Redis RDB 切换 AOF 需先确认数据载入并生成 AOF 再重启。确认迁移成功前不要删除旧卷。备份站点文件时排除项目中的 mysql_data、redis_data、backup_data，数据库应使用数据库备份功能。

## 仅更新代码（完成首次安装后）

```sh
cd /opt/nexusphp
./deploy-dev.sh          # 开发站：更新当前分支代码
./deploy-prod.sh         # 生产站：更新当前分支代码，现有 .env 须为 APP_ENV=production
./deploy-prod.sh v1.2.3  # 可选：指定 Git 标签或提交
```

两个入口共用 `deploy.sh`，只更新 Git 代码、停止并启动现有 PHP/队列/定时任务/清理容器以加载新代码。使用更新前获取的容器 ID，不应用新版 Compose 配置。MySQL、Redis、OpenResty、phpMyAdmin 不重启、不升级；不会执行数据库备份或迁移、`nexus:update`、Composer/npm 安装、前端构建、镜像构建或拉取，也不会复制或改写 `.env`。首次安装时自行选择配置，后续更新沿用已有 `.env`。

宿主机需要 Bash、Git、Docker Compose v2、Python 3、flock。目标版本包含依赖定义、锁文件或数据库迁移变化时，在停止容器前拒绝更新，不能用代码更新代替必要的独立兼容性处理。前端资源应事先构建并随代码发布。代码自身仍须兼容现有数据库结构和依赖；脚本不能自动证明兼容性。当前版本无变化时不重启。

更新前检查工作区无已跟踪文件的本地修改；不覆盖本地改动、不清理数据目录。失败时停止后续操作，检查 Git 状态和应用日志后再启动现有应用容器。指定版本会进入 detached HEAD，后续应继续指定版本或先切回分支。dev/prod 是现有站点的模式检查，不是两套可同时运行的隔离环境。

## AD-服务器推荐
|服务商| 推广地址 |优惠码|
|---|---|---|
|[七七云](https://www.vps77.com/aff.php?aff=167&gid=1)   |https://www.vps77.com/aff.php?aff=167&gid=1|xiaomlove|

## 更多信息
博客：[https://nexusphp.org](http://nexusphp.org/)  
文档：[https://doc.nexusphp.org](http://doc.nexusphp.org/)  
Telegram: [https://t.me/nexusphp_dev](https://t.me/nexusphp_dev)  
