import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:catcher_2/model/report.dart';
import 'package:catcher_2/model/report_handler.dart';
import 'package:catcher_2/utils/log_printer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Catcher2 {
  Catcher2(
    this.handlers,
    this._rootWidget, {
    Logger? logger,
    this.handlerTimeout = const Duration(seconds: 5),
    this.customParameters = const {},
    this.handleSilentError = true,
    this.excludedParameters = const [],
    this.filterFunction,
    this.reportOccurrenceTimeout = const Duration(seconds: 3),
  }) {
    assert(instance == null);
    Catcher2.logger = logger ??
        Logger(filter: ProductionFilter(), printer: PrettyLogPrinter());
    Catcher2.instance = this;

    _configure();
  }

  /// Root widget that is run using [runApp].
  final Widget _rootWidget;

  /// Handlers that should be used
  final List<ReportHandler> handlers;

  /// Timeout for handlers which uses long-running action. In milliseconds.
  final Duration handlerTimeout;

  /// Custom parameters which will be used in report handler
  final Map<String, Object> customParameters;

  /// Should catcher 2 handle silent errors
  final bool handleSilentError;

  /// Parameters which will be excluded from report
  final List<String> excludedParameters;

  /// Function which is used to filter reports. If [filterFunction] is empty
  /// then all reports will be passed to handlers.
  /// To mark given Report as valid, [filterFunction] should return true,
  /// otherwise return false.
  final bool Function(Report report)? filterFunction;

  /// Timeout for reports to prevent handling duplicates of same error. In
  /// milliseconds.
  final Duration reportOccurrenceTimeout;

  final Map<String, dynamic> deviceParameters = {};
  final Map<String, dynamic> applicationParameters = {
    'environment': kReleaseMode
        ? 'Release'
        : kProfileMode
            ? 'Profile'
            : 'Debug',
    'abi': Abi.current().toString(),
  };

  final Map<String, DateTime> _reportsOccurrenceMap = {};

  static Catcher2? instance;
  static late final Logger logger;

  void _configure() {
    _loadDeviceInfo();
    _loadApplicationInfo();

    _setupErrorHooks();

    runApp(_rootWidget);

    if (handlers.isEmpty) {
      assert(false);
      logger.w(
        'Handlers list is empty. Configure at least one handler to '
        'process error reports.',
      );
    } else {
      logger.d('Catcher 2 configured successfully.');
    }
  }

  void _flutterHandler(FlutterErrorDetails details) =>
      _reportError(details.exception, details.stack, errorDetails: details);

  bool _platformHandler(Object error, StackTrace stackTrace) {
    _reportError(error, stackTrace);
    return true;
  }

  void _isolateHandler(Object pair) => _reportError(
        (pair as List<dynamic>).first.toString(),
        pair.last.toString(),
      );

  void _setupErrorHooks() {
    // FlutterError.onError catches SYNCHRONOUS errors for all platforms
    FlutterError.onError = _flutterHandler;

    // PlatformDispatcher.instance.onError catches ASYNCHRONOUS errors, but it
    // currently does not work for Web, most likely due to this issue:
    // https://github.com/flutter/flutter/issues/100277
    PlatformDispatcher.instance.onError = _platformHandler;

    // Web doesn't have Isolate error listener support
    Isolate.current.addErrorListener(
      RawReceivePort(_isolateHandler, kDebugMode ? 'Catcher2' : '').sendPort,
    );
  }

  static void reportCheckedError(Object error, StackTrace? stackTrace) =>
      instance?._reportError(error, stackTrace);

  void _reportError(
    Object error,
    Object? stackTrace, {
    FlutterErrorDetails? errorDetails,
  }) {
    if ((errorDetails?.silent ?? false) && !handleSilentError) {
      logger.d(
        'Report error skipped. HandleSilentError is false.',
        error: error,
      );
      return;
    }

    final now = DateTime.now();

    _cleanPastReportsOccurrences(now);

    final report = Report(
      error,
      stackTrace,
      now,
      deviceParameters,
      applicationParameters,
      customParameters,
      errorDetails,
    );

    if (_isReportInReportsOccurrencesMap(report)) {
      logger.d(
        "Error: '$error' has been skipped to due to duplication occurrence "
        'within $reportOccurrenceTimeout ms.',
      );
      return;
    }

    if (filterFunction?.call(report) ?? false) {
      logger.d(
        "Error: '$error' has been filtered from Catcher 2 logs. "
        'Report will be skipped.',
      );
      return;
    }

    _addReportInReportsOccurrencesMap(report, now);

    onActionConfirmed(report);
  }

  /// Clean report occurrences from the past.
  void _cleanPastReportsOccurrences(DateTime now) {
    final timeout = reportOccurrenceTimeout;
    _reportsOccurrenceMap.removeWhere(
      (_, value) => now.isAfter(value.add(timeout)),
    );
  }

  bool _isReportInReportsOccurrencesMap(Report report) {
    return _reportsOccurrenceMap.containsKey(report.error.toString());
  }

  /// Add report in reports occurrences map. Report will be added only when
  /// error is not null and report occurrence timeout is greater than 0.
  void _addReportInReportsOccurrencesMap(Report report, DateTime now) {
    if (reportOccurrenceTimeout > Duration.zero) {
      _reportsOccurrenceMap[report.error.toString()] = now;
    }
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isLinux) {
        _loadLinuxParameters(await deviceInfo.linuxInfo);
      } else if (Platform.isWindows) {
        _loadWindowsParameters(await deviceInfo.windowsInfo);
      } else if (Platform.isMacOS) {
        _loadMacOSParameters(await deviceInfo.macOsInfo);
      } else if (Platform.isAndroid) {
        _loadAndroidParameters(await deviceInfo.androidInfo);
      } else if (Platform.isIOS) {
        _loadIosParameters(await deviceInfo.iosInfo);
      } else {
        logger.w("Couldn't load device info for unsupported device type.");
      }
      _removeExcludedParameters();
    } catch (exception) {
      logger.w("Couldn't load device info", error: exception);
    }
  }

  /// Remove excluded parameters from device parameters.
  void _removeExcludedParameters() =>
      excludedParameters.forEach(deviceParameters.remove);

  void _loadLinuxParameters(LinuxDeviceInfo linuxDeviceInfo) {
    try {
      deviceParameters['name'] = linuxDeviceInfo.name;
      deviceParameters['version'] = linuxDeviceInfo.version;
      deviceParameters['id'] = linuxDeviceInfo.id;
      deviceParameters['idLike'] = linuxDeviceInfo.idLike;
      deviceParameters['versionCodename'] = linuxDeviceInfo.versionCodename;
      deviceParameters['versionId'] = linuxDeviceInfo.versionId;
      deviceParameters['prettyName'] = linuxDeviceInfo.prettyName;
      deviceParameters['buildId'] = linuxDeviceInfo.buildId;
      deviceParameters['variant'] = linuxDeviceInfo.variant;
      deviceParameters['variantId'] = linuxDeviceInfo.variantId;
      deviceParameters['machineId'] = linuxDeviceInfo.machineId;
    } catch (exception) {
      logger.w('Load Linux parameters failed', error: exception);
    }
  }

  void _loadMacOSParameters(MacOsDeviceInfo macOsDeviceInfo) {
    try {
      deviceParameters['computerName'] = macOsDeviceInfo.computerName;
      deviceParameters['hostName'] = macOsDeviceInfo.hostName;
      deviceParameters['arch'] = macOsDeviceInfo.arch;
      deviceParameters['model'] = macOsDeviceInfo.model;
      deviceParameters['kernelVersion'] = macOsDeviceInfo.kernelVersion;
      deviceParameters['osRelease'] = macOsDeviceInfo.osRelease;
      deviceParameters['activeCPUs'] = macOsDeviceInfo.activeCPUs;
      deviceParameters['memorySize'] = macOsDeviceInfo.memorySize;
      deviceParameters['cpuFrequency'] = macOsDeviceInfo.cpuFrequency;
    } catch (exception) {
      logger.w('Load MacOS parameters failed', error: exception);
    }
  }

  void _loadWindowsParameters(WindowsDeviceInfo windowsDeviceInfo) {
    try {
      deviceParameters['numberOfCores'] = windowsDeviceInfo.numberOfCores;
      deviceParameters['systemMemoryInMegabytes'] =
          windowsDeviceInfo.systemMemoryInMegabytes;
      deviceParameters['buildNumber'] = windowsDeviceInfo.buildNumber;
      deviceParameters['displayVersion'] = windowsDeviceInfo.displayVersion;
      deviceParameters['productName'] = windowsDeviceInfo.productName;
    } catch (exception) {
      logger.w('Load Windows parameters failed', error: exception);
    }
  }

  void _loadAndroidParameters(AndroidDeviceInfo androidDeviceInfo) {
    try {
      deviceParameters['id'] = androidDeviceInfo.id;
      // TODO(N): _deviceParameters["androidId"] = androidDeviceInfo.androidId;
      deviceParameters['board'] = androidDeviceInfo.board;
      deviceParameters['bootloader'] = androidDeviceInfo.bootloader;
      deviceParameters['brand'] = androidDeviceInfo.brand;
      deviceParameters['device'] = androidDeviceInfo.device;
      deviceParameters['display'] = androidDeviceInfo.display;
      deviceParameters['fingerprint'] = androidDeviceInfo.fingerprint;
      deviceParameters['hardware'] = androidDeviceInfo.hardware;
      deviceParameters['host'] = androidDeviceInfo.host;
      deviceParameters['isPhysicalDevice'] = androidDeviceInfo.isPhysicalDevice;
      deviceParameters['manufacturer'] = androidDeviceInfo.manufacturer;
      deviceParameters['model'] = androidDeviceInfo.model;
      deviceParameters['product'] = androidDeviceInfo.product;
      deviceParameters['supportedAbis'] =
          androidDeviceInfo.supportedAbis.join(',');
      deviceParameters['tags'] = androidDeviceInfo.tags;
      deviceParameters['type'] = androidDeviceInfo.type;
      deviceParameters['versionBaseOs'] = androidDeviceInfo.version.baseOS;
      deviceParameters['versionCodename'] = androidDeviceInfo.version.codename;
      deviceParameters['versionIncremental'] =
          androidDeviceInfo.version.incremental;
      deviceParameters['versionPreviewSdk'] =
          androidDeviceInfo.version.previewSdkInt;
      deviceParameters['versionRelease'] = androidDeviceInfo.version.release;
      deviceParameters['versionSdk'] = androidDeviceInfo.version.sdkInt;
      deviceParameters['versionSecurityPatch'] =
          androidDeviceInfo.version.securityPatch;
    } catch (exception) {
      logger.w('Load Android parameters failed', error: exception);
    }
  }

  void _loadIosParameters(IosDeviceInfo iosInfo) {
    try {
      deviceParameters['model'] = iosInfo.model;
      deviceParameters['isPhysicalDevice'] = iosInfo.isPhysicalDevice;
      deviceParameters['name'] = iosInfo.name;
      deviceParameters['identifierForVendor'] = iosInfo.identifierForVendor;
      deviceParameters['localizedModel'] = iosInfo.localizedModel;
      deviceParameters['systemName'] = iosInfo.systemName;
      deviceParameters['utsnameVersion'] = iosInfo.utsname.version;
      deviceParameters['utsnameRelease'] = iosInfo.utsname.release;
      deviceParameters['utsnameMachine'] = iosInfo.utsname.machine;
      deviceParameters['utsnameNodename'] = iosInfo.utsname.nodename;
      deviceParameters['utsnameSysname'] = iosInfo.utsname.sysname;
    } catch (exception) {
      logger.w('Load iOS parameters failed', error: exception);
    }
  }

  Future<void> _loadApplicationInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      applicationParameters['version'] = packageInfo.version;
      applicationParameters['appName'] = packageInfo.appName;
      applicationParameters['buildNumber'] = packageInfo.buildNumber;
      applicationParameters['packageName'] = packageInfo.packageName;
    } catch (exception) {
      logger.w("Couldn't load application info", error: exception);
    }
  }

  void onActionConfirmed(Report report) {
    for (final handler in handlers) {
      _handleReport(report, handler);
    }
  }

  void _handleReport(Report report, ReportHandler reportHandler) {
    reportHandler.handle(report).catchError((handlerError) {
      logger.w('Error occurred in $reportHandler', error: handlerError);
      return true; // Shut up warnings
    }).then((result) {
      if (result) {
        logger.d('$reportHandler successfully reported an error');
      } else {
        logger.w('$reportHandler failed to report an error');
      }
    }).timeout(
      handlerTimeout,
      onTimeout: () {
        logger.w('$reportHandler failed to report an error because of timeout');
      },
    );
  }
}
