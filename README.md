# Server Backup Manager

[![Release](https://img.shields.io/github/v/release/a06342637/ali-oss?display_name=tag&sort=semver)](https://github.com/a06342637/ali-oss/releases/latest)
[![Tests](https://github.com/a06342637/ali-oss/actions/workflows/test.yml/badge.svg)](https://github.com/a06342637/ali-oss/actions/workflows/test.yml)
[![License](https://img.shields.io/github/license/a06342637/ali-oss)](LICENSE)

> Dujiao-Next、Komari、自定义目录和 MySQL/MariaDB 的统一备份方案；支持本地归档、阿里云 OSS、SFTP/SSH 双远端、定时任务、完整性校验和备份历史。

面向 Debian / Ubuntu 服务器的专业交互式备份管理器。一个脚本统一管理数据源、本地归档、远端同步、保留策略、定时任务、完整性校验和执行历史。当前仍是“一个活动任务配置”，可随时在四种类型之间切换。

当前版本：`v1.3.0`

## 功能概览

### 备份任务类型

1. **发卡备份（Dujiao-Next）**
   - SQLite + Redis 官方 Compose 方案
   - PostgreSQL + Redis 官方 Compose 方案
   - 数据库、上传文件与关键配置完整归档
2. **探针备份（Komari）**
   - 自动识别 Docker 容器 `/app/data` 的宿主机挂载
   - SQLite Online Backup，一致处理 WAL 数据库
   - 完整归档主题和其他 data 文件
3. **自定义目录备份**
   - 自定义任务名称和任意绝对目录
   - 支持目录路径包含空格
   - 归档前检查真实路径、递归风险、可读性和文件类型
4. **MySQL / MariaDB 数据库备份**
   - 自动扫描本机客户端、安装包、systemd 服务和 Docker 数据库容器
   - 支持宿主机 TCP、Unix Socket、远程 MySQL、Docker 容器内本地连接
   - 支持指定数据库、全部业务数据库或全实例备份

### 存储目标

- 本地安全归档（始终生成）
- 阿里云 OSS
- SFTP / SSH
- OSS + SFTP 双远端
- 仅本地（不推荐作为唯一副本）

所有任务复用同一条可靠链路：

```text
检查数据源
  -> 创建一致性归档
  -> 生成 SHA256SUMS
  -> 校验本地包
  -> 上传 OSS/SFTP
  -> 核对远端大小与 SHA256
  -> 执行保留策略
  -> 写入结构化历史
```

> 为兼容旧安装，命令、安装目录和 systemd 单元仍使用 `dujiao-backup` 名称。升级不会覆盖配置、SSH 密钥、日志或已有归档。

## 一键安装

使用 `root` 登录服务器：

```bash
curl -fsSL https://raw.githubusercontent.com/a06342637/ali-oss/main/dujiao-backup.sh \
  -o /tmp/dujiao-backup.sh && \
bash /tmp/dujiao-backup.sh install
```

新安装向导会依次完成：

1. 选择 OSS、SFTP、双远端或仅本地
2. 配置并测试远端连接
3. 选择四种备份任务之一
4. 自动识别或交互配置数据源
5. 设置当前任务类型的保留数量
6. 配置 systemd 定时任务
7. 可选立即生成第一份备份

为避免误用参考值，重要配置项必须明确输入。密码输入不会回显。

## 管理菜单

安装后执行：

```bash
dujiao-backup
```

主菜单：

```text
  1) 立即执行当前备份任务
  2) 查看当前备份任务（数据源/目标/计划/最近结果）
  3) 统一配置中心（任务类型/目录/MySQL/OSS/SFTP/定时）
  4) 定时任务快捷管理
  5) 查看备份历史（执行记录 + 全部本地归档）
  6) 查看远端归档历史（OSS/SFTP）
  7) 校验备份包
  8) 测试远端连接
  9) 查看最近 100 行运行日志
 10) 检查并执行在线升级
 11) 显示宝塔计划任务命令
 12) 卸载管理器
  0) 退出
```

统一配置中心支持随时修改：

- 当前任务类型及其数据源
- 自定义目录任务名称和源目录
- MySQL 连接方式、容器、地址、端口、Socket、用户、密码和备份范围
- 保留数量
- OSS 全部参数和版本控制删除策略
- SFTP 主机、端口、用户、目录、主机指纹和专用密钥
- systemd 定时间隔

系统当前采用**单个当前任务**模型。切换任务类型不会删除原任务归档；保留策略只清理当前任务类型的标准文件名，历史页面会集中显示四种类型的所有归档。

## 自定义目录备份

在“统一配置中心 -> 管理备份任务类型和数据源”中选择：

```text
3) 自定义目录
```

需要输入：

- 任务名称，例如 `商城附件`
- 源目录绝对路径，例如 `/var/www/shop storage`

每份 `directory-YYYYMMDD-HHMMSS.tar` 包含：

```text
directory.tar.gz
manifest.txt
SHA256SUMS
```

`directory.tar.gz` 内是源目录中的完整相对目录树。`manifest.txt` 记录任务名称、原始目录、主机、时间、文件数量和源数据大小。

### 目录安全策略

脚本会拒绝：

- `/` 根目录
- 含 `..` 的非规范路径
- 备份输出目录及会包含输出目录的父目录，防止递归归档
- 源目录本身为符号链接
- 目录中的符号链接、设备文件、FIFO、Socket 等特殊文件
- 不可读文件

该策略让归档可以做严格的类型和路径校验。若业务目录确实依赖符号链接，应改为备份链接指向的真实数据目录。

目录备份属于文件级快照。高频写入应用应在备份窗口暂停写入，或先创建 LVM/ZFS/Btrfs/云盘快照，再将快照挂载目录配置为数据源。

### 恢复目录备份

```bash
mkdir -p /root/restore-directory
cd /root/restore-directory
tar -xf /opt/dujiao-backup/backups/directory-YYYYMMDD-HHMMSS.tar
tar -xzf directory.tar.gz
```

恢复前建议先运行：

```bash
dujiao-backup verify /opt/dujiao-backup/backups/directory-YYYYMMDD-HHMMSS.tar
```

## MySQL / MariaDB 备份

在任务类型中选择：

```text
4) MySQL 数据库
```

### 自动扫描

配置向导会显示：

- 宿主机上的 `mysql` / `mariadb` 查询客户端
- `mysqldump` / `mariadb-dump` 导出工具
- 已运行的 `mysql`、`mariadb`、`mysqld` systemd 服务
- 已安装的 MySQL、MariaDB、Percona 软件包
- 运行中的 MySQL、MariaDB、Percona Docker 容器

如果选择宿主机或远程连接但客户端缺失，向导可使用 `apt-get` 自动安装 `default-mysql-client`，并在必要时回退到 `mariadb-client`。

### 连接模式

1. **宿主机 TCP**
   - 本机监听地址
   - 远程 MySQL / MariaDB
2. **宿主机 Unix Socket**
   - 自动探测常见 Socket 路径
3. **Docker 容器内本地连接**
   - 自动识别常见数据库镜像
   - 在容器内通过本地 Socket 执行客户端

### 数据库范围

- **指定数据库**：英文逗号分隔，例如 `shop,analytics`
- **全部业务数据库**：运行时自动发现，并排除：
  - `information_schema`
  - `performance_schema`
  - `mysql`
  - `sys`
- **全实例**：包括 `mysql`/`sys` 与账户权限数据（虚拟库由服务端生成），需要较高权限

每份 `mysql-YYYYMMDD-HHMMSS.tar` 包含：

```text
database.sql.gz
manifest.txt
SHA256SUMS
```

导出默认使用：

```text
--single-transaction
--quick
--routines
--events
--triggers
--hex-blob
--default-character-set=utf8mb4
```

这会为 InnoDB 表创建不停机一致性逻辑备份，并包含存储过程、事件和触发器。MyISAM 等非事务表无法获得与 InnoDB 相同的事务快照保证；这类数据库建议在备份窗口锁定写入或使用物理快照方案。

### MySQL 权限建议

备份账号至少需要所选数据库的读取和视图权限，并按实际对象授予事件、触发器和存储过程相关权限。全实例备份还需要读取系统对象所需权限。

建议创建专用最小权限账号，不要长期使用业务应用账号。脚本不会把密码放入命令行；运行时使用权限为 `0600` 的临时 `defaults-extra-file`，Docker 模式通过标准输入送入容器内临时文件，退出即删除。

MySQL 密码保存在：

```text
/opt/dujiao-backup/config.conf
```

该文件会强制设置为 `root:root 0600`，菜单和日志只显示“已保存”，不会回显密码。

### 恢复 MySQL 备份

```bash
mkdir -p /root/restore-mysql
tar -xf /opt/dujiao-backup/backups/mysql-YYYYMMDD-HHMMSS.tar \
  -C /root/restore-mysql
gzip -cd /root/restore-mysql/database.sql.gz \
  | mysql --user=root --password
```

请先在隔离实例验证恢复，再用于生产环境。

## Dujiao-Next 发卡备份

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

SQLite 使用 Online Backup；PostgreSQL 使用 custom-format `pg_dump` 并通过 `pg_restore --list` 校验。Redis 仅作为缓存和队列，不包含在业务备份中。

## Komari 探针备份

脚本通过 Docker Inspect 查找容器 `/app/data` 的唯一宿主机 Mount Source，并在每次备份前复核挂载关系，避免容器重建后误备份旧目录。

每份 `komari-YYYYMMDD-HHMMSS.tar` 包含：

```text
data.tar.gz
manifest.txt
SHA256SUMS
```

对于 WAL 模式 SQLite，脚本会：

1. 复制除 `komari.db` 及 `-wal`、`-shm`、`-journal` 外的普通文件
2. 使用 SQLite Online Backup 生成一致的 `komari.db`
3. 执行 `PRAGMA quick_check`
4. 重新打包完整 `data/` 目录

## 阿里云 OSS

配置项：

- AccessKey ID / Secret
- Region ID，例如 `cn-hangzhou`
- Endpoint，例如 `oss-cn-hangzhou.aliyuncs.com`
- Bucket
- Bucket 内保存目录
- Bucket 是否开启版本控制
- 超出保留数时是否永久删除对象全部历史版本

上传后脚本会核对：

- OSS 对象大小
- `X-Oss-Meta-Dujiao-Sha256` 元数据

AccessKey 不会进入 systemd 单元或宝塔命令。建议使用最小权限 RAM 用户。

如果 Bucket 启用版本控制但未选择“永久删除全部历史版本”，请在 OSS 控制台配置历史版本和 DeleteMarker 生命周期规则。

## SFTP / SSH

配置项：

- 主机名或 IP
- SSH/SFTP 端口
- 用户名
- 首次授权密码
- 远端专用保存目录

脚本会生成专用 Ed25519 密钥。密码只用于首次安装公钥，不保存；首次连接需确认主机指纹，后续固定使用 `known_hosts`。

上传流程使用：

1. `.partial` 临时文件
2. 远端直接计算 SHA256
3. 与本地 SHA256 比较
4. 原子改名为最终归档名

## 备份历史与任务展示

### 当前任务

```bash
dujiao-backup status
```

按区域显示：

- 任务类型和源数据详细信息
- 归档文件规则
- 本地、OSS、SFTP 目标状态和路径
- 保留数量与定时状态
- 当前类型归档数量和最新归档
- 最近一次成功或失败结果

### 执行与归档历史

```bash
dujiao-backup history
```

历史分为两部分：

1. **结构化执行记录**：开始/完成时间、耗时、任务类型、任务名称、归档、大小、目标和失败阶段
2. **本地归档历史**：四种任务的归档按时间倒序显示，并标明 OSS/SFTP 校验标记状态

历史记录文件：

```text
/opt/dujiao-backup/state/backup-history.tsv
```

最多保留 2000 条，超过后压缩为最近 1000 条。升级前已有归档即使没有结构化执行记录，也会出现在归档历史中。

## 保留、补传与失败恢复

- 保留数量按**当前任务类型**独立应用
- 标准归档名才允许自动清理
- 先确认启用的远端已经完成校验，再删除最旧本地归档
- 远端缺少本地保留归档时，下次执行会自动补传
- 上传失败时保留本地归档和失败历史，不会误报成功
- 切换任务类型不会删除其他类型历史

## 定时任务

### systemd

菜单支持按“天 + 小时 + 分钟”设置间隔，最短 1 分钟。服务使用互斥锁，重复触发不会并发执行。

```bash
systemctl status dujiao-backup.timer
systemctl list-timers dujiao-backup.timer
```

### 宝塔计划任务

任务类型选择“Shell 脚本”，用户使用 `root`：

```bash
/usr/local/bin/dujiao-backup backup --scheduled
```

使用宝塔计划任务时，应停用内置 systemd 定时，防止重复触发。

## 常用命令

```bash
dujiao-backup                   # 管理菜单
dujiao-backup backup            # 执行当前任务
dujiao-backup status            # 当前任务详情
dujiao-backup history           # 执行记录和本地归档历史
dujiao-backup configure         # 统一配置中心
dujiao-backup test              # 测试已启用远端
dujiao-backup list-local        # 全部本地归档
dujiao-backup list-remote       # OSS/SFTP 远端归档
dujiao-backup verify            # 校验当前任务最新归档
dujiao-backup verify /path/a.tar
dujiao-backup logs
dujiao-backup update
dujiao-backup version
```

## 文件位置

```text
/opt/dujiao-backup/
├── dujiao-backup.sh
├── config.conf                 # root:root 0600
├── backups/
├── keys/
│   ├── sftp_ed25519
│   ├── sftp_ed25519.pub
│   └── known_hosts
├── logs/
│   └── dujiao-backup.log
├── state/
│   ├── backup-history.tsv
│   └── *.ok                    # 远端上传校验标记
└── tmp/
```

日志达到 10 MiB 自动轮转，保留 5 份历史日志。

## 安全设计

- 必须使用 root 运行
- 配置、日志、状态、密钥和本地归档默认权限 `0700/0600`
- 配置写入使用临时文件和原子替换
- AccessKey 和数据库密码不显示、不写命令行
- SFTP 密码不保存
- SSH 主机指纹固定
- 本地归档先写隐藏 `.partial`，校验后原子改名
- 外层和内层 TAR 都检查固定文件、成员类型、重复成员和路径穿越
- 所有归档包含 SHA256 清单
- OSS 和 SFTP 上传后都做远端校验
- `flock` 防止并发备份

## 升级兼容

```bash
dujiao-backup update
```

`v1.3.0` 保持 `CONFIG_VERSION=1`，旧配置可直接加载：

- 旧配置没有新增字段时自动使用安全默认值
- 原 `dujiao` / `komari` 任务不受影响
- 原归档名、OSS/SFTP 标记和保留策略继续兼容
- 进入配置中心后可切换到 `directory` 或 `mysql`

## 系统要求

- Debian / Ubuntu
- root
- Bash 4.4+
- `apt-get`
- Dujiao / Komari 类型需要 Docker
- MySQL 宿主机模式需要 `mysql`/`mariadb` 和 `mysqldump`/`mariadb-dump`；向导可自动安装
- OSS 模式支持 amd64 / arm64 的 `ossutil`

## 开发与测试

```bash
bash -n dujiao-backup.sh
shellcheck -S warning -x dujiao-backup.sh tests/*.sh
bash dujiao-backup.sh self-test
```

GitHub Actions 包含：

- Bash 与 ShellCheck 静态检查
- Debian bookworm / trixie 自检
- Dujiao SQLite / PostgreSQL 集成测试
- Komari WAL 一致性测试
- 自定义目录备份、恢复、保留与恶意链接拒绝测试
- MySQL/MariaDB TCP 与 Docker 模式备份、校验和真实恢复测试
- OSS 上传、补传、校验与保留测试
- SFTP 上传、补传、校验与保留测试

## License

[MIT](LICENSE)