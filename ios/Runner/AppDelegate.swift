import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let textEngine = IosLlama()
  private let whisper = IosWhisper()
  private let sherpa = IosSherpa()
  private let voice = VoiceSession()
  private let textEvents = EventRelay()
  private let speechEvents = EventRelay()
  private let extractEvents = EventRelay()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LlamaBridge")!.messenger()

    let text = FlutterMethodChannel(
      name: "dev.local.gptanywhere/llama",
      binaryMessenger: messenger
    )
    text.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":
        self.textEngine.start(args) { event in
          self.textEvents.emit(event)
        }
        result(nil)
      case "cancel":
        if let taskId = args["taskId"] as? String {
          self.textEngine.cancel(taskId)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(
      name: "dev.local.gptanywhere/llama_events",
      binaryMessenger: messenger
    ).setStreamHandler(textEvents)

    let device = FlutterMethodChannel(
      name: "dev.local.gptanywhere/device",
      binaryMessenger: messenger
    )
    device.setMethodCallHandler { call, result in
      if call.method == "totalMemoryBytes" {
        result(NSNumber(value: ProcessInfo.processInfo.physicalMemory))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let speech = FlutterMethodChannel(
      name: "dev.local.gptanywhere/asr",
      binaryMessenger: messenger
    )
    speech.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":
        let engine = args["engine"] as? String
        let forward: ([AnyHashable: Any]) -> Void = { event in
          self.speechEvents.emit(event)
        }
        if engine == "whisper" {
          self.whisper.start(args, onEvent: forward)
        } else {
          self.sherpa.start(args, onEvent: forward)
        }
        result(nil)
      case "cancel":
        if let taskId = args["taskId"] as? String {
          self.whisper.cancel(taskId)
          self.sherpa.cancel(taskId)
        }
        result(nil)
      case "extract":
        self.sherpa.extract(args, progress: { written in
          self.extractEvents.emit(["extractBytes": written])
        }, result: { error in
          if error == nil {
            result(nil)
          } else {
            result(
              FlutterError(
                code: "file_corrupt",
                message: "听写模型无法解压。",
                details: nil
              )
            )
          }
        })
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(
      name: "dev.local.gptanywhere/asr_events",
      binaryMessenger: messenger
    ).setStreamHandler(speechEvents)
    FlutterEventChannel(
      name: "dev.local.gptanywhere/asr_extract",
      binaryMessenger: messenger
    ).setStreamHandler(extractEvents)

    let voiceChannel = FlutterMethodChannel(
      name: "dev.local.gptanywhere/voice",
      binaryMessenger: messenger
    )
    voiceChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "startRecording":
        let maxMs = args["maxMs"] as? Int ?? 30_000
        self.voice.startRecording(maxMs: maxMs, result: result)
      case "stopRecording":
        self.voice.stopRecording(result: result)
      case "decode":
        guard let path = args["path"] as? String else {
          result(
            FlutterError(
              code: "file_corrupt",
              message: "这段音频无法读取。",
              details: nil
            )
          )
          return
        }
        let maxMs = args["maxMs"] as? Int ?? 60_000
        self.voice.decode(path: path, maxMs: maxMs, result: result)
      case "play":
        self.voice.play(wav: args["wav"] as? FlutterStandardTypedData, result: result)
      case "stopPlayback":
        self.voice.stopPlayback(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(
      name: "dev.local.gptanywhere/voice_events",
      binaryMessenger: messenger
    ).setStreamHandler(voice)
  }
}

private final class EventRelay: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func emit(_ event: Any) {
    if Thread.isMainThread {
      sink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?(event)
      }
    }
  }
}
