# 备份运维

运行入口、环境变量、定时任务和离线测试见 [README](../README.md)。
本手册的主机时间均为 Asia/Shanghai。

## 日常状态检查

先看当前主日志；正常备份收尾后它会被轮转为空，本次记录移到 `.1`：

```bash
cd /home/yangn0/backup
tail -n 30 backupNextcloud.log
tail -n 30 backupNextcloud.log.1
ls -lh full/
lslocks -o PID,COMMAND,PATH | rg backupNextcloud
```

云端列表可用 README 中的只读连接检查命令查看。
进程退出、传输进度 100% 或云端目录存在，都不能单独证明备份完成。
正常流程应有“云端文件校验通过”“备份结束”及日志轮转记录；
若出现清理失败警告，还需检查保留数量。
`--resume` 的成功记录只说明上传与校验完成，随后按下文收尾。

## 保留策略

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

## 校验范围

`rclone check --size-only` 检查文件是否存在、路径和大小是否一致，
不能检测大小相同的内容损坏。主机的 rclone 1.64.2 即使指定该选项也会输出
`No common hash found`；该提示本身不代表校验失败，以退出码及差异报告为准。

## 恢复后的收尾

`--resume <timestamp>` 复用本地快照上传，并校验整个快照；
详细上传日志会自动压缩。它不执行旧快照清理或主日志轮转。
确认上传和校验成功后，按以下顺序收尾：

1. 核对成功记录，以及需要保留的本次快照和上一份完整备份。
   试运行快照、上传中断目录和缺少 `.backup-time` 的第二块盘副本不能仅按名称计数。
2. 检查第二块盘副本；若缺少上一份完整备份，先从主盘补建副本，再清理中断目录。
   补建仍使用同盘硬链接复用、临时目录和完成后发布的流程。
3. 按保留策略清理主盘及云端旧快照，并重新列目录核对保留结果。
   执行维护操作时仍使用 `/tmp/backupNextcloud.lock`，避免与定时任务冲突。
4. 归档校验报告，写入结束记录及耗时，再执行主日志轮转：

   ```bash
   /usr/sbin/logrotate -s /home/yangn0/backup/.logrotate.state \
     /home/yangn0/backup/logrotate.conf
   ```

恢复过程中如分开执行上传、校验和收尾，分别记录完成时间。
耗时统计应注明是否包含失败尝试、重试，以及校验后等待收尾的空闲时间。

## 故障排查

登录返回 401 时检查凭据；写入返回 403 时检查上述 WebDAV 权限。
下载返回 403 时检查挂载的 WebDAV 下载策略是否为 `native_proxy`。
上传返回 405 时须同时查看 OpenList 服务日志；当前版本也会把阿里云盘
`TooManyRequests`、`InvalidRapidProof` 等底层错误返回为 405。
前者应降低并发和请求频率；后者可临时关闭挂载的秒传，仅补传失败文件，
再恢复秒传并校验补传文件内容。
若目录读取持续返回 500，且 OpenList 日志出现 `database is locked` 或
`cannot start a transaction within a transaction`，应先停止上传、停止 OpenList，
备份 `data.db` 及其 journal/WAL 文件，再检查 SQLite 完整性。
不要在服务运行时删除 journal、WAL 文件。
失败可能留下不完整的 `nextcloud-<timestamp>` 目录，不能仅凭目录名判断备份完整性。

## 2026-11-05 故障与恢复记录

本次快照为 `nextcloud-1793805718`，前一次中断尝试为 `nextcloud-1793804471`。

| 现象 | 日志证据和处理 |
| --- | --- |
| 上传返回 405 | 两次 `TooManyRequests`，另两次 `InvalidRapidProof`；临时关闭秒传后实际补传 1 个文件，其余 3 个已在此前重试中成功，随后恢复秒传。4 个文件的大小及本地 SHA-1 与云端内容哈希均一致。 |
| 目录读取持续 500 | 06:15:04–05 出现 10 次令牌刷新记录，06:15:09 开始保存存储配置时 `SQLITE_BUSY`，06:34:51 起出现嵌套事务错误。并发刷新令牌并写入 SQLite 是可能的触发条件，异常事务状态的具体形成过程尚未定位。 |
| SQLite 实际未启用 WAL | 停止上传和 OpenList 后备份数据库及 journal，完整性检查为 `ok`，实测原模式为 `delete`。显式设置 WAL 并重启后目录读取恢复。默认上传/检查并发改为 2、每秒请求上限为 4，整轮重试间隔 30 秒。 |

该版本初始化使用 `_journal=WAL`，默认 Go SQLite 驱动文档使用
`_pragma=journal_mode(WAL)`；参数不匹配可能导致预期的 WAL 设置未生效。
这属于源码与现场状态支持的判断，尚未证明它是全部异常的唯一原因。
启用 WAL 和降低并发属于缓解措施，上游事务异常处理尚未修改。

- 上传及全量路径、大小校验于 **14:33:28** 完成：101,661 个文件匹配，差异和读取错误均为 0。
- 从 11 月 4 日 23:01:11 的前一次尝试开始，至校验完成累计 **15 小时 32 分 17 秒**，包含报错和排障。
- 收尾于 **21:49:10** 完成；校验后的等待时间单列。三处均保留 `nextcloud-1793480701` 和 `nextcloud-1793805718`。
- 第二块盘已补建 11 月 1 日完整副本，中断副本和 10 月旧快照已清理；主日志已轮转，校验日志及报告已压缩。

现场证据保存在本机 `full/`，不纳入 Git：

| 文件 | 内容 |
| --- | --- |
| `verify-1793805718.status.json` | 校验和收尾退出码、完成时间、保留快照 |
| `verify-1793805718.combined.txt.gz` | 全量逐文件校验报告 |
| `verify-1793805718.log.gz` | 校验汇总 |
| `recovery-files-1793805718.log.gz` | 4 个曾失败文件的补传及哈希核对记录 |
| `finalize-1793805718.log` | 副本补建、清理和归档记录 |

OpenList 停机数据库备份及恢复说明位于本机
`/home/yangn0/openlist/recovery-20261105-130746/`，目录权限为 `700`。
一次性修复/校验/收尾脚本、失败文件清单、空差异报告和已结束的临时服务已清理。

源码参考：[令牌刷新与保存](https://github.com/OpenListTeam/OpenList/blob/v4.2.9/drivers/aliyundrive_open/util.go#L113-L132)、
[SQLite 初始化](https://github.com/OpenListTeam/OpenList/blob/v4.2.9/internal/bootstrap/db.go#L44-L52)、
[驱动 PRAGMA 参数](https://github.com/glebarez/go-sqlite#settings-pragmas-in-connection-string)。

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

