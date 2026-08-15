# Dujiao-Next Backup Manager

专用于 [Dujiao-Next 官方 Docker Compose 部署](https://dujiao-next.com/deploy/docker-compose) 的交互式完整备份管理器。

当前版本：`v1.1.5`

支持：

- 方案 A：SQLite + Redis（轻量部署）
- 方案 B：PostgreSQL + Redis（生产部署）
- 阿里云 OSS
- SFTP/SSH 异地服务器
- OSS 与 SFTP 双目标同时备份
- 本地及远端按数量保留，自动删除最旧备份
- systemd 间隔定时与宝塔计划任务
- 统一配置中心，可逐项修改 OSS、SFTP、定时任务及其他参数
- 菜单管理、连接测试、备份校验、在线升级和安全卸载

## 一键安装

请使用 `root` 登录 Debian 服务器后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/a06342637/ali-oss/main/dujiao-backup.sh \
  -o /tmp/dujiao-backup.sh && \
bash /tmp/dujiao-backup.sh install
```

脚本会自动安装所需工具，并依次询问关键配置。输入后按回车即可。

安装结束会明确显示成功或失败；失败时会显示当前步骤、退出码和失败命令。

## 安装时会询问什么

1. Dujiao-Next 安装目录，默认 `/opt/dujiao-next`
2. 自动识别部署模式；无法识别时手动选择 SQLite 或 PostgreSQL
3. 最多保留多少份完整备份
4. 备份目标：
   - 阿里云 OSS
   - SFTP/SSH
   - OSS + SFTP
   - 仅本地
5. 对应远端参数
6. 是否启用 systemd 定时，以及天、小时、分钟间隔
7. 是否立即生成第一份完整备份

## 阿里云 OSS 参数

安装向导会询问：

- AccessKey ID
- AccessKey Secret
- Region ID，例如 `cn-hangzhou`
- Endpoint，例如 `oss-cn-hangzhou.aliyuncs.com`
- Bucket 名称
- Bucket 内保存目录，例如 `dujiao-next/shop-01`
- Bucket 是否开启版本控制

Region ID 和 Endpoint 可在阿里云 OSS 控制台的 Bucket“概览”或“基本信息”中查看。

AccessKey 会保存在 `/opt/dujiao-backup/config.conf`，权限固定为 `0600`，只允许 root 读取。AccessKey 不会出现在计划任务命令中。

建议给 RAM 用户只授予目标 Bucket/目录所需的列举、读取、上传和删除权限，不要使用阿里云主账号 AccessKey。

### OSS 版本控制

如果 Bucket 开启版本控制，普通删除只会产生 DeleteMarker，历史版本仍会占用存储空间。

安装时可选择：

- 永久删除超出保留数的对象全部历史版本；或
- 不永久删除，由 OSS 控制台的生命周期规则清理“历史版本”和“过期删除标记”

若希望物理存储数量和脚本设置的上限一致，应启用“删除全部历史版本”，或正确配置 OSS 生命周期。

## SFTP/SSH 参数与安全机制

安装向导会询问：

- 远端 IP 或域名
- SSH/SFTP 端口，默认 `22`
- SSH 用户名，默认 `root`
- SSH 登录密码
- 远端保存目录，例如 `/root/dujiao-backups`

密码只用于首次向远端部署专用 Ed25519 公钥，不会写入配置、日志或计划任务。之后所有备份都使用专用密钥。

首次连接会显示远端 SSH 主机指纹，只有确认后才会继续。上传过程为：

1. 以 `.partial` 临时文件名通过 SFTP 上传
2. 在远端计算并比对 SHA256
3. 校验成功后原子改名为正式 `.tar`

这样不会把未上传完整的文件误认为有效备份。

## 定时规则

内置定时使用 systemd，按“上一轮结束后再等待设定间隔”的方式运行，避免任务堆积。

三个数字代表间隔，`0` 表示该项不参与：

- `0 天 0 小时 2 分钟`：每 2 分钟
- `0 天 6 小时 0 分钟`：每 6 小时
- `1 天 2 小时 30 分钟`：每 26 小时 30 分钟

三个数字不能全部为 `0`，最短间隔为 1 分钟。

运行下面命令进入管理菜单，可随时启用、修改或停用定时：

```bash
dujiao-backup
```

## 宝塔计划任务

宝塔中新增“Shell 脚本”计划任务，执行用户使用 root，脚本内容只有这一行：

```bash
/usr/local/bin/dujiao-backup backup --scheduled
```

周期在宝塔界面设置。脚本带进程锁，同一时间不会并发运行两份备份。

如果使用宝塔计划任务，请在管理菜单停用脚本内置 systemd 定时，避免两套定时重复触发。

## 管理菜单

运行：

```bash
dujiao-backup
```

菜单包含：

1. 立即执行完整备份
2. 查看运行状态
3. 统一配置中心（部署、OSS、SFTP、定时等）
4. 定时任务快捷管理
5. 查看本地备份
6. 查看远端备份
7. 校验备份包
8. 测试远端连接
9. 查看最近日志
10. 在线升级
11. 显示宝塔命令
12. 安全卸载

### 统一配置中心

主菜单选择 `3` 后，可以安全查看脱敏配置，并分别修改：

- Dujiao-Next 安装目录、SQLite/PostgreSQL 模式及 PostgreSQL 容器名
- 本地和远端最多保留数量
- OSS 启用状态、AccessKey、Region、Endpoint、Bucket、保存目录及版本控制策略
- SFTP 启用状态、服务器、端口、用户名、远端目录、主机指纹及密钥认证
- systemd 定时启停，以及天、小时、分钟间隔

OSS 与 SFTP 可以独立启用或停用，修改其中一个不会自动关闭另一个。修改已启用的远端参数时，脚本会先完成连接和上传测试，测试失败不会覆盖原配置。

SFTP 登录密码仍然不会保存；需要重新认证时只用于部署专用公钥。配置摘要不会显示 AccessKey Secret 等敏感值。

常用非交互命令：

```bash
dujiao-backup backup
dujiao-backup status
dujiao-backup configure
dujiao-backup test
dujiao-backup verify
dujiao-backup logs
dujiao-backup baota
dujiao-backup version
```

## 文件都在哪里

所有管理器数据集中在一个目录：

```text
/opt/dujiao-backup/
├── dujiao-backup.sh
├── config.conf
├── logs/
│   └── dujiao-backup.log
├── backups/
├── keys/
│   ├── sftp_ed25519
│   ├── sftp_ed25519.pub
│   └── known_hosts
├── state/
└── tmp/
```

快捷命令：

```text
/usr/local/bin/dujiao-backup
```

systemd 文件：

```text
/etc/systemd/system/dujiao-backup.service
/etc/systemd/system/dujiao-backup.timer
```

## 每个 TAR 包包含什么

每个 `dujiao-next-YYYYMMDD-HHMMSS.tar` 都是可独立恢复的完整备份。

PostgreSQL 模式：

```text
database.dump
uploads.tar.gz
config.tar.gz
manifest.txt
SHA256SUMS
```

SQLite 模式：

```text
database.sqlite
uploads.tar.gz
config.tar.gz
manifest.txt
SHA256SUMS
```

文件说明：

- `database.dump`：PostgreSQL custom-format 数据库导出
- `database.sqlite`：SQLite 在线一致性快照
- `uploads.tar.gz`：商品图片和其他上传文件
- `config.tar.gz`：`.env`、`config/config.yml` 和当前 Compose 文件
- `manifest.txt`：备份时间、模式、镜像、文件数量等说明
- `SHA256SUMS`：包内文件校验值

Redis 不备份。Dujiao-Next 的 Redis 用于缓存和队列，业务真数据应以数据库、上传文件和配置为准。

## 保留与同步逻辑

假设最多保留 `100` 份：

- 第 101 份完成并成功同步到所有已启用目标后，删除第 1 份
- 本地、OSS 和 SFTP 删除相同文件名
- 如果任一远端上传失败，不执行保留清理，允许本地暂时超过 100 份，优先避免丢失备份
- 下次运行会继续同步尚未成功的本地备份
- 如果远端某份保留中的备份被人工删除或被生命周期规则清除，下次运行会根据本地保留副本自动补传
- OSS 每次上传后都会核对远端大小及脚本写入的 SHA256 元数据；SFTP 会在远端直接计算 SHA256
- 切换 Bucket、OSS 目录、SFTP 主机或远端目录后，目标指纹会变化，现有本地备份会同步到新目标

所以手动运行一次时，如果发现多份本地备份尚未同步，日志中可能会连续上传多份，这是正常的补传行为。

## 校验备份

校验最新一份：

```bash
dujiao-backup verify
```

校验指定文件：

```bash
dujiao-backup verify /opt/dujiao-backup/backups/dujiao-next-20260815-120000.tar
```

校验包括：

- 外层 TAR 结构和路径安全
- `SHA256SUMS`
- 两个内层压缩包
- SQLite `PRAGMA quick_check`
- PostgreSQL `pg_restore --list`（当前服务器有可用 PostgreSQL 容器时）

## 手动恢复说明

恢复会覆盖线上数据，建议先在新机器或测试环境演练，并在操作前再备份一次当前状态。

先解包并校验：

```bash
mkdir -p /root/dujiao-restore
cd /root/dujiao-restore
tar -xf /path/to/dujiao-next-YYYYMMDD-HHMMSS.tar
sha256sum -c SHA256SUMS
```

恢复图片：

```bash
tar -xzf uploads.tar.gz -C /opt/dujiao-next/data
```

查看并恢复配置：

```bash
mkdir -p /root/dujiao-config-review
tar -xzf config.tar.gz -C /root/dujiao-config-review
```

确认内容后，再把 `.env`、`config/config.yml` 和 Compose 文件复制回 `/opt/dujiao-next`。`app.secret_key` 必须与数据库配套恢复，否则数据库内的加密配置可能无法解密。

SQLite 数据库恢复：

```bash
cd /opt/dujiao-next
docker compose --env-file .env -f docker-compose.sqlite.yml stop dujiao-next
cp data/db/dujiao.db data/db/dujiao.db.before-restore
cp /root/dujiao-restore/database.sqlite data/db/dujiao.db
chmod 0666 data/db/dujiao.db
docker compose --env-file .env -f docker-compose.sqlite.yml up -d
```

PostgreSQL 数据库恢复：

```bash
cd /opt/dujiao-next
docker compose --env-file .env -f docker-compose.postgres.yml stop dujiao-next
docker exec -i dujiaonext-postgres sh -c \
  'pg_restore --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --clean --if-exists --no-owner' \
  < /root/dujiao-restore/database.dump
docker compose --env-file .env -f docker-compose.postgres.yml up -d
```

恢复后检查后台商品、订单、设置、图片和支付配置，并执行一次新的完整备份。

## 在线升级

管理菜单选择“检查并执行在线升级”，或运行：

```bash
dujiao-backup update
```

升级只替换主脚本，不覆盖配置、密钥、日志和备份。

## 日志与排错

日志：

```text
/opt/dujiao-backup/logs/dujiao-backup.log
```

日志达到 10 MiB 后会自动轮转，保留 `dujiao-backup.log.1` 到 `.5`，避免日志无限增长。

查看最近日志：

```bash
dujiao-backup logs
```

查看 systemd 执行状态：

```bash
systemctl status dujiao-backup.timer --no-pager
systemctl status dujiao-backup.service --no-pager
systemctl list-timers dujiao-backup.timer --no-pager
```

每次运行最后会出现：

- `[SUCCESS] 本次完整备份全部成功。`
- 或 `[ERROR] 失败原因：...`

## 支持范围

- Debian 11/12/13
- Ubuntu 22.04/24.04 等使用 `apt` 和 systemd 的发行版
- Bash 4.4+
- Dujiao-Next 官方 Docker Compose 方案 A/B
- CPU：`amd64` 或 `arm64`（OSS 模式）

脚本不会备份其他部署方式、外置 PostgreSQL、外置上传存储或自定义数据库拓扑。

## License

MIT
