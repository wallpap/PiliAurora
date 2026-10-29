"""将生产弹幕更新、Flutter Raster 与同一次 EGL 实际呈现关联。"""

import argparse
import bisect
import importlib.util
import json
import re
from pathlib import Path


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ROOT = Path(__file__).resolve().parents[3]
egl = load_module('egl_frame_association', ROOT / 'tool/experiments/android/egl_frame_association.py')
continuity = load_module('presentation_continuity_analysis', ROOT / 'tool/experiments/danmaku/presentation_continuity_analysis.py')


def match_frames(stage, native):
    native = sorted(native, key=lambda frame: frame['start'])
    starts = [frame['start'] / 1000 for frame in native]
    timings = {row['frameNumber']: row for row in stage['timings']}
    matched, used = [], set()
    missing = dict(timing=0, swap=0, ambiguous=0, present=0, reused=0)
    for index, frame in enumerate(stage['frames']):
        timing = timings.get(frame['frameNumber'])
        if timing is None:
            missing['timing'] += 1
            continue
        left = bisect.bisect_left(starts, timing['rasterStartUs'] - 2)
        right = bisect.bisect_right(starts, timing['rasterFinishUs'] + 2)
        candidates = [n for n in native[left:right] if n['end'] / 1000 <= timing['rasterFinishUs'] + 2]
        if len(candidates) != 1:
            missing['ambiguous' if candidates else 'swap'] += 1
            continue
        event = candidates[0]
        if event['id'] in used:
            missing['reused'] += 1
            continue
        used.add(event['id'])
        if event['present'] <= 0:
            missing['present'] += 1
            continue
        matched.append({**frame, 'index': index, 'presentNs': event['present']})
    return matched, missing


def judge(stage, matched, analysis):
    seconds = (stage['endedUs'] - stage['startedUs']) / 1e6
    fps = (stage['after']['updates'] - stage['before']['updates']) / seconds
    expected = min(stage['target'] or stage['refreshHz'], stage['refreshHz'])
    frequency = expected > 0 and abs(fps - expected) / expected < .05
    coverage = len(matched) / max(1, len(stage['frames']))
    active = bool(stage['frames']) and all(frame['scrollCount'] > 0 for frame in stage['frames'])
    windows = analysis['summary']['centeredWindows']
    smooth = all(
        window['windows'] > 0 and window['velocityRms']['p95'] <= .1
        and window['withOutside10pct'] / window['windows'] < .01
        for window in windows.values()
    )
    return dict(fps=fps, expectedHz=expected, frequencyPassed=frequency,
                activePassed=active, matchedFraction=coverage, continuityPassed=smooth,
                passed=frequency and active and coverage >= .95 and smooth)


def analyze(directory):
    report = json.loads((directory / 'probe.json').read_text(encoding='utf-8'))
    lines = (directory / 'probe.log').read_text(encoding='utf-8', errors='replace').splitlines()
    native = egl.parse_engine_frames(
        line.split('): ', 1)[1] for line in lines
        if re.search(r'PILI_FRAME_PLAN\(\s*\d+\): (?:submit|present) ', line)
    )
    surface_path = directory / 'surface.json'
    surface = json.loads(surface_path.read_text(encoding='utf-8')) if surface_path.exists() else {}
    surface_presents = {row[1] for row in surface.get('surfaceFlinger', {}).get('rows', [])}
    stages = []
    for index, stage in enumerate(report['stages']):
        matched, missing = match_frames(stage, native)
        result = continuity.analyze(matched)
        verdict = judge(stage, matched, result)
        verdict.update(target=stage['target'], refreshHz=stage['refreshHz'], missing=missing,
                       targetGapUs=continuity.describe(b['targetUs'] - a['targetUs']
                           for a, b in zip(stage['frames'], stage['frames'][1:])),
                       rasterUs=continuity.describe(t['rasterUs'] for t in stage['timings']),
                       surfaceExactMatches=sum(f['presentNs'] in surface_presents for f in matched),
                       scheduler=stage['after'], continuity=result['summary'])
        (directory / f'presentation-stage-{index}.json').write_text(json.dumps(matched), encoding='utf-8')
        (directory / f'continuity-stage-{index}.json').write_text(json.dumps(result), encoding='utf-8')
        stages.append(verdict)
    lifecycle = report.get('lifecycle')
    lifecycle_ok = (all(lifecycle.get(key) is True for key in ('pause', 'resume', 'hide'))
                    if report['mode'] == 'live' and lifecycle else report['mode'] == 'point')
    summary = dict(mode=report['mode'], stages=stages, lifecycle=lifecycle,
                   surfaceFrames=len(surface_presents), error=report.get('error'),
                   passed=len(stages) == 5 and all(s['passed'] for s in stages)
                   and lifecycle_ok and bool(surface_presents) and report.get('error') is None)
    (directory / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    lines = ['# Android 弹幕帧率与呈现', '', f'判定：{"通过" if summary["passed"] else "未通过"}；模式：{report["mode"]}。', '',
             '| 目标 | 实际 FPS | 同帧关联 | 7 帧速度 RMS P95 | 超 10% 窗口 | 判定 |',
             '| --- | ---: | ---: | ---: | ---: | --- |']
    for stage in stages:
        window = stage['continuity']['centeredWindows']['3']
        rms = window.get('velocityRms', {}).get('p95')
        lines.append(f'| {stage["target"] or "跟随屏幕"} | {stage["fps"]:.2f} | '
                     f'{stage["matchedFraction"]:.2%} | {f"{rms:.2%}" if rms is not None else "缺失"} | '
                     f'{window["withOutside10pct"]}/{window["windows"]} | {"通过" if stage["passed"] else "未通过"} |')
    lines += ['', f'SurfaceFlinger 数值帧：{len(surface_presents)}；生命周期：{lifecycle}。', '',
              '各档检查实际频率误差 <5%、持续滚动、同帧关联率 ≥95%；3/5/7 帧完整窗口的速度 RMS P95 ≤10%，含超10%速度偏差的窗口比例 <1%。',
              '目标档位按屏幕上限计算；90 FPS 在120 Hz上允许1/2槽交替。缺帧不补点。视频关闭音频，点播使用生产异步媒体时钟采样。']
    (directory / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    result = analyze(parser.parse_args().directory)
    print(json.dumps({key: result[key] for key in ('mode', 'passed', 'surfaceFrames')}, ensure_ascii=False))
    raise SystemExit(0 if result['passed'] else 1)
