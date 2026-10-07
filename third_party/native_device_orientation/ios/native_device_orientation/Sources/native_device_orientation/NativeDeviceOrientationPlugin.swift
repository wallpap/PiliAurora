import Flutter
import UIKit

let METHOD_CHANEL:String = "native_device_orientation"
let EVENT_CHANNEL:String = "native_device_orientation_events"

let PORTRAIT_UP:String! = "portraitUp"
let PORTRAIT_DOWN:String! = "portraitDown"
let LANDSCAPE_LEFT:String! = "landscapeLeft"
let LANDSCAPE_RIGHT:String! = "landscapeRight"

public class NativeDeviceOrientationPlugin: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativeDeviceOrientationPlugin()

    let channel = FlutterMethodChannel(name: "native_device_orientation", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)

    let eventChannel = FlutterEventChannel(name: "native_device_orientation_events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)
  }


  private var listener:OrientationListener?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let argReader = MapArgumentReader(call.arguments as? [String: Any])

    switch call.method {
    case "pause":
      pause()
      result(nil)
    case "resume":
      result(resume())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

extension NativeDeviceOrientationPlugin: FlutterStreamHandler {
  func pause() {
    guard let listener = listener else {
      return
    }

    listener.stop()
  }

  func resume() -> FlutterError? {
    if let listener = listener {
      return listener.start()
    }
    return nil
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    let argReader = MapArgumentReader(arguments as? [String: Any])

    let listener: OrientationListener = DisplayOrientationListener{ events($0) }

    if let error = listener.start() {
      return error
    }

    self.listener = listener
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let listener = listener {
      listener.stop()
    }
    listener = nil
    return nil
  }
}
