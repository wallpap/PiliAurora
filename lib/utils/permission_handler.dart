import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart'
    show Permission, PermissionStatus, PermissionHandlerPlatform;

export 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart'
    show Permission, PermissionStatus;

PermissionHandlerPlatform get _handler => PermissionHandlerPlatform.instance;

Future<bool> openAppSettings() => _handler.openAppSettings();

extension PermissionActions on Permission {
  Future<PermissionStatus> request() async =>
      (await _handler.requestPermissions([this]))[this] ??
      PermissionStatus.denied;
}
