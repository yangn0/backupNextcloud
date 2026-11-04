#!/bin/bash
#
# Nextcloud 备份脚本（增量版）
# =====================================================================
# 相对旧版（整包 tar.gz 重传）的改进：
#   1. 按文件做 rsync 快照，并用硬链接复用上一份，本地几乎不额外占空间
#   2. 排除可再生的缓存、缩略图、回收站、版本历史、日志
#   3. 数据库用 mysqldump 单独导出（gzip 压缩）
#   4. 通过 OpenList WebDAV 上传；网盘秒传由 OpenList 存储驱动处理
#   5. 上传并发调低，降低峰值带宽，降低被运营商限速的风险
#   6. 新备份上传并校验成功后才清理主盘和云端旧备份
#   7. 上传的逐文件输出单独归档到 full/，主日志只留关键行
# =====================================================================

set -u
set -o pipefail

# ---------- 配置区（按需修改） ----------
NC_ROOT=/home/yangn0/disk6T/nextcloud           # Nextcloud 安装根目录
BACKUP_DIR=/home/yangn0/disk1T/nextcloudBackups # 本地备份目录
SECOND_BACKUP_DIR=/home/yangn0/disk500G/nextcloudBackups # 第二份本地备份目录（只保留最新 1 份；留空则关闭）
REMOTE_BASE=/NASbackups/nextcloudBackups        # 网盘中的备份目录（相对 OpenList 挂载点）
OPENLIST_URL=${OPENLIST_URL:-http://127.0.0.1:5244/dav/}
OPENLIST_MOUNT_PATH=${OPENLIST_MOUNT_PATH:-/opt/openlist/data} # 现有阿里云盘备份盘的挂载点
OPENLIST_CREDENTIALS=${OPENLIST_CREDENTIALS:-/home/yangn0/openlist/admin-credentials.txt}
RCLONE=${RCLONE:-rclone}                         # WebDAV 客户端
KEEP_DISK1T=2                                   # /home/yangn0/disk1T 保留的备份份数
KEEP_REMOTE=2                                   # 阿里云盘保留的备份份数
UPLOAD_CONCURRENCY=10                           # WebDAV 上传并发数（路由器统一限速）
DB_CONTAINER=                                   # 留空则自动取 config.php 中的 dbhost
INCLUDE_DATA=${INCLUDE_DATA:-1}                 # 1=备份 data；0=测试模式（跳过 data，且不清理旧备份）
KEEP_LOGS=1                                     # 备份日志保留次数（与 logrotate.conf 的 rotate 一致）
LOG_ROTATE_CONF=/home/yangn0/backup/logrotate.conf
LOG_STATE=/home/yangn0/backup/.logrotate.state
FULL_LOG_DIR=/home/yangn0/backup/full           # 上传逐文件详细日志目录（压缩归档）
KEEP_FULL_LOGS=2                                # 详细日志保留份数
FULL_LOG=""                                     # 本次运行的详细日志路径（运行时填充）

log()  { echo "[$(date '+%F %T')] $*"; }
fail() { log "错误: $*"; exit 1; }

# 使用现有 OpenList 凭据；密码只经 stdin 传给 obscure，不写入命令行或仓库。
configure_openlist() {
  command -v "$RCLONE" >/dev/null 2>&1 || fail "未找到 rclone，请先安装 WebDAV 客户端"
  [ -r "$OPENLIST_CREDENTIALS" ] || fail "无法读取 OpenList 凭据: $OPENLIST_CREDENTIALS"
  local line username="" password=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      username=*) username=${line#username=} ;;
      password=*) password=${line#password=} ;;
    esac
  done < "$OPENLIST_CREDENTIALS"
  [ -n "$username" ] && [ -n "$password" ] || fail "OpenList 凭据缺少 username 或 password"
  OPENLIST_USER=$username
  OPENLIST_PASS=$(printf '%s' "$password" | "$RCLONE" obscure -) || fail "处理 OpenList 凭据失败"
  REMOTE_ROOT="openlist:${OPENLIST_MOUNT_PATH%/}${REMOTE_BASE}"
}

# 独立 remote 配置，避免依赖运行用户的 rclone 配置文件（包括 cron）。
openlist() {
  RCLONE_CONFIG_OPENLIST_TYPE=webdav \
  RCLONE_CONFIG_OPENLIST_URL="$OPENLIST_URL" \
  RCLONE_CONFIG_OPENLIST_VENDOR=other \
  RCLONE_CONFIG_OPENLIST_USER="$OPENLIST_USER" \
  RCLONE_CONFIG_OPENLIST_PASS="$OPENLIST_PASS" \
    "$RCLONE" --config /dev/null --contimeout 30s --timeout 5m \
      --retries 3 --low-level-retries 10 "$@"
}

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
  local keep=$1 list name remove_count i
  local -a names=()
  if ! list=$(openlist lsf "$REMOTE_ROOT" --dirs-only --max-depth 1); then
    log "警告: 读取云端备份列表失败，跳过云端清理"
    return 1
  fi
  # 只接受完整的快照目录名，不从任意输出或文件名中提取子串。
  mapfile -t names < <(printf '%s\n' "$list" | sed -n 's/^\(nextcloud-[0-9][0-9]*\)\/$/\1/p' | sort -t- -k2 -n)
  remove_count=$((${#names[@]} - keep))
  for ((i=0; i<remove_count; i++)); do
    name=${names[i]}
    # 部分上传留下的较新目录不能挤掉本次已校验成功的快照。
    if [ "${name#nextcloud-}" -ge "$startTime_s" ]; then
      log "警告: 保留本次及更新的云端快照: $name"
      break
    fi
    if openlist purge "$REMOTE_ROOT/$name"; then
      log "已删除云端旧备份: $name"
    else
      log "警告: 云端删除 $name 失败，停止清理"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------
# 上传日志过滤
# rclone INFO 级别的逐文件成功记录只写进 FULL_LOG；
# 定期统计、所有错误及未知输出都保留在主日志中。
# ---------------------------------------------------------------------
UPLOAD_FILTER='
/ INFO[[:space:]]*: .*: Copied / {next}
/^[[:space:]]*$/ {next}
{print}
'

# 压缩本次上传详细日志，并只保留最近 KEEP_FULL_LOGS 份
rotate_full_logs() {
  [ -n "${FULL_LOG:-}" ] && [ "$FULL_LOG" != /dev/null ] || return 0
  if [ ! -f "$FULL_LOG" ]; then
    return 0
  fi
  if [ ! -s "$FULL_LOG" ]; then
    rm -f "$FULL_LOG"
    return 0
  fi
  if ! gzip -f "$FULL_LOG"; then
    log "警告: 压缩详细日志失败，保留原文件: $FULL_LOG"
    return 0
  fi
  log "上传详细日志已归档: $FULL_LOG.gz ($(du -h "$FULL_LOG.gz" | cut -f1))"
  local keep=${KEEP_FULL_LOGS:-2}
  ls -1t "$FULL_LOG_DIR"/backup-*.log.gz 2>/dev/null | tail -n +$((keep + 1)) | while read -r f; do
    rm -f "$f" && log "已删除旧详细日志: $f"
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

main() {
  # 在进入维护模式或写入本地快照前检查 OpenList 登录和存储连通性。
  configure_openlist
  openlist lsf "openlist:${OPENLIST_MOUNT_PATH%/}" --dirs-only --max-depth 1 >/dev/null \
    || fail "OpenList 存储不可访问，请检查服务、凭据和挂载点"

  startTime=$(date)
  startTime_s=$(date +%s)
  SNAP="$BACKUP_DIR/nextcloud-$startTime_s"
  REMOTE_SNAP="$REMOTE_ROOT/nextcloud-$startTime_s"

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
  # 退出时恢复维护模式；同时归档上传详细日志（中途 fail 退出时也要归档，避免留下上 GB 的裸日志）
  cleanup() {
    docker exec --user www-data -i nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true
    rotate_full_logs
  }
  trap cleanup EXIT
  log "维护模式已开启"

  # 3. 本地快照（排除可再生目录；未变化文件硬链接到上一份）
  EXCLUDES=(--exclude '*/files_trashbin/' --exclude '*/files_versions/' --exclude '*/preview/' --exclude 'appdata_*/cache/' --exclude 'nextcloud.log*')
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
  done

  # 4. 导出数据库（维护模式下进行，保证一致性）
  log "导出数据库: $SNAP/db/nextcloud-db.sql.gz"
  docker exec -i "$DB_CONTAINER" mysqldump --single-transaction --quick --triggers \
    -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip -1 > "$SNAP/db/nextcloud-db.sql.gz" || fail "数据库导出失败"
  log "数据库导出完成: $(ls -lh "$SNAP/db/nextcloud-db.sql.gz" | awk '{print $5}')"

  # 5. 关闭维护模式
  docker exec --user www-data -i nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || log "警告: 关闭维护模式失败"
  log "维护模式已关闭"

  # 5.5 第二份本地备份（disk500G，只保留最新一份；测试模式不做，避免动到真实旧备份）
  if [ "$INCLUDE_DATA" -eq 1 ]; then
    sync_second_copy
  fi

  # 6. 通过 OpenList 上传；秒传由存储驱动决定，WebDAV 本身仍会读取本地文件。
  openlist mkdir "$REMOTE_SNAP" || fail "创建云端目录 $REMOTE_SNAP 失败"
  log "开始通过 OpenList WebDAV 上传（并发 $UPLOAD_CONCURRENCY）..."
  if mkdir -p "$FULL_LOG_DIR" 2>/dev/null; then
    FULL_LOG="$FULL_LOG_DIR/backup-$startTime_s.log"
    log "逐文件详细输出: $FULL_LOG（备份结束后自动压缩归档）"
  else
    FULL_LOG=/dev/null
    log "警告: 无法创建 $FULL_LOG_DIR，本次不保留逐文件详细日志"
  fi

  # 完整输出写进 FULL_LOG，主日志只保留 UPLOAD_FILTER 过滤后的关键行
  openlist copy "$SNAP/" "$REMOTE_SNAP" \
    --transfers "$UPLOAD_CONCURRENCY" --checkers "$UPLOAD_CONCURRENCY" \
    --create-empty-src-dirs --log-level INFO --stats 1m --stats-one-line 2>&1 \
    | tee "$FULL_LOG" \
    | awk "$UPLOAD_FILTER"
  UPLOAD_STATUS=("${PIPESTATUS[@]}")
  for rc in "${UPLOAD_STATUS[@]}"; do
    [ "$rc" -eq 0 ] || fail "上传或日志处理失败（管道退出码: ${UPLOAD_STATUS[*]}），保留全部旧备份，详细输出: $FULL_LOG"
  done

  # 7. 逐文件校验路径和大小；通用 WebDAV 不提供可靠的云端哈希。
  log "校验云端所有文件的路径和大小 ..."
  openlist check "$SNAP/" "$REMOTE_SNAP" --size-only \
    --checkers "$UPLOAD_CONCURRENCY" 2>&1 | tee -a "$FULL_LOG"
  CHECK_STATUS=("${PIPESTATUS[@]}")
  for rc in "${CHECK_STATUS[@]}"; do
    [ "$rc" -eq 0 ] || fail "上传校验或日志处理失败（管道退出码: ${CHECK_STATUS[*]}），保留全部旧备份"
  done
  log "云端文件校验通过"

  # 8. 清理旧备份（仅在上传校验通过后执行）
  if [ "$INCLUDE_DATA" -eq 0 ]; then
    log "测试模式（本次未包含 data），跳过旧备份清理"
  else
    prune_local "$BACKUP_DIR" "$KEEP_DISK1T"
    prune_remote "$KEEP_REMOTE" || log "警告: 云端旧备份清理未完成"
    # 删除方式由 OpenList 存储配置决定，当前阿里云盘使用回收站。
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
