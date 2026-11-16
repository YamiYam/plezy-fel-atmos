import Cocoa
import FlutterMacOS
import PlezyNativePlayback

private final class NativePlaybackContainer: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26, *)
@MainActor
final class NativePlaybackPlugin: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler {
  private var session: PlaybackSession?
  private var eventSink: FlutterEventSink?
  private weak var registrar: FlutterPluginRegistrar?
  private var instanceID: Int?
  private var opening: Task<Void, Never>?
  private let container = NativePlaybackContainer()

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = NativePlaybackPlugin()
    plugin.registrar = registrar
    registrar.addMethodCallDelegate(
      plugin,
      channel: FlutterMethodChannel(name: "com.plezy/native_playback", binaryMessenger: registrar.messenger)
    )
    FlutterEventChannel(
      name: "com.plezy/native_playback/events", binaryMessenger: registrar.messenger
    ).setStreamHandler(plugin)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "dispose", args["instanceId"] as? Int != instanceID {
      result(nil)
      return
    }
    if ["initialize", "open", "dispose", "stop"].contains(call.method) {
      opening?.cancel()
    }
    let operation = Task { @MainActor in
      do {
        result(try await self.perform(call.method, args: args))
      } catch is CancellationError {
        result(FlutterError(code: "CANCELLED", message: "Playback operation superseded.", details: nil))
      } catch {
        NSLog("[NativePlayback] %@: %@", call.method, error.localizedDescription)
        result(FlutterError(code: "NATIVE_PLAYBACK_FAILED", message: error.localizedDescription, details: nil))
      }
    }
    if call.method == "open" { opening = operation }
  }

  private func perform(_ method: String, args: [String: Any]) async throws -> Any? {
    try Task.checkCancellation()
    if method == "initialize" {
      guard let id = args["instanceId"] as? Int else {
        throw NativePlaybackError.invalidArgument("instanceId")
      }
      session?.close()
      container.removeFromSuperview()
      let playback = try PlaybackSession()
      playback.onEvent = { [weak self] in self?.eventSink?($0) }
      session = playback
      instanceID = id
      try updateFrame()
      return true
    }
    if method == "dispose" {
      guard args["instanceId"] as? Int == instanceID else { return nil }
      session?.close()
      container.removeFromSuperview()
      session = nil
      instanceID = nil
      return nil
    }
    guard let session else { throw NativePlaybackError.unavailable }
    switch method {
    case "open":
      guard let uri = args["uri"] as? String else {
        throw NativePlaybackError.invalidArgument("uri")
      }
      session.view.isHidden = false
      let subtitles = try (args["externalSubtitles"] as? [[String: Any]] ?? []).map { subtitle in
        guard let uri = subtitle["uri"] as? String else {
          throw NativePlaybackError.invalidArgument("subtitle URI")
        }
        return NativeSubtitle(
          uri: uri, title: subtitle["title"] as? String, language: subtitle["language"] as? String,
          codec: subtitle["codec"] as? String,
          isDefault: subtitle["isDefault"] as? Bool ?? false,
          isForced: subtitle["isForced"] as? Bool ?? false
        )
      }
      return try await session.open(
        uri: uri, headers: args["headers"] as? [String: String] ?? [:],
        start: try number(args, "startPositionMs") / 1000,
        autoplay: args["autoPlay"] as? Bool ?? true,
        isLive: args["isLive"] as? Bool ?? false, subtitles: subtitles
      )
    case "play": try await session.play()
    case "pause": session.pause()
    case "stop": session.stop()
    case "seek": try await session.seek(try number(args, "positionMs") / 1000)
    case "setVolume": try session.setVolume(try number(args, "volume"))
    case "setRate": try session.setRate(try number(args, "rate"))
    case "selectAudioTrack", "selectSubtitleTrack":
      guard let id = args["trackId"] as? String else {
        throw NativePlaybackError.invalidArgument("trackId")
      }
      try session.selectTrack(id, subtitle: method == "selectSubtitleTrack")
    case "setProperty":
      guard let name = args["name"] as? String, let value = args["value"] as? String else {
        throw NativePlaybackError.invalidArgument("property")
      }
      try await session.setProperty(name, value: value)
    case "getProperty":
      guard let name = args["name"] as? String else {
        throw NativePlaybackError.invalidArgument("property name")
      }
      return session.property(name)
    case "getStats": return session.stats()
    case "isHdrOutputSupported":
      return (registrar?.view?.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    case "setVisible":
      guard let visible = args["visible"] as? Bool else {
        throw NativePlaybackError.invalidArgument("visible")
      }
      session.view.isHidden = !visible
      if visible { try updateFrame() }
      return true
    case "updateFrame": try updateFrame()
    case "setBoxFitMode":
      guard let mode = args["mode"] as? Int else {
        throw NativePlaybackError.invalidArgument("mode")
      }
      try session.setFit(mode)
    default: throw NativePlaybackError.unsupported(method)
    }
    return nil
  }

  private func number(_ args: [String: Any], _ key: String) throws -> Double {
    guard let value = args[key] as? NSNumber, value.doubleValue.isFinite else {
      throw NativePlaybackError.invalidArgument(key)
    }
    return value.doubleValue
  }

  private func updateFrame() throws {
    guard let window = registrar?.view?.window,
      let contentView = window.contentView, let session
    else { throw NativePlaybackError.unavailable }
    if container.superview !== contentView {
      container.frame = contentView.bounds
      container.autoresizingMask = [.width, .height]
      container.wantsLayer = true
      contentView.addSubview(container, positioned: .below, relativeTo: nil)
    }
    if session.view.superview !== container {
      session.view.frame = container.bounds
      session.view.autoresizingMask = [.width, .height]
      container.addSubview(session.view)
    }
    if let parent = contentView.layer, let layer = container.layer,
      parent.sublayers?.first !== layer
    {
      layer.removeFromSuperlayer()
      parent.insertSublayer(layer, at: 0)
    }
    container.frame = contentView.bounds
    session.view.frame = container.bounds
  }
}
