"""为本地实验资料生成文件清单和报告导航，保留原始资料及其路径。"""

import argparse
import csv
from datetime import datetime, timezone
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def catalog(source: Path, output: Path):
    source = source.resolve(strict=True)
    output = output.resolve()
    if output == source or source not in output.parents:
        raise ValueError('索引输出必须位于资料目录内的独立子目录')
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    reports = {}
    for path in sorted(source.rglob('*')):
        if output in path.parents or path.is_symlink() or path.is_junction() or not path.is_file():
            continue
        if '__pycache__' in path.parts:
            continue
        relative = path.relative_to(source).as_posix()
        stat = path.stat()
        group = relative.split('/')[0] if '/' in relative else '(root)'
        rows.append((relative, group, path.suffix.lower(), stat.st_size,
                     datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()))
        if path.suffix.lower() == '.md':
            # 只建立文件导航；历史报告正文与结论保持原样。
            reports.setdefault(group, []).append(relative)
    with (output / 'files.csv').open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(('path', 'group', 'extension', 'bytes', 'modifiedUtc'))
        writer.writerows(rows)
    defaults_link = Path(os.path.relpath(ROOT / 'doc/development/build-defaults.md', output)).as_posix()
    lines = ['# 本地实验资料目录', '',
             f'文件 {len(rows)} 个，合计 {sum(row[3] for row in rows):,} 字节；Markdown {sum(map(len, reports.values()))} 份。', '',
             '完整文件元数据见 `files.csv`。历史报告中的默认值、构建命令和验收结论仅对应当时版本；当前采用项见 '
             f'[默认构建与策略](<{defaults_link}>)。', '',
             '| 分类 | 文件数 | 字节数 | Markdown |', '| --- | ---: | ---: | ---: |']
    for group in sorted({row[1] for row in rows}):
        selected = [row for row in rows if row[1] == group]
        lines.append(f'| `{group}` | {len(selected)} | {sum(row[3] for row in selected):,} | {len(reports.get(group, []))} |')
    for group, paths in sorted(reports.items()):
        lines.extend(('', f'## {group}', ''))
        for relative in paths:
            # 从输出目录计算相对链接，兼容自定义目录。
            target = Path(os.path.relpath(source / relative, output)).as_posix()
            lines.append(f'- [{relative}](<{target}>)')
    (output / 'README.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return len(rows), sum(map(len, reports.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'doc/dev')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or args.source / 'catalog'
    count, reports = catalog(args.source, output)
    print(f'{count} files, {reports} Markdown documents: {output}')


if __name__ == '__main__':
    main()
