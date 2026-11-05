# Nextcloud 备份

云端上传使用 **rclone → OpenList WebDAV → 阿里云盘备份盘**。
脚本先创建本地文件快照并导出数据库，再将生成的快照上传到 OpenList。
入口为 `backupNextcloud.sh`，运行期间无需调用旧的 aliyunpan 客户端。

日常检查、保留策略、恢复后的收尾、云端取回和故障排查见[运维手册](docs/operations.md)。

## 备份内容和流程

1. 检查 OpenList 登录和存储连通性。
2. 开启 Nextcloud 维护模式，用 `rsync` 对 `data/`、`config/` 创建本地快照，用 `mysqldump` 导出数据库。
3. 关闭维护模式，用 `rsync --link-dest` 将快照复制到第二块本地盘，复用该盘上一份副本。
4. 用 `rclone copy` 通过 OpenList 上传快照，再用 `rclone check` 核对云端路径和大小。
5. 校验通过后清理主盘和云端旧快照，归档日志。

每份快照结构如下，目录名中的数字为 Unix 时间戳：

```text
nextcloud-<timestamp>/
├── config/
├── data/
└── db/
    └── nextcloud-db.sql.gz
```

两块本地盘分别通过硬链接复用各自上一份快照中未变化的文件，盘间仍独立保存数据。
第二块盘先同步到临时目录，成功后发布新副本并保留最近两份。
上传仍遍历整个快照，
秒传由 OpenList 的阿里云盘驱动决定；文件内容会先发送给本机 OpenList。

不备份 `apps/`、`custom_apps/`，应用需另行安装；排除回收站、历史版本、
缩略图、`appdata_*/cache/` 和 `nextcloud.log*`。

## 运行环境和配置

需要 Bash 4+、rsync、Docker CLI、rclone、gzip，以及 GNU 常用命令。
自动测试另需 Python 3；主日志轮转使用 `/usr/sbin/logrotate`。
运行用户须能访问 Docker、本地备份目录及 OpenList 凭据文件。
Nextcloud 容器固定命名为 `nextcloud`，其中须能执行 `php occ`；
数据库容器须提供 `mysqldump`。

主机当前配置在脚本顶部维护：

| 配置 | 默认值或含义 |
| --- | --- |
| `NC_ROOT` | `/home/yangn0/disk6T/nextcloud` |
| `BACKUP_DIR` | `/home/yangn0/disk1T/nextcloudBackups` |
| `SECOND_BACKUP_DIR` | `/home/yangn0/disk500G/nextcloudBackups`；设为空可关闭第二份本地副本 |
| `KEEP_DISK500G` | 第二块本地盘保留最近 2 份已完成的副本 |
| `REMOTE_BASE` | 网盘内的 `/NASbackups/nextcloudBackups` |
| `UPLOAD_CONCURRENCY` | 默认 2，可用环境变量覆盖 |
| `CHECK_CONCURRENCY` | 目录读取和校验并发默认 2，可用环境变量覆盖 |
| `OPENLIST_TPSLIMIT` | 每个 rclone 进程每秒最多 4 个请求，突发为 1；可用环境变量覆盖 |
| `DB_CONTAINER` | 默认取 `config/config.php` 中的 `dbhost`；不等于容器名时需显式填写 |

数据库名、用户和密码在运行时从 `config/config.php` 读取，
支持单引号字面量配置。迁移主机时还应调整脚本中的日志路径及 `logrotate.conf`。

### OpenList 连接

当前阿里云盘备份盘挂载在 OpenList 的 `/opt/openlist/data`，这是虚拟挂载点。
因此网盘备份目录对应的 WebDAV 路径为
`/opt/openlist/data/NASbackups/nextcloudBackups`。
该挂载已开启秒传，WebDAV 下载策略为 `native_proxy`（本机中转）；
实测使用 302 跳转下载时会返回 403。

以下配置可通过环境变量覆盖，无需创建 rclone remote 配置文件：

| 环境变量 | 默认值 |
| --- | --- |
| `OPENLIST_URL` | `http://127.0.0.1:5244/dav/` |
| `OPENLIST_MOUNT_PATH` | `/opt/openlist/data` |
| `OPENLIST_CREDENTIALS` | `/home/yangn0/openlist/admin-credentials.txt` |
| `RCLONE` | `rclone` |

凭据文件格式如下，不要添加引号；文件权限应为 `600`：

```ini
username=你的OpenList用户名
password=你的OpenList密码
```

账户需要 WebDAV 读取、WebDAV 管理、创建目录或上传和删除权限。
修改 OpenList 用户名或密码后，需同步更新凭据文件。
OpenList 密码不会写入脚本、上传日志或 rclone 命令行。

只读检查连接及现有备份目录：

```bash
cd /home/yangn0/backup
bash -c 'source ./backupNextcloud.sh; configure_openlist; openlist lsf "$REMOTE_ROOT" --dirs-only --max-depth 1'
```

### 手动和定时执行

完整备份使用与定时任务相同的锁，避免同时运行：

```bash
/usr/bin/flock -n /tmp/backupNextcloud.lock \
  /bin/bash /home/yangn0/backup/backupNextcloud.sh \
  >> /home/yangn0/backup/backupNextcloud.log 2>&1
```

现有 crontab 每月 1 日 05:05 执行上述入口，时间由主机 cron 的时区决定：

```cron
5 5 1 * * /usr/bin/flock -n /tmp/backupNextcloud.lock /bin/bash /home/yangn0/backup/backupNextcloud.sh >> /home/yangn0/backup/backupNextcloud.log 2>&1
```

`INCLUDE_DATA=0` 可用于配置和数据库的试运行：

```bash
INCLUDE_DATA=0 /usr/bin/flock -n /tmp/backupNextcloud.lock \
  /bin/bash /home/yangn0/backup/backupNextcloud.sh
```

试运行会短暂开启维护模式并上传一份缺少 `data/` 的快照，
跳过第二份本地副本、旧快照清理及主日志轮转。
它使用相同的快照目录名格式，后续正常备份仍会将其纳入保留数量；
恢复时应确认所选快照包含 `data/`。

### 恢复中断的上传

上传中断后，可以复用已有完整本地快照继续上传并校验，避免重新生成快照：

```bash
/usr/bin/flock -n /tmp/backupNextcloud.lock \
  /bin/bash /home/yangn0/backup/backupNextcloud.sh --resume 1793805718 \
  >> /home/yangn0/backup/backupNextcloud.log 2>&1
```

将时间戳替换为需要恢复的快照。恢复入口要求快照包含 `data/`、`config/`
和有效的数据库 gzip 文件。此入口不重做本地备份、不切换维护模式，
成功后保留全部旧快照，不轮转主日志。
上传会跳过远端已有的相同文件；结束后仍对整个快照校验路径和大小。
限流或临时错误的整轮重试间隔为 30 秒。

**恢复上传及校验成功后，仍需完成[收尾检查](docs/operations.md#恢复后的收尾)。**
不要仅凭退出码为 0 判断旧快照清理和主日志轮转已完成。

## 验证

离线检查不访问生产 Nextcloud 或网盘：

```bash
bash -n backupNextcloud.sh tests/openlist_smoke.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
git diff --check
```

自动测试使用临时目录验证上传、校验、日志管道及连接失败时的保护行为，
以及云端清理的目录匹配和失败处理；这些测试模拟 Docker 和 WebDAV 操作。
恢复入口另检查已有快照复用、非法路径及损坏数据库压缩文件拒绝、
失败时不清理旧快照，以及不调用 Docker 或重建本地副本。
第二块盘的测试使用真实 rsync，检查硬链接 inode 复用、旧文件内容保留、
两份副本保留策略，以及部分同步失败时的旧副本保护。

`bash tests/openlist_smoke.sh` 会实际访问 OpenList，在备份目录下创建独立的
`.openlist-upload-check-*` 目录，检查中文文件名、零字节文件、空目录的往返，
确认文件大小变化会触发校验失败，并在退出时清理本次测试目录。
此检查无需操作 Nextcloud 或运行全量备份。

接口文档：[OpenList WebDAV](https://doc.oplist.org/guide/advanced/webdav)、
[rclone copy](https://rclone.org/commands/rclone_copy/)、
[rclone check](https://rclone.org/commands/rclone_check/)。
