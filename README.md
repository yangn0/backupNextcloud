# Nextcloud 备份

云端上传使用 **rclone → OpenList WebDAV → 阿里云盘备份盘**。
脚本先创建本地文件快照并导出数据库，再将生成的快照上传到 OpenList。
入口为 `backupNextcloud.sh`，运行期间无需调用旧的 aliyunpan 客户端。

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
| `UPLOAD_CONCURRENCY` | 10 |
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

## 保留策略和故障排查

| 位置 | 默认保留规则 |
| --- | --- |
| 主备份盘 disk1T | 上传并校验通过后保留最近 2 份 |
| 云端 | 上传并校验通过后保留最近 2 份；仅匹配 `nextcloud-<数字>/` 目录 |
| 第二备份盘 disk500G | 使用硬链接复用，同步成功后保留最近 2 份已完成的副本 |
| `backupNextcloud.log.1` | 最近 1 次轮转的主日志，不压缩 |
| `full/backup-<timestamp>.log.gz` | 最近 2 份详细上传日志 |

上传、逐文件校验或日志管道失败时非零退出，保留主盘和云端旧快照。
第二块本地盘同步失败时保留旧副本，并清理本次临时目录；副本完成标记为 `.backup-time`。
已有副本不会原地修改；删除旧副本只减少硬链接计数，不会删除新副本仍引用的数据。
硬链接节省未变化文件的空间，容量取决于保留快照中文件的并集及新副本创建期间的增量，
大量文件被替换或数据持续增长时仍可能空间不足；同步失败不会为腾空间提前删除旧副本。
脚本退出时会尝试关闭维护模式并压缩详细日志；被强制终止或主机断电时，
应检查 Nextcloud 维护模式是否仍开启。

主日志保留流程、错误和定期统计，逐文件成功输出写入 `full/`。
云端清理失败会记录警告，留待后续处理；当前 OpenList 存储将删除项移入回收站。

`rclone check --size-only` 检查文件是否存在、路径和大小是否一致，
不能检测大小相同的内容损坏。主机的 rclone 1.64.2 即使指定该选项也会输出
`No common hash found`；该提示本身不代表校验失败，以退出码及差异报告为准。

登录返回 401 时检查凭据；写入返回 403 时检查上述 WebDAV 权限。
下载返回 403 时检查挂载的 WebDAV 下载策略是否为 `native_proxy`。
失败可能留下不完整的 `nextcloud-<timestamp>` 目录，不能仅凭目录名判断备份完整性。

## 从云端取回快照

先用只读连接检查命令列出目录，选择一份已完成校验的完整快照。
以下命令只将快照下载到新的本地目录，请将示例中的 `nextcloud-<timestamp>`
替换为实际目录名：

```bash
cd /home/yangn0/backup
(
  source ./backupNextcloud.sh
  configure_openlist
  snapshot='nextcloud-<timestamp>'
  restore_dir=$(mktemp -d /tmp/nextcloud-restore.XXXXXXXX)
  openlist copy "$REMOTE_ROOT/$snapshot" "$restore_dir/$snapshot" --create-empty-src-dirs &&
    openlist check "$REMOTE_ROOT/$snapshot" "$restore_dir/$snapshot" --download &&
    printf '已取回并核对内容: %s\n' "$restore_dir/$snapshot"
)
```

下载位置需要足够空间，可将 `/tmp` 改为恢复盘上的目录。
恢复服务还需在维护模式下还原 `config/`、`data/`，导入对应数据库，
安装匹配的 Nextcloud 版本及应用，并核对数据目录的属主和权限。
WebDAV 副本不保留原始 POSIX 权限和硬链接关系，优先使用本地快照恢复这些元数据。

## 验证

离线检查不访问生产 Nextcloud 或网盘：

```bash
bash -n backupNextcloud.sh tests/openlist_smoke.sh
python3 -m unittest discover -s tests -v
git diff --check
```

自动测试使用临时目录验证上传、校验、日志管道及连接失败时的保护行为，
以及云端清理的目录匹配和失败处理；这些测试模拟 Docker 和 WebDAV 操作。
第二块盘的测试使用真实 rsync，检查硬链接 inode 复用、旧文件内容保留、
两份副本保留策略，以及部分同步失败时的旧副本保护。

`bash tests/openlist_smoke.sh` 会实际访问 OpenList，在备份目录下创建独立的
`.openlist-upload-check-*` 目录，检查中文文件名、零字节文件、空目录的往返，
确认文件大小变化会触发校验失败，并在退出时清理本次测试目录。
此检查无需操作 Nextcloud 或运行全量备份。

接口文档：[OpenList WebDAV](https://doc.oplist.org/guide/advanced/webdav)、
[rclone copy](https://rclone.org/commands/rclone_copy/)、
[rclone check](https://rclone.org/commands/rclone_check/)。
