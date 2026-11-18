import AVFoundation
import Flutter
import Foundation

/// Records 16 kHz mono PCM and turns an imported file into the same WAV.
final class VoiceSession: NSObject, FlutterStreamHandler {
  private var events: FlutterEventSink?
  private let engine = AVAudioEngine()
  private var player: AVAudioPlayer?
  private var pcm = Data()
  private var recording = false
  private var interrupted = false
  private var reachedLimit = false
  private var started: Date?
  private var maxMs = 30_000
  private var timer: Timer?
  private let lock = NSLock()

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.events = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  func startRecording(maxMs: Int, result: @escaping FlutterResult) {
    let limit = min(max(maxMs, 1), 30_000)
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      DispatchQueue.main.async {
        if !granted {
          result(
            FlutterError(
              code: "permissionDenied",
              message: "没有获得使用麦克风的权限。",
              details: nil
            )
          )
          return
        }
        self.begin(limit: limit, result: result)
      }
    }
  }

  func stopRecording(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      self.finish(reachedLimit: false)
      result(nil)
    }
  }

  func decode(path: String, maxMs: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let wav = try Self.wavFile(path: path, maxMs: maxMs)
        DispatchQueue.main.async {
          result(FlutterStandardTypedData(bytes: wav))
        }
      } catch VoiceError.tooLong {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "tooLong",
              message: "这段音频超过 60 秒，这一版还不分段。",
              details: nil
            )
          )
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "file_corrupt",
              message: "这段音频无法读取。",
              details: nil
            )
          )
        }
      }
    }
  }

  func play(wav: FlutterStandardTypedData?, result: @escaping FlutterResult) {
    guard let wav, !wav.data.isEmpty else {
      result(
        FlutterError(
          code: "file_corrupt",
          message: "这段音频无法读取。",
          details: nil
        )
      )
      return
    }
    do {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ta_chat_play.wav"
      )
      try wav.data.write(to: url)
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
      let created = try AVAudioPlayer(contentsOf: url)
      player?.stop()
      player = created
      created.play()
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "file_corrupt",
          message: "这段音频无法读取。",
          details: nil
        )
      )
    }
  }

  func stopPlayback(result: @escaping FlutterResult) {
    player?.stop()
    player = nil
    result(nil)
  }

  private func begin(limit: Int, result: @escaping FlutterResult) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth]
      )
      try session.setActive(true)
      let input = engine.inputNode
      let hardware = input.outputFormat(forBus: 0)
      guard let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      ), let converter = AVAudioConverter(from: hardware, to: target) else {
        throw VoiceError.unreadable
      }
      lock.lock()
      pcm = Data()
      lock.unlock()
      interrupted = false
      reachedLimit = false
      maxMs = limit
      started = Date()
      input.removeTap(onBus: 0)
      input.installTap(onBus: 0, bufferSize: 4096, format: hardware) {
        [weak self] buffer, _ in
        self?.append(buffer, converter: converter, target: target)
      }
      engine.prepare()
      try engine.start()
      recording = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleInterruption),
        name: AVAudioSession.interruptionNotification,
        object: session
      )
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
        [weak self] _ in
        self?.tick()
      }
      result(nil)
    } catch {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      recording = false
      result(
        FlutterError(
          code: "audioInterrupted",
          message: "录音被打断。",
          details: nil
        )
      )
    }
  }

  private func append(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    target: AVAudioFormat
  ) {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard capacity > 0,
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
    else { return }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, output.frameLength > 0, let channels = output.int16ChannelData
    else { return }
    let chunk = Data(bytes: channels[0], count: Int(output.frameLength) * 2)
    lock.lock()
    pcm.append(chunk)
    lock.unlock()
  }

  private func tick() {
    guard recording, let started else { return }
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    events?(["elapsedMs": elapsed])
    if elapsed >= maxMs {
      reachedLimit = true
      finish(reachedLimit: true)
    }
  }

  @objc private func handleInterruption(_ notice: Notification) {
    let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
    let kind = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
    if kind == .began {
      interrupted = true
      finish(reachedLimit: false)
    }
  }

  private func finish(reachedLimit limitFlag: Bool) {
    guard recording || engine.isRunning else { return }
    if limitFlag { reachedLimit = true }
    recording = false
    timer?.invalidate()
    timer = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    NotificationCenter.default.removeObserver(
      self,
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    lock.lock()
    let samples = pcm
    pcm = Data()
    lock.unlock()
    let wav = Self.wav(from: samples, sampleRate: 16_000)
    events?([
      "done": true,
      "wav": FlutterStandardTypedData(bytes: wav),
      "interrupted": interrupted,
      "reachedLimit": reachedLimit,
    ])
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private static func wavFile(path: String, maxMs: Int) throws -> Data {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let rate = file.fileFormat.sampleRate
    if rate <= 0 { throw VoiceError.unreadable }
    let durationMs = Double(file.length) / rate * 1000
    if durationMs > Double(maxMs) { throw VoiceError.tooLong }
    guard let target = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    ) else { throw VoiceError.unreadable }
    let input = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: AVAudioFrameCount(file.length)
    )
    guard let input else { throw VoiceError.unreadable }
    try file.read(into: input)
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target)
    else { throw VoiceError.unreadable }
    let outFrames = AVAudioFrameCount(
      max(1, Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate)
    )
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames + 32)
    else { throw VoiceError.unreadable }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .endOfStream
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return input
    }
    if error != nil || output.frameLength == 0 || output.int16ChannelData == nil {
      throw VoiceError.unreadable
    }
    let data = Data(
      bytes: output.int16ChannelData![0],
      count: Int(output.frameLength) * 2
    )
    return wav(from: data, sampleRate: 16_000)
  }

  private static func wav(from pcm: Data, sampleRate: Int) -> Data {
    var data = Data(count: 44 + pcm.count)
    data.replaceSubrange(0..<4, with: Array("RIFF".utf8))
    write32(&data, 4, UInt32(36 + pcm.count))
    data.replaceSubrange(8..<12, with: Array("WAVE".utf8))
    data.replaceSubrange(12..<16, with: Array("fmt ".utf8))
    write32(&data, 16, 16)
    write16(&data, 20, 1)
    write16(&data, 22, 1)
    write32(&data, 24, UInt32(sampleRate))
    write32(&data, 28, UInt32(sampleRate * 2))
    write16(&data, 32, 2)
    write16(&data, 34, 16)
    data.replaceSubrange(36..<40, with: Array("data".utf8))
    write32(&data, 40, UInt32(pcm.count))
    data.replaceSubrange(44..<data.count, with: pcm)
    return data
  }

  private static func write16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
  }

  private static func write32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
  }
}

private enum VoiceError: Error {
  case tooLong
  case unreadable
}
