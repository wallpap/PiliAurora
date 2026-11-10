import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/foundation.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';

/// 搜索资源属于页面；设备仅在两条投屏命令均确认后成为当前设备。
class DlnaController extends ChangeNotifier {
  DlnaController({
    DLNAManager? manager,
    this.searchDuration = const Duration(seconds: 20),
  }) : _manager = manager ?? DLNAManager();

  final DLNAManager _manager;
  final Duration searchDuration;
  final Map<String, DLNADevice> devices = {};
  final Set<DLNADevice> _ownedDevices = {};
  final Set<DLNADevice> _releasedDevices = {};
  DeviceManager? _deviceManager;
  bool searching = false;
  bool connecting = false;
  String? searchError;
  String? selectedKey;
  DLNADevice? _selected;
  bool _disposed = false;
  Object? _search;
  Timer? _timer;
  // 由 _closeSearchResources 统一取消，包括定时结束和 dispose。
  // ignore: cancel_subscriptions
  StreamSubscription<Map<String, DLNADevice>>? _subscription;
  Completer<void>? _searchDone;
  Future<void>? _stopping;

  Future<void> search() async {
    if (_disposed || searching) return;
    final operation = _search = Object();
    searching = true;
    searchError = null;
    devices.clear();
    notifyListeners();
    try {
      final manager = await _manager.start();
      _deviceManager = manager;
      if (_disposed || !identical(operation, _search)) {
        // start 内部有多次 await，dispose 的 stop 可能早于最后一次 socket 绑定。
        await _stopManager();
        return;
      }
      final done = _searchDone = Completer<void>();
      _subscription = manager.devices.stream.listen(
        (snapshot) {
          if (_disposed || !identical(operation, _search)) return;
          devices
            ..clear()
            ..addAll(snapshot);
          _ownedDevices.addAll(snapshot.values);
          notifyListeners();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!done.isCompleted) done.completeError(error, stackTrace);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      _timer = Timer(
        searchDuration,
        () => unawaited(_closeSearch()),
      );
      await done.future;
    } catch (error, stackTrace) {
      logger.w('搜索投屏设备失败', error: error.runtimeType, stackTrace: stackTrace);
      if (!_disposed && identical(operation, _search)) {
        searchError = '设备搜索失败，请检查局域网连接后重试';
      }
    } finally {
      await _closeSearch();
      if (identical(operation, _search)) {
        _search = null;
        searching = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> _stopManager() async {
    final devices = _deviceManager?.deviceList.values;
    if (devices != null) _ownedDevices.addAll(devices);
    try {
      // 当前版本为同步 stop；Future.sync 同时消费替代实现的异步失败。
      await Future<void>.sync(_manager.stop);
    } catch (error, stackTrace) {
      logger.w('停止投屏搜索失败', error: error.runtimeType, stackTrace: stackTrace);
      if (!_disposed) searchError = '设备搜索停止失败，请重试';
    } finally {
      if (_disposed) _disposeDevices();
    }
  }

  Future<void> _closeSearch() =>
      _stopping ??= _closeSearchResources().whenComplete(
        () => _stopping = null,
      );

  Future<void> _closeSearchResources() async {
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel();
    } catch (error, stackTrace) {
      logger.w('释放投屏搜索订阅失败', error: error.runtimeType, stackTrace: stackTrace);
    }
    final done = _searchDone;
    _searchDone = null;
    if (done != null && !done.isCompleted) done.complete();
    await _stopManager();
  }

  Future<LoadingState<void>> connect({
    required String key,
    required String url,
    String title = '',
    required bool Function() isCurrent,
  }) async {
    if (_disposed || !isCurrent()) return const Error('投屏页面已关闭');
    if (connecting) return const Error('正在连接设备，请稍候');
    if (key == selectedKey) return const Success(null);
    final device = devices[key];
    final uri = Uri.tryParse(url);
    if (device == null ||
        uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return const Error('投屏地址或设备无效，请重新打开投屏');
    }
    connecting = true;
    notifyListeners();
    bool current() => !_disposed && isCurrent();
    try {
      await device.setUrl(url, title: title);
      if (!current()) return const Error('投屏操作已取消');
      await device.play();
      if (!current()) return const Error('投屏操作已取消');
      final previous = _selected;
      _selected = device;
      selectedKey = key;
      notifyListeners();
      if (previous != null && !identical(previous, device)) {
        try {
          await previous.pause();
        } catch (error, stackTrace) {
          logger.w(
            '新设备已连接，暂停原设备失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
          return Error(
            '新设备已连接，请手动暂停原设备',
            cause: error,
            stackTrace: stackTrace,
          );
        }
      }
      return const Success(null);
    } catch (error, stackTrace) {
      logger.w('连接投屏设备失败', error: error.runtimeType, stackTrace: stackTrace);
      return Error('投屏未能确认，请检查设备后重试', cause: error, stackTrace: stackTrace);
    } finally {
      connecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_closeSearch());
    _disposeDevices();
    super.dispose();
  }

  void _disposeDevices() {
    for (final device in _ownedDevices) {
      if (!_releasedDevices.add(device)) continue;
      try {
        device.dispose();
      } catch (error, stackTrace) {
        logger.w('释放投屏设备失败', error: error.runtimeType, stackTrace: stackTrace);
      }
    }
    _ownedDevices.clear();
  }
}
