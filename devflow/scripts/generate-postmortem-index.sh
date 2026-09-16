#!/usr/bin/env bash
# ============================================================
# generate-postmortem-index.sh 
# ------------------------------------------------------------
# 用途：扫描 docs/postmortems/*-pm.md，自动生成 INDEX.md
# 对应：P11 Postmortem 阶段
# 用法：
#   bash "$SKILL_ROOT/scripts/generate-postmortem-index.sh"                    # 输出到 docs/postmortems/INDEX.md
#   bash "$SKILL_ROOT/scripts/generate-postmortem-index.sh" /tmp/index.md      # 输出到指定文件
# ============================================================

set -e

POSTMORTEM_DIR="${POSTMORTEM_DIR:-docs/postmortems}"
OUTPUT_FILE="${1:-$POSTMORTEM_DIR/INDEX.md}"

if [ ! -d "$POSTMORTEM_DIR" ]; then
  echo "[WARN] 目录不存在：$POSTMORTEM_DIR"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

python3 - "$POSTMORTEM_DIR" "$OUTPUT_FILE" <<'PYEOF'
import os, sys, re, glob
from datetime import datetime

postmortem_dir = sys.argv[1]
output_file = sys.argv[2]

reports = []
for f in sorted(glob.glob(f'{postmortem_dir}/*-pm.md')):
    if os.path.basename(f) == 'INDEX.md':
        continue
    content = open(f, encoding='utf-8').read()
    fname = os.path.basename(f)
    # 文件名格式: YYYY-MM-DD-slug-pm.md
    m = re.match(r'(\d{4}-\d{2}-\d{2})-(.+)-pm\.md', fname)
    if not m:
        continue
    date, slug = m.group(1), m.group(2)
    # 解析级别（P0/P1/P2）
    level_m = re.search(r'严重等级[：:]\s*\*?\*?(P[012])', content)
    level = level_m.group(1) if level_m else '?'
    # 解析一句话总结
    sum_m = re.search(r'## §1\..*?\n\n(.*?)(?=\n## |\Z)', content, re.DOTALL)
    summary = sum_m.group(1).strip()[:80] if sum_m else '-'
    # 解析改进项数
    ai_count = len(re.findall(r'^\| \d+ \|', content, re.MULTILINE))
    # 解析责任人
    owner_m = re.search(r'主写人[：:]\s*@?(\S+)', content)
    owner = owner_m.group(1) if owner_m else '-'
    reports.append({
        'date': date,
        'slug': slug,
        'level': level,
        'summary': summary.replace('\n', ' ').replace('|', '\\|'),
        'actions': ai_count,
        'owner': owner,
        'link': fname,
    })

# 按日期降序
reports.sort(key=lambda x: x['date'], reverse=True)

lines = []
lines.append('# Postmortem 索引')
lines.append('')
lines.append(f'> 自动生成于 {datetime.now().strftime("%Y-%m-%d %H:%M:%S")} | 总计 {len(reports)} 篇')
lines.append('')

if not reports:
    lines.append('_暂无 Postmortem 报告。当发生 P0/P1 故障时运行 `/postmortem` 生成。_')
    lines.append('')
else:
    # 统计
    p0_count = sum(1 for r in reports if r['level'] == 'P0')
    p1_count = sum(1 for r in reports if r['level'] == 'P1')
    p2_count = sum(1 for r in reports if r['level'] == 'P2')
    lines.append('## 📊 统计')
    lines.append('')
    lines.append(f'- 总数：{len(reports)}')
    lines.append(f'- P0：{p0_count}')
    lines.append(f'- P1：{p1_count}')
    lines.append(f'- P2：{p2_count}')
    lines.append(f'- 累计改进项：{sum(r["actions"] for r in reports)}')
    lines.append('')
    lines.append('## 📋 列表')
    lines.append('')
    lines.append('| 日期 | 事故简称 | 等级 | 一句话总结 | 改进项 | 责任人 | 链接 |')
    lines.append('|------|---------|------|-----------|--------|--------|------|')
    for r in reports:
        lines.append(f'| {r["date"]} | {r["slug"]} | {r["level"]} | {r["summary"]} | {r["actions"]} | {r["owner"]} | [查看]({r["link"]}) |')
    lines.append('')
    lines.append('## 🔗 联动')
    lines.append('')
    lines.append('- 阶段定义：`commands/postmortem.md`')
    lines.append('- 命令入口：`commands/postmortem.md`')
    lines.append('- 重跑：`bash "$SKILL_ROOT/scripts/generate-postmortem-index.sh"`')

# v3.21.0(L-P2-001): 硬链接防护 + 原子写——硬链接别名共享 inode，in-place 覆写会经同一
# inode 双向破坏（事故：聚合投影覆写分文档详设）。nlink>1 拒绝写入（fail-closed）；
# 正常路径写 <path>.tmp 后 os.replace 原子落盘（替换目录项，天然斩断别名）。
def _atomic_write(path, content):
    if os.path.exists(path):
        _nlink = os.stat(path).st_nlink
        if _nlink > 1:
            print(f'[P0] 目标为硬链接（nlink={_nlink}），拒绝覆写: {path} —— 跨模板视图必须独立文件（L-P2-001），请先 unlink 或拆除别名', file=sys.stderr)
            sys.exit(1)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(content)
    os.replace(tmp, path)

_atomic_write(output_file, '\n'.join(lines))

print(f'[OK] 已生成 {output_file}（{len(reports)} 篇）')
PYEOF
