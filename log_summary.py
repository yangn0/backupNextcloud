#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 backupNextcloud.sh 产生的超大日志压缩成人类可读的摘要。

背景：aliyunpan upload 会为每个文件打印 7 行进度（加入队列/计算SHA/秒传/结果），
10 万个文件就是 70 万行，把真正的问题（失败/错误）彻底淹没。
本脚本只保留脚本自身的进度行、问题行、失败文件清单和结尾统计。

用法：
    ./log_summary.py backupNextcloud.log.1 backupNextcloud.summary.txt
    ./log_summary.py backupNextcloud.log.1.gz        # 自动识别 .gz
"""

import gzip
import io
import os
import re
import sys
from collections import Counter
from datetime import datetime

# 脚本自身的进度行：[2026-10-01 05:05:01] xxx
RE_SCRIPT = re.compile(r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]')
# 时间戳：[2026-10-01 06:00:45] 或 [1234] 2026-10-01 06:00:45
RE_STAMP = re.compile(r'^\[\d+\]\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+')

# 上传工具对每个文件的逐条输出 —— 全部是噪音
NOISE_PATTERNS = [
    re.compile(r'^\s*(\[\d+\]\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+)?)?'
               r'(加入上传队列|准备上传|正在计算文件SHA|检测秒传中|秒传成功|'
               r'正在检测和创建云盘文件夹|文件上传结果： 成功)'),
    re.compile(r'^\s*正在检测和创建云盘文件夹'),
    # 结尾的文件清单：     83269  /home/yangn0/...
    re.compile(r'^\s*\d+\s+/home/'),
    re.compile(r'^\s*$'),
]

# 问题关键字（噪音行已先被剔除，所以不会误match文件名里的 error）
RE_PROBLEM = re.compile(r'失败|错误|警告|Error|error|failed|重试|retry', re.I)

RE_FAILED_HEADER = re.compile(r'^以下文件上传失败:\s*$')
RE_FAILED_ITEM = re.compile(r'^\s*\d+\s+(/\S.*?)\s*$')


def open_text(path):
    """打开日志；按需解 gzip。"""
    if path.endswith('.gz'):
        return io.TextIOWrapper(gzip.open(path, 'rb'), encoding='utf-8', errors='replace')
    return open(path, 'r', encoding='utf-8', errors='replace')


def is_noise(line):
    return any(p.match(line) for p in NOISE_PATTERNS)


def norm(line):
    """把一行归一化成"模式"，用于去重计数。"""
    s = RE_STAMP.sub('', line)            # 去掉 [1234] 时间戳
    s = RE_SCRIPT.sub('[时间] ', s)        # 脚本时间戳 → [时间]
    s = re.sub(r'\b[0-9A-Fa-f]{8,}\b', 'H', s)   # SHA/哈希 → H
    s = re.sub(r'\d+', 'N', s)             # 数字 → N
    s = s.strip()
    return s[:160]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src + '.summary.txt'

    if not os.path.exists(src):
        print(f'找不到文件: {src}', file=sys.stderr)
        return 1

    size = os.path.getsize(src)

    script_lines = []     # 脚本进度
    problems = []         # (行号, 原文)
    failed_files = []     # 上传失败的文件路径
    first_ts = last_ts = None
    total = 0
    noise_count = 0
    in_failed_block = False

    with open_text(src) as fh:
        for lineno, line in enumerate(fh, 1):
            total += 1
            line = line.rstrip('\n').rstrip('\r')
            if line.startswith('\x00') or len(line) > 4000:
                continue

            # 结尾的"以下文件上传失败:"清单
            if RE_FAILED_HEADER.match(line):
                in_failed_block = True
                continue
            if in_failed_block:
                m = RE_FAILED_ITEM.match(line)
                if m:
                    failed_files.append(m.group(1))
                    continue
                if line.strip():
                    in_failed_block = False   # 清单结束

            if RE_SCRIPT.match(line):
                m = RE_SCRIPT.match(line)
                ts = line[1:20]
                first_ts = first_ts or ts
                last_ts = ts
                script_lines.append((lineno, line))

            if is_noise(line):
                noise_count += 1
                continue

            if RE_PROBLEM.search(line):
                problems.append((lineno, line))

    # ---------- 问题去重 ----------
    counts = Counter(norm(l) for _, l in problems)
    first_lineno = {}
    for ln, l in problems:
        first_lineno.setdefault(norm(l), ln)

    bar = '=' * 72
    out = []
    w = out.append

    w(bar)
    w(' Nextcloud 备份日志摘要')
    w(bar)
    w(f' 源文件 : {os.path.abspath(src)}')
    w(f' 大小   : {size / 1024 / 1024:.1f} MB')
    w(f' 总行数 : {total:,}')
    if first_ts:
        w(f' 时间范围: {first_ts}  →  {last_ts}')
    w(f' 生成于 : {datetime.now():%Y-%m-%d %H:%M:%S}')
    w('')
    w(f' 原始日志 {total:,} 行中，{noise_count:,} 行（{noise_count * 100.0 / max(total, 1):.1f}%）')
    w(' 是上传工具对每个文件的逐条输出，已略去；下面只保留有价值的')
    w(' 脚本进度、问题记录、失败文件清单和结尾统计。')
    w('')

    # ---------- 1. 时间线 ----------
    w('#' * 72)
    w('# 1. 备份流程时间线（脚本自身输出）')
    w('#' * 72)
    if script_lines:
        for _, l in script_lines:
            w(l)
    else:
        w('（未找到脚本进度行）')
    w('')

    # ---------- 2. 问题统计 ----------
    w('#' * 72)
    w(f'# 2. 问题记录汇总（共 {len(problems):,} 行，去重后 {len(counts)} 类）')
    w('#' * 72)
    if counts:
        w(f'{"次数":>6}  {"首次行号":>10}  说明')
        w('-' * 72)
        for pat, c in counts.most_common():
            w(f'{c:>6}  {first_lineno.get(pat, 0):>10}  {pat}')
    else:
        w('本次备份没有失败或错误记录。')
    w('')

    # ---------- 3. 失败文件清单 ----------
    w('#' * 72)
    w(f'# 3. 上传失败的文件（共 {len(failed_files)} 个）')
    w('#' * 72)
    if failed_files:
        # 先按所属目录归类，避免一长串绝对路径难以扫读
        groups = Counter(os.path.dirname(p).rsplit('/data/', 1)[-1]
                         if '/data/' in p else os.path.dirname(p)
                         for p in failed_files)
        w('--- 按目录归类 ---')
        for g, c in groups.most_common():
            w(f'{c:>5}  {g}')
        w('')
        w('--- 完整清单 ---')
        root = os.path.commonpath(failed_files) if len(failed_files) > 1 else ''
        for p in failed_files:
            w(p)
    else:
        w('（无）')
    w('')

    # ---------- 4. 结尾统计 ----------
    w('#' * 72)
    w('# 4. 结尾统计')
    w('#' * 72)
    try:
        with open_text(src) as fh:
            tail = [l.rstrip('\n') for l in fh if RE_SCRIPT.match(l)]
        for l in tail[-8:]:
            w(l)
    except OSError:
        pass

    text = '\n'.join(out) + '\n'
    with open(dst, 'w', encoding='utf-8') as fh:
        fh.write(text)

    print(f'源日志 : {total:,} 行 / {size / 1024 / 1024:.1f} MB')
    print(f'摘要   : {text.count(chr(10)):,} 行 / {len(text.encode()) / 1024:.1f} KB  ->  {dst}')
    print(f'其中   : 流程 {len(script_lines)} 行，问题 {len(problems)} 行，失败文件 {len(failed_files)} 个')
    return 0


if __name__ == '__main__':
    sys.exit(main())
