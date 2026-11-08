#!/usr/bin/env python3
"""顺序执行本地视频 × 解码路径矩阵，保留失败样本和汇总。"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, action='append', required=True)
    parser.add_argument('--decoder', action='append', help='可重复；默认 d3d11va、d3d11va-copy、no')
    parser.add_argument('--library-dir', type=Path, default=root / 'build/windows/x64/runner/Release')
    parser.add_argument('--frames', type=int, default=30)
    parser.add_argument('--sample-every', type=int, default=5)
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--output-dir', type=Path, default=root / 'build/windows-decode-matrix')
    args = parser.parse_args()
    if any(not video.is_file() for video in args.video):
        parser.error('All inputs must be existing local video files')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cases = []
    for video in args.video:
        for decoder in args.decoder or ('d3d11va', 'd3d11va-copy', 'no'):
            case_dir = args.output_dir / f'case-{len(cases):02d}'
            command = [sys.executable, str(Path(__file__).with_name('windows_video_sampling_probe.py')),
                       '--video', str(video.resolve()), '--decoder', decoder, '--library-dir', str(args.library_dir.resolve()),
                       '--frames', str(args.frames), '--sample-every', str(args.sample_every), '--output-dir', str(case_dir)]
            for key in ('width', 'height'):
                if getattr(args, key) is not None:
                    command.extend((f'--{key}', str(getattr(args, key))))
            case = {'video': video.name, 'decoder': decoder, 'passed': False}
            try:
                process = subprocess.run(command, capture_output=True, text=True, timeout=120)
                case['exitCode'] = process.returncode
                if process.stderr.strip():
                    case['stderr'] = process.stderr[-2000:]
                case['stdoutTail'] = process.stdout[-2000:]
                # 子进程只在最后一行输出摘要；完整采样明细由其 JSON 报告持有。
                summary = json.loads(process.stdout.splitlines()[-1])
                report = Path(summary['report'])
                detail = json.loads(report.read_text(encoding='utf-8'))
                case.update({'passed': process.returncode == 0 and detail['passed'], 'report': str(report),
                             'frames': detail['frames'], 'actualDecoders': detail['actualDecoders'],
                             'softwareFallback': detail['softwareFallback'], 'failures': detail['failures']})
                if detail['samples']:
                    samples = detail['samples']
                    finite_psnr = [s['psnrDb'] for s in samples if s['psnrDb'] is not None]
                    case.update({'sampleCount': len(samples), 'maxMae': max(s['mae'] for s in samples),
                                 'minPsnrDb': min(finite_psnr) if finite_psnr else None,
                                 'maxRowMae': max(s['maxRowMae'] for s in samples),
                                 'badRows': sorted({y for s in samples for y in s['rowsAboveMae12']})})
            except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
                case['failures'] = [str(error)]
            if 'report' in case:
                case.pop('stdoutTail', None)
            cases.append(case)
            print(json.dumps(case, ensure_ascii=False), flush=True)
    summary = {'passed': all(case['passed'] for case in cases), 'cases': cases,
               'scope': 'Local libmpv/ANGLE frame quality; excludes Flutter and final screen presentation'}
    (args.output_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
