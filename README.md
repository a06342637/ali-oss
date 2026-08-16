# Dujiao-Next / Komari Backup Manager

面向 Debian/Ubuntu Docker 服务器的交互式完整备份管理器，同时支持：

- 发卡备份：Dujiao-Next 官方 Docker Compose 部署
- 探针备份：Komari 官方 Docker 部署
- 阿里云 OSS、SFTP/SSH、双远端或仅本地备份
- 本地及远端按数量保留、缺失备份自动补传
- systemd 间隔定时和宝塔计划任务
- 配置查看与修改、连接测试、日志、完整性校验、在线升级和安全卸载

当前版本：`v1.2.2`

> 为兼容已经安装的旧版本，命令和管理目录仍使用 `dujiao-backup` 名称。升级不会覆盖现有配置、密钥、日志或备份。

## 一键安装

使用 `root` 登录服务器后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/a06342637/ali-oss/main/dujiao-backup.sh \
  -o /tmp/dujiao-backup.sh && \
bash /tmp/dujiao-backup.sh install
```

新安装向导按以下顺序进行：

1. 选择阿里云 OSS、SFTP、双远端或仅本地备份
2. 完成对应 OSS/SFTP 参数和连接认证
3. 选择“发卡备份”或“探针备份”
4. 自动识别并确认对应 Docker 数据源
5. 设置备份保留数量
6. 设置 systemd 定时任务
7. 可选立即生成第一份备份

所有配置项、菜单选择和确认项都必须显式输入。直接回车、只输入空格或 Tab 都不会采用参考值，也不会进入下一步；脚本会原地提示并等待重新输入。参考值只用于帮助填写。仅“按回车继续”和“备份文件留空时校验最新一份”这类明确标注的非配置操作允许留空。

`v1.2.2` 统一了交互界面的输出通道，并会在备份子命令退出前等待日志完全刷新。安装、OSS/SFTP 配置、业务选择、保留数量、定时设置、立即备份和各级菜单都会按顺序同步显示，避免下载、连接或备份日志延迟插入下一条提示而造成标题缺失、选项错位、文字粘连或最后一行遗漏。

## 两种业务备份

### 发卡备份：Dujiao-Next

支持官方 Docker Compose：

- 方案 A：SQLite + Redis
- 方案 B：PostgreSQL + Redis

每份 `dujiao-next-YYYYMMDD-HHMMSS.tar` 包含：

```text
database.sqlite 或 database.dump
uploads.tar.gz
config.tar.gz
manifest.txt
SHA256SUMS
```

SQLite 使用在线一致性快照；PostgreSQL 使用 custom-format `pg_dump`。Redis 只作为缓存和队列，不包含在业务备份中。

### 探针备份：Komari

Komari 官方 Docker 文档把宿主机 `data` 文件夹挂载到容器 `/app/data`：

```yaml
volumes:
  - ./data:/app/data
```

参考：[Komari Docker 部署文档](https://komari-document.pages.dev/install/docker)

脚本不会猜测宿主机路径，而是通过 Docker Inspect 查找容器 `/app/data` 的真实 Mount Source，再要求人工确认。例如：

```text
宿主机 /komari/data  ->  容器 /app/data
```

配置保存后，每次备份都会再次核对挂载。如果容器名称或挂载路径发生变化，任务会停止并提示重新识别，防止备份错误目录。

Komari 默认数据库是 SQLite，运行时通常存在：

```text
komari.db
komari.db-wal
komari.db-shm
theme/
```

不能简单压缩一个正在写入的 WAL 数据库。脚本采用以下方式实现不停机一致性备份：

1. 复制 `data` 内除 SQLite 主库和运行时旁路文件之外的普通文件
2. 使用 SQLite Online Backup 创建一致的 `komari.db` 快照
3. 对快照执行 `PRAGMA quick_check`
4. 重新组成完整 `data` 文件夹并打包
5. 生成 SHA256 清单并再次校验

每份 `komari-YYYYMMDD-HHMMSS.tar` 包含：

```text
data.tar.gz
manifest.txt
SHA256SUMS
```

其中 `data.tar.gz` 内是可用于恢复的完整 `data/` 目录，包含一致的 `data/komari.db`，不包含运行时 `-wal`、`-shm` 或 `-journal` 文件。

## 阿里云 OSS

安装向导会询问：

- AccessKey ID
- AccessKey Secret
- Region ID，例如 `cn-hangzhou`
- Endpoint，例如 `oss-cn-hangzhou.aliyuncs.com`
- Bucket 名称
- Bucket 内保存目录，例如 `server-backups/node-01`
- Bucket 是否开启版本控制
- 是否永久删除超出保留数对象的全部历史版本

AccessKey 保存在 `/opt/dujiao-backup/config.conf`，权限固定为 `0600`，不会出现在 systemd 或宝塔命令中。建议使用最小权限的 RAM 用户，不要使用阿里云主账号 AccessKey。

如果 Bucket 开启版本控制，普通删除只会生成 DeleteMarker。若不选择永久删除全部历史版本，请在 OSS 控制台设置历史版本和过期删除标记的生命周期规则。

## SFTP/SSH

安装向导会询问：

- 远端 IP 或域名
- SSH/SFTP 端口
- SSH 用户名
- 首次登录密码
- 远端保存目录，例如 `/root/server-backups`

密码只用于首次下发专用 Ed25519 公钥，不写入配置、日志或计划任务。首次连接必须人工核对 SSH 主机指纹。

上传流程：

1. 上传为 `.partial` 临时文件
2. 在远端计算并比对 SHA256
3. 校验成功后原子改名为正式 `.tar`

因此未完成的上传不会被误认为有效备份。

## 管理菜单

运行：

```bash
dujiao-backup
```

主菜单提供：

1. 立即执行当前业务完整备份
2. 查看运行状态和当前发卡/探针数据源
3. 统一配置中心
4. 定时任务快捷管理
5. 查看本地备份
6. 查看远端备份
7. 校验备份包
8. 测试远端连接
9. 查看当前业务最近日志
10. 在线升级
11. 显示宝塔计划任务命令
12. 安全卸载

“统一配置中心”可以查看脱敏配置，并分别管理：

- 发卡备份 / 探针备份类型切换
- Dujiao 目录、数据库模式和 PostgreSQL 容器
- Komari 容器和 `/app/data` 实际挂载
- 本地与远端保留数量
- OSS 全部参数和版本控制策略
- SFTP 全部参数、主机指纹和密钥认证
- systemd 定时间隔与启停

切换业务类型不会删除原业务已有的本地或远端备份。当前保留策略只管理当前业务前缀，避免把另一类历史备份误删。

## 常用命令

```bash
dujiao-backup backup
dujiao-backup status
dujiao-backup configure
dujiao-backup test
dujiao-backup list-local
dujiao-backup list-remote
dujiao-backup verify
dujiao-backup verify /path/to/archive.tar
dujiao-backup logs
dujiao-backup baota
dujiao-backup update
dujiao-backup version
```

## 定时任务

内置定时使用 systemd，按“上一轮结束后再等待设定间隔”运行，避免任务堆积。

例如：

- `0天 0小时 2分钟`：每 2 分钟
- `0天 6小时 0分钟`：每 6 小时
- `1天 2小时 30分钟`：每 26 小时 30 分钟

宝塔中可新增“Shell 脚本”计划任务，执行用户为 root，内容为：

```bash
/usr/local/bin/dujiao-backup backup --scheduled
```

如果使用宝塔，请在管理菜单停用内置 systemd 定时，避免重复触发。

## 保留、同步与修复

假设最多保留 `100` 份：

- 新备份生成并成功同步到所有已启用目标后，才删除最旧备份
- 任一远端上传失败时不执行保留清理，优先避免数据丢失
- 下次运行会继续上传尚未同步的本地备份
- 远端缺少仍在本地保留的备份时，会自动补传
- 本地、OSS 和 SFTP 只清理当前业务类型的标准文件名
- OSS 会核对对象大小和 SHA256 元数据
- SFTP 会在远端直接计算 SHA256

## 完整性校验

校验最新一份当前业务备份：

```bash
dujiao-backup verify
```

也可以指定任意 Dujiao 或 Komari 标准备份文件：

```bash
dujiao-backup verify /opt/dujiao-backup/backups/komari-20260816-120000.tar
```

校验内容包括：

- 外层 TAR 固定结构和文件类型
- 路径穿越、符号链接、硬链接和特殊文件防护
- SHA256 清单
- 内层压缩包路径安全
- Dujiao SQLite `PRAGMA quick_check` 或 PostgreSQL dump 目录
- Komari `data/komari.db` 的 `PRAGMA quick_check`
- Komari 包中不存在运行时 WAL/SHM/journal 文件

## Komari 恢复提示

恢复会覆盖线上数据，请先在测试机演练，并保留当前数据目录副本。

先校验和解包：

```bash
dujiao-backup verify /path/to/komari-YYYYMMDD-HHMMSS.tar
mkdir -p /root/komari-restore
tar -xf /path/to/komari-YYYYMMDD-HHMMSS.tar -C /root/komari-restore
tar -xzf /root/komari-restore/data.tar.gz -C /root/komari-restore
```

确认 `/root/komari-restore/data/` 内容后，停止 Komari 容器，把当前宿主机数据目录改名保留，再将恢复出的 `data` 放回原 Mount Source，最后启动容器。实际宿主机目录请以 `dujiao-backup status` 显示为准，不要固定照抄 `/komari/data`。

## 管理器文件

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

快捷命令：`/usr/local/bin/dujiao-backup`

systemd 文件：

```text
/etc/systemd/system/dujiao-backup.service
/etc/systemd/system/dujiao-backup.timer
```

日志达到 10 MiB 后自动轮转，保留 `.1` 到 `.5`。

## 在线升级与兼容性

```bash
dujiao-backup update
```

升级只替换主脚本，不覆盖配置、密钥、日志和备份。

从 `v1.1.x` 升级时，旧配置没有 `BACKUP_TYPE` 字段，脚本会自动按 `dujiao`（发卡备份）加载；进入统一配置中心后即可切换为 Komari 探针备份。

支持范围：

- Debian 11/12/13
- Ubuntu 22.04/24.04 等使用 apt 和 systemd 的发行版
- Bash 4.4+
- CPU：amd64 或 arm64（OSS 模式）
- Dujiao-Next 官方 Docker Compose 方案 A/B
- Komari Docker 部署，`/app/data` 挂载到宿主机目录或 Docker volume

## License

MIT
