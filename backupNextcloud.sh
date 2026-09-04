#!/bin/bash
#
# Nextcloud 备份脚本（增量版）
# =====================================================================
# 相对旧版（整包 tar.gz 重传）的改进：
#   1. 按文件做 rsync 快照，并用硬链接复用上一份，本地几乎不额外占空间
#   2. 排除可再生的缓存、缩略图、回收站、版本历史、日志
#   3. 数据库用 mysqldump 单独导出（gzip 压缩）
#   4. 上传走阿里云盘"秒传"：未变化文件不消耗带宽，只传实际变化的文件
#   5. 上传并发调低，降低峰值带宽，降低被运营商限速的风险
#   6. 新备份上传成功后才清理旧备份，失败时旧备份完整保留
# =====================================================================

set -u
set -o pipefail

# ---------- 配置区（按需修改） ----------
NC_ROOT=/home/yangn0/disk6T/nextcloud           # Nextcloud 安装根目录
BACKUP_DIR=/home/yangn0/disk1T/nextcloudBackups # 本地备份目录
SECOND_BACKUP_DIR=/home/yangn0/disk500G/nextcloudBackups # 第二份本地备份目录（只保留最新 1 份；留空则关闭）
REMOTE_BASE=/NASbackups/nextcloudBackups        # 阿里云盘备份目录
ALIYUNPAN_DIR=/home/yangn0/aliyunpan
ALIYUNPAN="$ALIYUNPAN_DIR/aliyunpan"
DRIVE_ID=99819931                               # 网盘 ID（备份盘）
KEEP_DISK1T=2                                   # /home/yangn0/disk1T 保留的备份份数
KEEP_REMOTE=2                                   # 阿里云盘保留的备份份数
UPLOAD_CONCURRENCY=10                           # 上传并发数（工具上限 20，路由器统一限速）
DB_CONTAINER=                                   # 留空则自动取 config.php 中的 dbhost
INCLUDE_DATA=${INCLUDE_DATA:-1}                 # 1=备份 data；0=测试模式（跳过 data，且不清理旧备份）
KEEP_LOGS=1                                     # 备份日志保留次数（与 logrotate.conf 的 rotate 一致）
LOG_ROTATE_CONF=/home/yangn0/backup/logrotate.conf
LOG_STATE=/home/yangn0/backup/.logrotate.state

log()  { echo "[$(date '+%F %T')] $*"; }
fail() { log "错误: $*"; exit 1; }

# 从 config.php 读取配置项（单引号字面量格式）
oc_cfg() {
  sed -n "s/.*'$1'[[:space:]]*=>[[:space:]]*'\([^']*\)'.*/\1/p" "$NC_ROOT/config/config.php" | head -1
}

# 删除本地旧备份，直到只剩 keep 份
prune_local() {
  local dir=$1 keep=$2
  while [ "$(ls -d "$dir"/nextcloud-* 2>/dev/null | wc -l)" -gt "$keep" ]; do
    oldest=$(ls -d "$dir"/nextcloud-* 2>/dev/null | sort -t- -k2 -n | head -1)
    [ -n "$oldest" ] || break
    rm -rf "$oldest"
    log "已删除本地旧备份: $oldest"
  done
}

# 删除云端旧备份，直到只剩 keep 份
prune_remote() {
  local keep=$1 list names count oldest
  list=$("$ALIYUNPAN" ls "$REMOTE_BASE" 2>&1) || true
  names=$(printf '%s\n' "$list" | grep -oE 'nextcloud-[0-9]+' | sort -u | sort -t- -k2 -n)
  count=$(printf '%s\n' "$names" | grep -c 'nextcloud-' || true)
  while [ "${count:-0}" -gt "$keep" ]; do
    oldest=$(printf '%s\n' "$names" | sort -t- -k2 -n | head -1)
    "$ALIYUNPAN" rm "$REMOTE_BASE/$oldest" >/dev/null 2>&1 || log "警告: 云端删除 $oldest 失败"
    log "已删除云端旧备份: $oldest"
    names=$(printf '%s\n' "$names" | grep -v "^$oldest$")
    count=$((count - 1))
  done
}

# 把最新快照完整复制到第二块本地盘（disk500G），并只保留最新 1 份
sync_second_copy() {
  [ -n "$SECOND_BACKUP_DIR" ] || return 0
  mkdir -p "$SECOND_BACKUP_DIR" || { log "警告: 无法创建 $SECOND_BACKUP_DIR，第二份本地备份跳过"; return 0; }
  # disk500G 只装得下一份，先删旧释放空间再同步；主备份在 disk1T，云端另有备份兜底
  prune_local "$SECOND_BACKUP_DIR" 0
  log "同步最新快照到 $SECOND_BACKUP_DIR/nextcloud-$startTime_s ..."
  if rsync -a --delete "$SNAP/" "$SECOND_BACKUP_DIR/nextcloud-$startTime_s/"; then
    printf '%s\n' "备份时间: $startTime" > "$SECOND_BACKUP_DIR/nextcloud-$startTime_s/.backup-time"
  else
    log "警告: 同步到 $SECOND_BACKUP_DIR 失败，本次没有第二份本地备份"
  fi
}

startTime=$(date)
startTime_s=$(date +%s)
SNAP="$BACKUP_DIR/nextcloud-$startTime_s"
REMOTE_SNAP="$REMOTE_BASE/nextcloud-$startTime_s"

log "===== Nextcloud 备份开始 $startTime ====="
log "本地快照: $SNAP"
log "云端快照: $REMOTE_SNAP"

# 先找上一份快照（用于硬链接复用），再创建新目录
PREV=$(ls -d "$BACKUP_DIR"/nextcloud-* 2>/dev/null | sort -t- -k2 -n | tail -1)
mkdir -p "$BACKUP_DIR" || fail "无法创建备份目录 $BACKUP_DIR"
mkdir -p "$SNAP/db" || fail "无法创建快照目录 $SNAP"

# 1. 读取数据库配置（密码来自 config.php，运行时读取，不写死在脚本里）
DB_HOST=$(oc_cfg dbhost)
DB_NAME=$(oc_cfg dbname)
DB_USER=$(oc_cfg dbuser)
DB_PASS=$(oc_cfg dbpassword)
[ -n "$DB_NAME" ] || fail "无法从 $NC_ROOT/config/config.php 读取数据库配置"
DB_CONTAINER=${DB_CONTAINER:-$DB_HOST}
log "数据库: $DB_CONTAINER / $DB_NAME"

# 2. 开启维护模式；脚本退出（无论成功失败）都会尝试关闭
docker exec --user www-data -i nextcloud php occ maintenance:mode --on >/dev/null 2>&1 || fail "开启维护模式失败"
trap 'docker exec --user www-data -i nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true' EXIT
log "维护模式已开启"

# 3. 本地快照（排除可再生日录；未变化文件硬链接到上一份）
EXCLUDES=(--exclude '*/files_trashbin/' --exclude '*/files_versions/' --exclude '*/preview/' --exclude 'appdata_*/cache/' --exclude 'nextcloud.log*')
SOURCES=()
# 只备份 data 和 config；apps/custom_apps 不备份（官方应用可从应用市场重新安装）
COMPS=(config)
[ "$INCLUDE_DATA" -eq 1 ] && COMPS=(data "${COMPS[@]}")
for comp in "${COMPS[@]}"; do
  [ -d "$NC_ROOT/$comp" ] || continue
  log "本地快照 $comp ..."
  if [ -n "$PREV" ] && [ -d "$PREV/$comp" ]; then
    rsync -aH --delete "${EXCLUDES[@]}" --link-dest="$PREV/$comp" "$NC_ROOT/$comp/" "$SNAP/$comp/" || fail "快照 $comp 失败"
  else
    rsync -aH --delete "${EXCLUDES[@]}" "$NC_ROOT/$comp/" "$SNAP/$comp/" || fail "快照 $comp 失败"
  fi
  SOURCES+=("$SNAP/$comp")
done

# 4. 导出数据库（维护模式下进行，保证一致性）
log "导出数据库: $SNAP/db/nextcloud-db.sql.gz"
docker exec -i "$DB_CONTAINER" mysqldump --single-transaction --quick --triggers \
  -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip -1 > "$SNAP/db/nextcloud-db.sql.gz" || fail "数据库导出失败"
log "数据库导出完成: $(ls -lh "$SNAP/db/nextcloud-db.sql.gz" | awk '{print $5}')"
SOURCES+=("$SNAP/db")

# 5. 关闭维护模式
docker exec --user www-data -i nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || log "警告: 关闭维护模式失败"
log "维护模式已关闭"

# 5.5 第二份本地备份（disk500G，只保留最新一份；测试模式不做，避免动到真实旧备份）
if [ "$INCLUDE_DATA" -eq 1 ]; then
  sync_second_copy
fi

# 6. 上传到阿里云盘（未变化文件走秒传，几乎不耗带宽）
cd "$ALIYUNPAN_DIR" || fail "无法进入 $ALIYUNPAN_DIR"
"$ALIYUNPAN" drive "$DRIVE_ID" >/dev/null 2>&1 || log "警告: 切换网盘失败"
"$ALIYUNPAN" mkdir "$REMOTE_BASE" >/dev/null 2>&1 || true
"$ALIYUNPAN" mkdir "$REMOTE_SNAP" >/dev/null 2>&1 || fail "创建云端目录 $REMOTE_SNAP 失败"
log "开始上传（并发 $UPLOAD_CONCURRENCY，首次会传全量，之后只传变化文件）..."
"$ALIYUNPAN" upload -p "$UPLOAD_CONCURRENCY" -np --timeout 60 --retry 3 "${SOURCES[@]}" "$REMOTE_SNAP" || fail "上传失败"

# 7. 校验云端目录结构（不通过则不清理旧备份）
UPLOAD_OK=1
REMOTE_LIST=$("$ALIYUNPAN" ls "$REMOTE_SNAP" 2>&1) || true
for src in "${SOURCES[@]}"; do
  sub=$(basename "$src")
  if ! printf '%s\n' "$REMOTE_LIST" | grep -qE "(^|[[:space:]])${sub}/"; then
    log "警告: 云端 $REMOTE_SNAP 下未找到 $sub"
    UPLOAD_OK=0
  fi
done

# 8. 清理旧备份（仅在上传校验通过后执行）
if [ "$INCLUDE_DATA" -eq 0 ]; then
  log "测试模式（本次未包含 data），跳过旧备份清理"
elif [ "$UPLOAD_OK" -eq 1 ]; then
  prune_local "$BACKUP_DIR" "$KEEP_DISK1T"
  prune_remote "$KEEP_REMOTE"
  # 注意: v0.4.0 已移除 recycle 命令；旧备份删除后进入网盘回收站，
  # 如需释放容量请在阿里云盘 App/网页手动清空回收站。
  # "$ALIYUNPAN" recycle d --all >/dev/null 2>&1 || true
else
  log "上传校验未通过，保留全部旧备份"
fi

endTime=$(date)
endTime_s=$(date +%s)
log "$startTime ---> $endTime Total:$((endTime_s - startTime_s)) seconds"
log "===== 备份结束 ====="

# 9. 日志轮转：真实备份结束后归档本次日志，只保留最近 KEEP_LOGS 次
if [ "$INCLUDE_DATA" -eq 1 ]; then
  if [ -x /usr/sbin/logrotate ]; then
    log "轮转备份日志（保留最近 $KEEP_LOGS 次）..."
    /usr/sbin/logrotate -s "$LOG_STATE" "$LOG_ROTATE_CONF" >/dev/null 2>&1 || log "警告: 日志轮转失败"
  else
    log "警告: 未找到 logrotate，日志不会自动轮转"
  fi
fi
