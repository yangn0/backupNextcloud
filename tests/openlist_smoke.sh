#!/bin/bash
# Live test: create an isolated test directory, round-trip files, then remove it.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/../backupNextcloud.sh"
configure_openlist
TEST_DIR=$(mktemp -d /tmp/openlist-upload-check.XXXXXXXX)
TEST_REMOTE="$REMOTE_ROOT/.openlist-upload-check-$(date +%s)-$$"
TEST_CREATED=0
cleanup_test() {
  local rc=$?
  if [ "$TEST_CREATED" -eq 1 ]; then
    openlist purge "$TEST_REMOTE" || { log "测试目录清理失败: $TEST_REMOTE"; rc=1; }
  fi
  rm -rf -- "$TEST_DIR"
  return "$rc"
}
trap cleanup_test EXIT
mkdir -p "$TEST_DIR/source/data/空目录" "$TEST_DIR/source/config" "$TEST_DIR/source/db"
printf 'OpenList 上传验证\n' > "$TEST_DIR/source/data/中文 空格.txt"
printf 'test configuration\n' > "$TEST_DIR/source/config/test.txt"
printf 'test database\n' | gzip > "$TEST_DIR/source/db/test.sql.gz"
touch "$TEST_DIR/source/data/.ocdata"
TEST_CREATED=1
openlist mkdir "$TEST_REMOTE"
openlist copy "$TEST_DIR/source/" "$TEST_REMOTE" --transfers "$UPLOAD_CONCURRENCY" \
  --checkers "$UPLOAD_CONCURRENCY" --create-empty-src-dirs --log-level INFO
openlist check "$TEST_DIR/source/" "$TEST_REMOTE" --size-only
openlist copy "$TEST_REMOTE" "$TEST_DIR/download/" --create-empty-src-dirs
diff -r "$TEST_DIR/source/" "$TEST_DIR/download/"
# A changed file size must fail verification.
printf 'changed size\n' >> "$TEST_DIR/source/config/test.txt"
if openlist check "$TEST_DIR/source/" "$TEST_REMOTE" --size-only; then
  log "错误: 大小不匹配未被发现"
  exit 1
fi
log "OpenList 实际上传、下载内容比对和校验失败检测通过"
