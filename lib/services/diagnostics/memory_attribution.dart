import 'dart:collection';

Map _map(Object? value) => value is Map ? value : const {};
num? _number(Object? value) => value is num && value.isFinite ? value : null;

class MemoryAttribution {
  static const intervalMs = 5000;
  static const _delays = [5000, 30000, 90000];
  final _active = <String, _PlaybackMemory>{};
  final _pending = Queue<_PlaybackMemory>();
  Map<String, Object?>? _previous;
  String? _route;
  int? _lastSnapshot;
  int _nextId = 0;
  int _omittedFollowUps = 0;
  num? _peakPrivate, _peakWc;

  List<Map<String, Object?>> observe(
    Map<String, Object?> sample, {
    bool force = false,
  }) {
    final tick = sample['elapsedMs'] as int;
    final point = _point(sample);
    final private = _number(point['privateBytes']);
    final wc = _number(point['wcBytes']);
    if (private != null && (_peakPrivate == null || private > _peakPrivate!)) {
      _peakPrivate = private;
    }
    if (wc != null && (_peakWc == null || wc > _peakWc!)) _peakWc = wc;
    final sources = _map(sample['sources']);
    final players = <String, Map>{};
    var omittedPlayers = 0;
    for (final name in _active.keys) {
      if (sources.containsKey(name)) players[name] = _map(sources[name]);
    }
    for (final entry in sources.entries) {
      if (entry.key is! String || !entry.key.startsWith('player.')) continue;
      if (players.containsKey(entry.key)) continue;
      if (players.length < 8) {
        players[entry.key as String] = _map(entry.value);
      } else {
        omittedPlayers++;
      }
    }
    final events = <Map<String, Object?>>[];
    for (final entry in _active.entries.toList()) {
      final player = players[entry.key];
      if (player?['available'] == false) continue;
      final runtime = _map(player?['session'])['runtimeId'];
      if (player != null && runtime == entry.value.runtime) continue;
      final observation = _active.remove(entry.key)!
        ..closedAt = tick
        ..interveningPlayback = players.keys.any((name) => name != entry.key);
      events.add(observation.event('playback.closed', point));
      if (_pending.length == 8) {
        _pending.removeFirst();
        _omittedFollowUps++;
      }
      _pending.add(observation);
    }
    for (final entry in players.entries) {
      var observation = _active[entry.key];
      if (entry.value['available'] == false && observation == null) continue;
      if (observation == null) {
        for (final pending in _pending) {
          pending.interveningPlayback = true;
        }
        observation = _PlaybackMemory(
          ++_nextId,
          _map(entry.value['session'])['runtimeId'],
          _previous,
        );
        _active[entry.key] = observation;
        events.add(observation.event('playback.observed', point));
      }
      observation.update(point);
      bool? fullscreen;
      for (final source in sources.entries) {
        if (source.key is! String || !source.key.startsWith('videoViewport.')) {
          continue;
        }
        final viewport = _map(source.value);
        if (viewport['player'] == entry.key && viewport['fullScreen'] is bool) {
          fullscreen = viewport['fullScreen'] as bool;
          break;
        }
      }
      if (fullscreen != null && fullscreen != observation.fullscreen) {
        if (fullscreen || observation.fullscreen != null) {
          events.add(
            observation.event(
              fullscreen ? 'fullscreen.entered' : 'fullscreen.exited',
              point,
            ),
          );
        }
        observation.fullscreen = fullscreen;
      }
    }
    for (final observation in _pending.toList()) {
      if (_active.isNotEmpty) observation.interveningPlayback = true;
      while (observation.followUp < _delays.length &&
          tick - observation.closedAt! >= _delays[observation.followUp]) {
        final delay = _delays[observation.followUp++];
        events.add(observation.event('afterClose.${delay ~/ 1000}s', point));
      }
      if (observation.followUp == _delays.length) _pending.remove(observation);
    }
    if (_route != sample['route']) {
      if (_route != null) {
        events.add({
          'kind': 'stage',
          'stage': 'route.changed',
          'from': _route,
          'to': sample['route'],
          'process': point,
        });
      }
      _route = sample['route'] as String?;
    }
    final due = _lastSnapshot == null || tick - _lastSnapshot! >= intervalMs;
    if (force || due || events.isNotEmpty) {
      _lastSnapshot = tick;
      events.insert(0, {
        'kind': 'snapshot',
        'process': point,
        'sessionPeakPrivateBytes': _peakPrivate,
        'sessionPeakWcBytes': _peakWc,
        'owners': _owners(sample),
        'activePlaybacks': _active.length,
        'omittedActivePlayers': omittedPlayers,
        'unavailablePlayerSources': players.values
            .where((value) => value['available'] == false)
            .length,
        'pendingFollowUps': _pending.length,
        'omittedFollowUps': _omittedFollowUps,
        'unobserved': const [
          'engine.swapchain',
          'engine.importedTextures',
          'decoder.allocations',
          'driver.allocations',
          'dart.heap',
        ],
      });
    }
    _previous = point;
    return events;
  }

  static Map<String, Object?> _point(Map<String, Object?> sample) {
    final process = _map(sample['process']);
    final memory = _map(sample['memory']);
    final totals = _map(memory['totals']);
    final valid = memory['complete'] == true && memory['status'] == 'sampled';
    return {
      'elapsedMs': sample['elapsedMs'],
      'time': sample['time'],
      'privateBytes': _number(process['privateBytes']),
      'rssBytes': _number(process['rssBytes']),
      'wcBytes': valid ? _number(totals['privateWriteCombineBytes']) : null,
      'rwBytes': valid ? _number(totals['privateReadWriteBytes']) : null,
      'pageStatus': memory['status'] ?? 'unavailable',
      'pageSampleId': memory['sampleId'],
      'pageCacheAgeMs': memory['cacheAgeMs'],
    };
  }

  static Map<String, Object?> _owners(Map<String, Object?> sample) {
    final images = _map(sample['images']);
    final handles = _map(sample['graphicsHandles']);
    final native = _map(sample['nativeMemory']);
    final graphics = _map(sample['graphicsMemory']);
    final contexts = _map(graphics['contexts']);
    return {
      'framework.imageCache': {
        'status': images.isEmpty ? 'unavailable' : 'observed',
        'nominalBytes': _number(images['cacheBytes']),
        'count': _number(images['cacheEntries']),
        'semantics': 'frameworkCache; overlapsImageHandlesAndNativeResources',
      },
      for (final kind in ['image', 'picture'])
        'framework.${kind}Handles': {
          'status': handles['running'] == true ? 'observed' : 'unavailable',
          for (final key in [
            'currentHandles',
            'currentBytes',
            'created',
            'explicitlyDisposed',
            'gcObserved',
          ])
            key: _number(_map(handles[kind])[key]),
          'semantics': 'createdWhileRecording; handlesNotUniqueAllocations; gcNotNativeRelease',
        },
      'plugin.video': {
        'status': native['status'] ?? 'unavailable',
        'ownerStatus': native['owners'] is List ? 'observed' : 'unsupported',
        'cacheAgeMs': native['cacheAgeMs'],
        'resources': native['resources'],
        'outputs': native['owners'],
        'omittedOwners': native['omittedOwners'],
        'releasingOutputs': native['releasingOutputs'],
        'pendingTextureUnregistrations':
            native['pendingTextureUnregistrations'],
        'semantics': 'pluginOwnedResources; nominalBytesNotDriverCommit; registrationsNotEngineImports',
      },
      for (final name in ['raster', 'io'])
        'engine.$name': {
          'status': _map(contexts[name])['available'] == true
              ? 'observed'
              : graphics['status'] ?? 'unavailable',
          'available': _map(contexts[name])['available'] == true,
          'cacheAgeMs': graphics['cacheAgeMs'],
          'schemaVersion': graphics['schemaVersion'],
          for (final key in [
            'resourceBytes',
            'budgetedResourceBytes',
            'budgetBytes',
            'purgeableBytes',
            'rasterCacheLayerBytes',
            'rasterCachePictureBytes',
          ])
            key: _number(_map(contexts[name])[key]),
          'semantics': 'engineReportedNominalBytes; contextsMayShareBacking; schema1ResourceBytesBudgetedOnly',
        },
    };
  }
}

class _PlaybackMemory {
  _PlaybackMemory(this.id, this.runtime, this.baseline);
  final int id;
  final Object? runtime;
  final Map<String, Object?>? baseline;
  num? peakPrivate;
  num? peakWc;
  bool? fullscreen;
  int? closedAt;
  int followUp = 0;
  bool interveningPlayback = false;

  void update(Map<String, Object?> point) {
    final private = _number(point['privateBytes']);
    final wc = _number(point['wcBytes']);
    if (private != null && (peakPrivate == null || private > peakPrivate!)) {
      peakPrivate = private;
    }
    if (wc != null && (peakWc == null || wc > peakWc!)) peakWc = wc;
  }

  Map<String, Object?> event(String stage, Map<String, Object?> point) {
    num? delta(String key) {
      final before = _number(baseline?[key]);
      final after = _number(point[key]);
      return before == null || after == null ? null : after - before;
    }

    return {
      'kind': 'stage',
      'stage': stage,
      'playbackId': id,
      'runtimeId': runtime,
      'baseline': baseline,
      'process': point,
      'privateDeltaBytes': delta('privateBytes'),
      'wcDeltaBytes': delta('wcBytes'),
      'peakPrivateBytes': peakPrivate,
      'peakWcBytes': peakWc,
      'closedAtElapsedMs': closedAt,
      'afterCloseElapsedMs': closedAt == null
          ? null
          : (point['elapsedMs'] as int) - closedAt!,
      'interveningPlayback': interveningPlayback,
      'semantics': 'processObservation; concurrentPlaybacksOverlap; residualIsNotProofOfLeak',
    };
  }
}

class MemoryAttributionReport {
  final _sessions = <(Object?, Object?, Object?, Object?), _MemorySession>{};
  int _omittedSessions = 0;

  void add(Map value) {
    if (value['type'] != 'memoryAttribution') return;
    final key = (
      value['runId'],
      value['processId'],
      value['session'],
      value['windowId'],
    );
    var session = _sessions[key];
    if (session == null) {
      if (_sessions.length == 32) {
        _omittedSessions++;
        return;
      }
      session = _MemorySession({
        'runId': value['runId'],
        'processId': value['processId'],
        'session': value['session'],
        'windowId': value['windowId'],
      });
      _sessions[key] = session;
    }
    session.add(value);
  }

  Map<String, Object?> toJson() => {
    'schema': 1,
    'status': _sessions.isEmpty ? 'notRecorded' : 'observed',
    'semantics': 'observedOwnershipAndProcessDeltas; byteCategoriesOverlap; notAnAllocatorOrLeakVerdict',
    'coverage':
        'retainedFilesOnly; sampledBoundaries; missingOrUnsupportedIsNotZero',
    'limits': {'sessions': 32, 'stagesPerSession': 64},
    'omittedSessionRecords': _omittedSessions,
    'sessions': [for (final session in _sessions.values) session.toJson()],
  };
}

class _MemorySession {
  _MemorySession(this.identity);
  final Map<String, Object?> identity;
  final _stages = <Map>[];
  final _seenStages = <(Object?, Object?)>{};
  Map? first, last;
  num? peakPrivate, peakWc;
  int snapshots = 0, omittedStages = 0;

  void add(Map value) {
    if (value['kind'] == 'stage') {
      final key = (value['elapsedMs'], value['sequence']);
      if (!_seenStages.add(key)) return;
      _stages.add(value);
      _stages.sort((before, after) {
        final tick = (_number(before['elapsedMs']) ?? 0).compareTo(
          _number(after['elapsedMs']) ?? 0,
        );
        return tick != 0
            ? tick
            : (_number(before['sequence']) ?? 0).compareTo(
                _number(after['sequence']) ?? 0,
              );
      });
      if (_stages.length > 64) {
        final old = _stages.removeAt(0);
        _seenStages.remove((old['elapsedMs'], old['sequence']));
        omittedStages++;
      }
    } else if (value['kind'] == 'snapshot') {
      snapshots++;
      final tick = _number(value['elapsedMs']) ?? 0;
      if (first == null || tick < (_number(first!['elapsedMs']) ?? 0)) {
        first = value;
      }
      if (last == null || tick > (_number(last!['elapsedMs']) ?? 0)) {
        last = value;
      }
      final point = _map(value['process']);
      final private =
          _number(value['sessionPeakPrivateBytes']) ??
          _number(point['privateBytes']);
      final wc =
          _number(value['sessionPeakWcBytes']) ?? _number(point['wcBytes']);
      if (private != null && (peakPrivate == null || private > peakPrivate!)) {
        peakPrivate = private;
      }
      if (wc != null && (peakWc == null || wc > peakWc!)) peakWc = wc;
    }
  }

  Map<String, Object?> toJson() => {
    ...identity,
    'snapshots': snapshots,
    'first': first,
    'last': last,
    'peakPrivateBytes': peakPrivate,
    'peakWcBytes': peakWc,
    'stages': _stages.toList(),
    'omittedStages': omittedStages,
  };
}
