import 'dart:async';
import 'dart:collection';
import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';

/// 与媒体时间、墙钟无关的进程单调时间。
int liveDanmakuNowUs() => Timeline.now;

class LiveEmoteDescriptor {
  const LiveEmoteDescriptor(
    this.placeholder,
    this.url,
    this.width,
    this.height,
  );
  final String placeholder;
  final String url;
  final double width;
  final double height;
}

class LiveDanmakuMessage<T> {
  const LiveDanmakuMessage({
    required this.identity,
    required this.receivedAtUs,
    required this.text,
    this.color = const Color(0xffffffff),
    this.type = DanmakuItemType.scroll,
    this.selfSend = false,
    this.extra,
    this.emotes = const [],
  });
  final Object identity;
  final int receivedAtUs;
  final String text;
  final Color color;
  final DanmakuItemType type;
  final bool selfSend;
  final T? extra;
  final List<LiveEmoteDescriptor> emotes;
  int get descriptorBytes =>
      text.length * 2 +
      128 +
      emotes.fold(
        0,
        (sum, emote) =>
            sum + emote.url.length * 2 + emote.placeholder.length * 2 + 64,
      );
}

class _Candidate<T> {
  _Candidate(this.message);
  final LiveDanmakuMessage<T> message;
  bool started = false;
  bool done = false;
  bool ready = false;
  int resourceDeadline = 0;
  List<DanmakuInlineImage> images = [];
  void release() {
    for (final image in images) {
      image.image.dispose();
    }
    images = [];
  }
}

/// 候选与解码任务分开计账；过期任务实际完成前继续占槽。
class LiveDanmakuQueue<T> {
  static const maxCandidateImageBytes = 256 * 1024;
  // 候选已保留的图片与下一张解码结果可同时存活。
  static const taskReservationBytes = 2 * maxCandidateImageBytes;
  LiveDanmakuQueue({
    required this.loadImage,
    this.loadImageIfCurrent,
    required this.admit,
    required this.wake,
    this.nowUs = liveDanmakuNowUs,
    this.maxCandidates = 120,
    this.maxDescriptorBytes = 256 * 1024,
    this.maxAgeUs = 1000000,
    this.resourceWaitUs = 300000,
    this.maxTasks = 4,
    this.maxResourceBytes = 2 * 1024 * 1024,
    this.maxBatch = 24,
    this.maxWorkUs = 2000,
    this.canReserveBytes,
  });
  final Future<ui.Image?> Function(LiveEmoteDescriptor) loadImage;
  final Future<ui.Image?> Function(LiveEmoteDescriptor, bool Function())?
  loadImageIfCurrent;
  final bool Function(DanmakuContentItem<T>) admit;
  final void Function() wake;
  final int Function() nowUs;
  final int maxCandidates, maxDescriptorBytes, maxAgeUs, resourceWaitUs;
  final int maxTasks, maxResourceBytes, maxBatch, maxWorkUs;
  final bool Function(int bytes)? canReserveBytes;
  final _queue = Queue<_Candidate<T>>();
  final _identities = <Object>{};
  int _bytes = 0, _tasks = 0, _reserved = 0, _held = 0;
  bool _disposed = false;
  int get candidateCount => _queue.length;
  int get runningTasks => _tasks;
  int get reservedBytes => workingSetBytesExcluding(const []) - _bytes;
  int get workingSetBytes => _bytes + reservedBytes;
  int workingSetBytesExcluding(Iterable<ui.Image> sourceImages) {
    final images = sourceImages.toList();
    var bytes = _bytes + _reserved;
    for (final candidate in _queue) {
      for (final inline in candidate.images) {
        if (images.any((image) => image.isCloneOf(inline.image))) continue;
        images.add(inline.image);
        bytes += inline.image.width * inline.image.height * 4;
      }
    }
    return bytes;
  }

  bool get hasReady => _queue.any(
    (c) =>
        c.ready ||
        (!c.started &&
            (c.message.emotes.isEmpty ||
                _tasks < maxTasks &&
                    _reserved + _held + taskReservationBytes <=
                        maxResourceBytes &&
                    (canReserveBytes?.call(taskReservationBytes) ?? true))),
  );
  int? get nextDeadlineUs {
    int? result;
    for (final c in _queue) {
      var deadline = c.message.receivedAtUs + maxAgeUs;
      if (c.started && !c.ready && c.resourceDeadline < deadline) {
        deadline = c.resourceDeadline;
      }
      if (result == null || deadline < result) result = deadline;
    }
    return result;
  }

  void add(LiveDanmakuMessage<T> message) {
    if (_disposed) return;
    _expire();
    if (nowUs() >= message.receivedAtUs + maxAgeUs ||
        message.text.length > 1000 ||
        message.emotes.length > 16 ||
        message.descriptorBytes > maxDescriptorBytes ||
        !_identities.add(message.identity)) {
      return;
    }
    while (_identities.length > 512) {
      _identities.remove(_identities.first);
    }
    while (_queue.isNotEmpty &&
        (_queue.length >= maxCandidates ||
            _bytes + message.descriptorBytes > maxDescriptorBytes ||
            !(canReserveBytes?.call(message.descriptorBytes) ?? true))) {
      _remove(_queue.first);
    }
    if (!(canReserveBytes?.call(message.descriptorBytes) ?? true)) return;
    _queue.add(_Candidate(message));
    _bytes += message.descriptorBytes;
    wake();
  }

  void _remove(_Candidate<T> c) {
    if (!_queue.remove(c)) return;
    _bytes -= c.message.descriptorBytes;
    c.done = true;
    _held -= c.images.fold(
      0,
      (sum, image) => sum + image.image.width * image.image.height * 4,
    );
    c.release();
  }

  void _expire() {
    final now = nowUs();
    for (final c in _queue.toList()) {
      if (now >= c.message.receivedAtUs + maxAgeUs) {
        _remove(c);
      } else if (c.started && !c.ready && now >= c.resourceDeadline) {
        c.ready = true;
      }
    }
  }

  void process({required bool running, required double fontSize}) {
    if (_disposed) return;
    _expire();
    if (!running) return;
    final started = nowUs();
    var count = 0;
    for (final c in _queue.toList()) {
      if (nowUs() - started >= maxWorkUs) break;
      if (c.started && !c.ready) continue;
      if (!c.started &&
          c.message.emotes.isNotEmpty &&
          (_tasks >= maxTasks ||
              _reserved + _held + taskReservationBytes > maxResourceBytes ||
              !(canReserveBytes?.call(taskReservationBytes) ?? true))) {
        continue;
      }
      if (++count > maxBatch) break;
      if (!c.started && c.message.emotes.isNotEmpty) {
        c
          ..started = true
          ..resourceDeadline = nowUs() + resourceWaitUs;
        _tasks++;
        _reserved += taskReservationBytes;
        unawaited(_prepare(c, fontSize));
        continue;
      }
      if (c.started && !c.ready) continue;
      if (nowUs() >= c.message.receivedAtUs + maxAgeUs) {
        _remove(c);
        continue;
      }
      final m = c.message;
      final item = DanmakuContentItem<T>(
        m.text,
        color: m.color,
        type: m.type,
        selfSend: m.selfSend,
        extra: m.extra,
        inlineImages: c.images,
      );
      _held -= c.images.fold(
        0,
        (sum, image) => sum + image.image.width * image.image.height * 4,
      );
      c.images = [];
      _remove(c);
      if (!admit(item)) item.dispose();
    }
  }

  Future<void> _prepare(_Candidate<T> c, double fontSize) async {
    final images = <DanmakuInlineImage>[];
    var bytes = 0;
    try {
      for (final e in c.message.emotes) {
        if (c.done || c.ready || _disposed || nowUs() >= c.resourceDeadline) {
          break;
        }
        bool isCurrent() =>
            !c.done &&
            !c.ready &&
            !_disposed &&
            nowUs() < c.resourceDeadline &&
            nowUs() < c.message.receivedAtUs + maxAgeUs;
        final image =
            await (loadImageIfCurrent?.call(e, isCurrent) ?? loadImage(e));
        if (image == null) continue;
        final size = image.width * image.height * 4;
        if (c.done ||
            c.ready ||
            _disposed ||
            nowUs() >= c.resourceDeadline ||
            nowUs() >= c.message.receivedAtUs + maxAgeUs ||
            bytes + size > maxCandidateImageBytes) {
          image.dispose();
          break;
        }
        bytes += size;
        final w = e.width.isFinite && e.width > 0 ? e.width : fontSize;
        final h = e.height.isFinite && e.height > 0 ? e.height : fontSize;
        final scale = (fontSize * 1.5 / (w > h ? w : h)).clamp(0.0, 1.0);
        images.add(
          DanmakuInlineImage(
            placeholder: e.placeholder,
            image: image,
            width: w * scale,
            height: h * scale,
          ),
        );
      }
    } catch (_) {
      // 图片失败沿原候选期限降级。
    } finally {
      _tasks--;
      _reserved -= taskReservationBytes;
      if (!_disposed &&
          !c.done &&
          !c.ready &&
          nowUs() < c.resourceDeadline &&
          nowUs() < c.message.receivedAtUs + maxAgeUs) {
        c.images = images;
        _held += bytes;
        c.ready = true;
      } else {
        for (final image in images) {
          image.image.dispose();
        }
      }
      if (!_disposed) wake();
    }
  }

  void clear() {
    for (final c in _queue.toList()) {
      _remove(c);
    }
  }

  void dispose() {
    _disposed = true;
    clear();
    _identities.clear();
  }
}
