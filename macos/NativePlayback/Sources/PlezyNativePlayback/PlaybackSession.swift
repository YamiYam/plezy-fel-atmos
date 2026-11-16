import AetherEngine
import AppKit
import AVFoundation
import Combine

public enum NativePlaybackError: LocalizedError {
  case invalidArgument(String)
  case unsupported(String)
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let value): return "Invalid playback argument: \(value)"
    case .unsupported(let feature): return "Experimental native playback does not support \(feature)."
    case .unavailable: return "The native playback session is no longer available."
    }
  }
}

public struct NativeSubtitle: Sendable {
  public let uri: String
  public let title: String?
  public let language: String?
  public let codec: String?
  public let isDefault: Bool
  public let isForced: Bool

  public init(
    uri: String, title: String?, language: String?, codec: String?,
    isDefault: Bool, isForced: Bool
  ) {
    self.uri = uri
    self.title = title
    self.language = language
    self.codec = codec
    self.isDefault = isDefault
    self.isForced = isForced
  }
}

struct NativePlaybackConfiguration {
  var hardwareDecoding = true
  var hdr = true
  var dolbyVision = true
  var audioDelay = 0.0
  var volume: Float = 1
  var muted = false

  func options(headers: [String: String], autoplay: Bool) -> LoadOptions {
    var options = LoadOptions()
    options.httpHeaders = headers
    options.autoplay = autoplay
    options.preferDualLayerDolbyVision = hardwareDecoding && hdr && dolbyVision
    options.foldsDolbyVisionFEL = false
    options.dolbyVisionHandling = dolbyVision && hdr ? .automatic : .baseLayerOnly
    options.objectAudioRendering = .apac(.l714)
    options.rendersDTSXObjectAudio = false
    options.confirmAtmos = true
    options.audioDelaySeconds = audioDelay
    options.preferredDecodePath = hardwareDecoding ? .automatic : .software
    return options
  }
}

@MainActor
@available(macOS 26, *)
public final class PlaybackSession {
  public let view: NSView
  public var onEvent: (([String: Any]) -> Void)?

  private let engine: AetherEngine
  private var configuration = NativePlaybackConfiguration()
  private var observations = Set<AnyCancellable>()
  private var poller: Task<Void, Never>?
  private var sourceID = 0
  private var closed = false
  private var firstFrame = false
  private var loading = false
  private var replay: (uri: String, headers: [String: String], subtitles: [NativeSubtitle])?
  private var subtitleDelay = 0.0
  private var subtitlesVisible = true
  private let subtitleLayer = CATextLayer()
  private let bitmapLayer = CALayer()
  private let dolbyVisionDiagnostics = DolbyVisionDiagnostics()

  public init() throws {
    guard AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn,
      AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn
    else { throw NativePlaybackError.unsupported("a build without FEL and TrueHD object decoders") }
    engine = try AetherEngine()
    let surface = AetherPlayerView(frame: .zero)
    view = surface
    engine.bind(view: surface)
    subtitleLayer.alignmentMode = .center
    subtitleLayer.isWrapped = true
    subtitleLayer.foregroundColor = NSColor.white.cgColor
    subtitleLayer.shadowColor = NSColor.black.cgColor
    subtitleLayer.shadowOpacity = 1
    subtitleLayer.shadowRadius = 2
    subtitleLayer.zPosition = 11
    bitmapLayer.zPosition = 10
    surface.layer?.addSublayer(subtitleLayer)
    surface.layer?.addSublayer(bitmapLayer)
    EngineLog.structuredHandler = { [weak diagnostics = dolbyVisionDiagnostics] line, _, _ in
      diagnostics?.record(line)
    }

    engine.$state.sink { [weak self] state in
      guard let self, !self.closed else { return }
      switch state {
      case .ended:
        self.emitProperties(["eof-reached": true, "pause": true])
        self.emit("end-file", ["reason": "eof", "error": 0])
      case .error(let message):
        self.emit("log-message", ["prefix": "aether", "level": "error", "text": message])
        if !self.loading {
          self.emit("end-file", ["reason": "error", "message": message])
        }
      default: break
      }
    }.store(in: &observations)
  }

  public func open(
    uri: String, headers: [String: String], start: Double, autoplay: Bool, isLive: Bool,
    subtitles: [NativeSubtitle] = []
  ) async throws -> Int {
    guard !closed else { throw NativePlaybackError.unavailable }
    guard !isLive else { throw NativePlaybackError.unsupported("live TV; use the standard build") }
    guard start.isFinite, start >= 0 else { throw NativePlaybackError.invalidArgument("start") }
    let url = try Self.mediaURL(uri)
    let external = try subtitles.map {
      ExternalSubtitleTrack(
        url: try Self.mediaURL($0.uri), name: $0.title, language: $0.language,
        isForced: $0.isForced, isDefault: $0.isDefault, formatHint: $0.codec
      )
    }
    poller?.cancel()
    sourceID += 1
    let openingID = sourceID
    firstFrame = false
    loading = true
    dolbyVisionDiagnostics.reset()
    defer { if sourceID == openingID { loading = false } }
    subtitleLayer.string = nil
    bitmapLayer.sublayers = nil
    emit("start-file")
    var options = configuration.options(headers: headers, autoplay: autoplay)
    options.externalSubtitles = external
    _ = try await engine.load(url: url, startPosition: start, options: options)
    guard !closed, sourceID == openingID, !Task.isCancelled else { throw CancellationError() }
    guard engine.audioDelivery != .droppedNoPipeline else {
      engine.stop()
      throw NativePlaybackError.unsupported("this source's audio pipeline; use the standard mpv build")
    }
    replay = (uri, headers, subtitles)
    engine.volume = configuration.muted ? 0 : configuration.volume
    applyHDRPolicy()
    emit("file-loaded")
    emitProperties(["track-list": tracks()])
    poller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.closed, self.sourceID == openingID else { return }
        await self.poll(source: openingID)
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      }
    }
    return openingID
  }

  nonisolated static func mediaURL(_ uri: String) throws -> URL {
    if uri.hasPrefix("/") { return URL(fileURLWithPath: uri) }
    guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
      ["file", "http", "https"].contains(scheme)
    else { throw NativePlaybackError.invalidArgument("media URI") }
    return url
  }

  public func play() async throws {
    if engine.state == .ended, let replay {
      _ = try await open(
        uri: replay.uri, headers: replay.headers, start: 0, autoplay: true,
        isLive: false, subtitles: replay.subtitles
      )
      return
    }
    guard engine.isSessionReady else { throw NativePlaybackError.unavailable }
    engine.play()
  }

  public func pause() { engine.pause() }

  public func stop() {
    dolbyVisionDiagnostics.reset()
    poller?.cancel()
    poller = nil
    sourceID += 1
    loading = false
    replay = nil
    engine.stop()
    subtitleLayer.string = nil
    bitmapLayer.sublayers = nil
  }

  public func close() {
    closed = true
    stop()
    observations.removeAll()
    EngineLog.structuredHandler = nil
    onEvent = nil
    view.removeFromSuperview()
  }

  public func seek(_ seconds: Double) async throws {
    guard seconds.isFinite, seconds >= 0 else {
      throw NativePlaybackError.invalidArgument("seek position")
    }
    if engine.state == .ended, let replay {
      _ = try await open(
        uri: replay.uri, headers: replay.headers, start: seconds, autoplay: false,
        isLive: false, subtitles: replay.subtitles
      )
      return
    }
    guard engine.canSeek else { throw NativePlaybackError.unavailable }
    await engine.seek(to: seconds, exact: true)
  }

  public func setVolume(_ value: Double) throws {
    guard value.isFinite, (0...100).contains(value) else {
      throw NativePlaybackError.invalidArgument("volume")
    }
    configuration.volume = Float(value / 100)
    engine.volume = configuration.muted ? 0 : configuration.volume
  }

  public func setRate(_ value: Double) throws {
    guard value.isFinite, value >= 0.25, value <= Double(engine.maxSupportedRate) else {
      throw NativePlaybackError.invalidArgument("rate")
    }
    engine.setRate(Float(value))
  }

  public func selectTrack(_ id: String, subtitle: Bool) throws {
    if subtitle && id == "no" {
      engine.selectSubtitleTrack(index: -1)
      return
    }
    guard let index = Int(id),
      (subtitle ? engine.subtitleTracks : engine.audioTracks).contains(where: { $0.id == index })
    else { throw NativePlaybackError.invalidArgument("track ID") }
    if subtitle { engine.selectSubtitleTrack(index: index) }
    else { engine.selectAudioTrack(index: index) }
    emitProperties(["track-list": tracks()])
  }

  public func setProperty(_ name: String, value: String) async throws {
    var next = configuration
    switch name {
    case "hwdec":
      next.hardwareDecoding = value != "no"
    case "hdr-enabled":
      next.hdr = try Self.flag(value)
    case "dv-conversion-mode":
      guard ["auto", "hevc_strip"].contains(value) else {
        throw NativePlaybackError.unsupported("this conversion override; choose Auto for FEL reconstruction")
      }
      next.dolbyVision = value == "auto"
    case "mute":
      configuration.muted = try Self.flag(value)
      engine.volume = configuration.muted ? 0 : configuration.volume
    case "audio-delay":
      guard let delay = Double(value), delay.isFinite else {
        throw NativePlaybackError.invalidArgument(name)
      }
      next.audioDelay = delay
    case "sub-delay":
      guard let delay = Double(value), delay.isFinite else {
        throw NativePlaybackError.invalidArgument(name)
      }
      subtitleDelay = delay
    case "sub-visibility":
      subtitlesVisible = try Self.flag(value)
      subtitleLayer.isHidden = !subtitlesVisible
      bitmapLayer.isHidden = !subtitlesVisible
    default: throw NativePlaybackError.unsupported("the mpv property '\(name)'")
    }
    let changesRoute = next.hardwareDecoding != configuration.hardwareDecoding
      || next.hdr != configuration.hdr || next.dolbyVision != configuration.dolbyVision
      || next.audioDelay != configuration.audioDelay
    if changesRoute && engine.isSessionReady {
      let updated = next.options(headers: [:], autoplay: true)
      try await engine.reloadAtCurrentPosition { options in
        options.preferDualLayerDolbyVision = updated.preferDualLayerDolbyVision
        options.dolbyVisionHandling = updated.dolbyVisionHandling
        options.preferredDecodePath = updated.preferredDecodePath
        options.audioDelaySeconds = updated.audioDelaySeconds
      }
    }
    next.volume = configuration.volume
    next.muted = configuration.muted
    configuration = next
    applyHDRPolicy()
  }

  nonisolated static func flag(_ value: String) throws -> Bool {
    switch value {
    case "yes": return true
    case "no": return false
    default: throw NativePlaybackError.invalidArgument("boolean '\(value)'")
    }
  }

  public func property(_ name: String) -> String? {
    switch name {
    case "time-pos": return String(engine.currentTime)
    case "duration": return String(engine.duration)
    case "seekable": return engine.canSeek ? "yes" : "no"
    case "pause": return engine.state == .playing ? "no" : "yes"
    case "mute": return configuration.muted ? "yes" : "no"
    case "audio-delay": return String(configuration.audioDelay)
    case "sub-delay": return String(subtitleDelay)
    case "container-fps": return engine.sourceVideoFrameRate.map { String($0) }
    case "video-codec": return engine.sourceVideoCodecName
    case "video-decoder": return engine.activeVideoDecoder
    case "audio-codec-name": return engine.activeAudioDecoder
    case "hwdec": return configuration.hardwareDecoding ? "auto" : "no"
    case "hdr-enabled": return configuration.hdr ? "yes" : "no"
    case "dv-conversion-mode": return configuration.dolbyVision ? "auto" : "hevc_strip"
    case "width": return String(engine.sourceVideoWidth)
    case "height": return String(engine.sourceVideoHeight)
    default: return nil
    }
  }

  public func setFit(_ mode: Int) throws {
    switch mode {
    case 0: engine.videoGravity = .resizeAspect
    case 1: engine.videoGravity = .resizeAspectFill
    case 2: engine.videoGravity = .resize
    default: throw NativePlaybackError.invalidArgument("fit")
    }
  }

  public func stats() -> [String: Any] {
    var result: [String: Any] = [
      "playerType": "aether",
      "backend": "aether",
      "videoRoute": engine.videoRoute.rawValue,
      "audioDelivery": engine.audioDelivery.rawValue,
      "felRequested": configuration.hardwareDecoding && configuration.hdr && configuration.dolbyVision,
      "trueHDObjectRenderingRequested": true,
      "audioOutput": "APAC 7.1.4 rendered bed (not TrueHD bitstream)",
      "displayManagementVerified": false,
    ]
    result["videoCodec"] = engine.sourceVideoCodecName
    result["videoDecoder"] = engine.activeVideoDecoder
    result["videoDecoderName"] = engine.activeVideoDecoder
    result["videoWidth"] = Int(engine.sourceVideoWidth)
    result["videoHeight"] = Int(engine.sourceVideoHeight)
    result["videoFps"] = engine.sourceVideoFrameRate
    result["audioDecoder"] = engine.activeAudioDecoder
    result["audioDecoderName"] = engine.activeAudioDecoder
    result["sourceDolbyVisionProfile"] = engine.sourceDVProfile
    result["dvSourceProfile"] = engine.sourceDVProfile
    if engine.sourceDVProfile == 7 {
      let diagnostics = dolbyVisionDiagnostics.snapshot()
      result["dvEnhancementLayerType"] = diagnostics.enhancementLayer
      result["dvFelCompositingActive"] = diagnostics.felActive && firstFrame
      result["dvFelComposedFrames"] = diagnostics.composedFrames
      if !diagnostics.felSelected || diagnostics.compositionBlocked {
        result["dvPlaybackPath"] = engine.videoFormat == .dolbyVision ? "P8.1 (BL + RPU)" : "HDR10 (BL)"
      }
    }
    if let activity = engine.liveTelemetry?.objectAudio {
      result["objectAudio"] = [
        "layout": activity.layout.rawValue, "objects": activity.objects,
        "activeObjects": activity.activeObjects, "elevatedObjects": activity.elevatedObjects,
        "heightChannels": activity.heightChannels,
      ]
    }
    return result
  }

  private func applyHDRPolicy() {
    view.layer?.preferredDynamicRange = configuration.hdr ? .high : .standard
    for layer in view.layer?.sublayers ?? [] {
      layer.preferredDynamicRange = configuration.hdr ? .high : .standard
    }
  }

  private func poll(source: Int) async {
    let rendered = await engine.hasRenderedVideoFrame()
    guard !closed, sourceID == source, !Task.isCancelled else { return }
    if engine.audioDelivery == .droppedNoPipeline {
      emit("end-file", ["reason": "error", "message": "Audio pipeline failed; use the standard mpv build."])
      engine.stop()
      poller?.cancel()
      return
    }
    emitProperties([
      "time-pos": engine.currentTime, "duration": engine.duration,
      "seekable": engine.canSeek, "pause": engine.state != .playing,
      "paused-for-cache": engine.isBuffering, "demuxer-cache-time": engine.bufferedPosition,
      "aid": engine.activeAudioTrackIndex.map(String.init) ?? "no",
      "sid": engine.activeSubtitleTrackIndex.map(String.init) ?? "no",
      "track-list": tracks(),
    ])
    if rendered && !firstFrame {
      firstFrame = true
      emit("playback-restart", ["positionSeconds": engine.currentTime])
    }
    drawSubtitles()
  }

  private func tracks() -> [[String: Any]] {
    func describe(_ track: TrackInfo, type: String, selected: Int?) -> [String: Any] {
      var result: [String: Any] = [
        "id": track.id, "type": type, "title": track.name, "codec": track.codec,
        "selected": track.id == selected, "default": track.isDefault, "forced": track.isForced,
        "demux-channel-count": track.channels, "demux-samplerate": track.sampleRate,
        "external": track.isExternal,
      ]
      result["lang"] = track.language
      result["codec-profile"] = track.profile
      return result
    }
    return engine.audioTracks.map { describe($0, type: "audio", selected: engine.activeAudioTrackIndex) }
      + engine.subtitleTracks.map { describe($0, type: "sub", selected: engine.activeSubtitleTrackIndex) }
  }

  private func drawSubtitles() {
    let time = engine.sourceTime - subtitleDelay
    let cues = engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    bitmapLayer.frame = view.bounds
    bitmapLayer.sublayers = cues.compactMap { cue in
      guard case .image(let image) = cue.body else { return nil }
      let layer = CALayer()
      layer.contents = image.cgImage
      let coded = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
      let displayed = engine.softwareDisplaySize ?? CGSize(
        width: coded.width * engine.sourceVideoPixelAspectRatio, height: coded.height
      )
      let picture = engine.videoGravity == .resize ? view.bounds :
        Self.pictureRect(size: displayed, bounds: view.bounds, fill: engine.videoGravity == .resizeAspectFill)
      let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0 ? image.canvasSize : coded
      let height = coded.width > 0 && coded.height > 0
        ? picture.height * (canvas.height * coded.width / canvas.width) / coded.height : picture.height
      let rect = image.position
      layer.frame = CGRect(
        x: picture.minX + rect.minX * picture.width,
        y: picture.midY + height / 2 - rect.maxY * height,
        width: rect.width * picture.width, height: rect.height * height
      )
      return layer
    }
    let text = cues.compactMap { cue -> String? in
      switch cue.body {
      case .text(let text): return text
      case .richText(let runs): return runs.map(\.text).joined()
      case .image: return nil
      }
    }.joined(separator: "\n")
    subtitleLayer.contentsScale = view.window?.backingScaleFactor ?? 2
    subtitleLayer.fontSize = max(18, view.bounds.height / 25)
    subtitleLayer.frame = CGRect(
      x: view.bounds.width * 0.05, y: view.bounds.height * 0.05,
      width: view.bounds.width * 0.9, height: view.bounds.height * 0.2
    )
    subtitleLayer.string = text
  }

  nonisolated static func pictureRect(size: CGSize, bounds: CGRect, fill: Bool) -> CGRect {
    guard size.width > 0, size.height > 0 else { return bounds }
    let x = bounds.width / size.width
    let y = bounds.height / size.height
    let scale = fill ? max(x, y) : min(x, y)
    let width = size.width * scale
    let height = size.height * scale
    return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
  }

  private func emitProperties(_ values: [String: Any]) { emit("properties", ["values": values]) }

  private func emit(_ name: String, _ data: [String: Any] = [:]) {
    var payload = data
    payload["sourceId"] = sourceID
    onEvent?(["type": "event", "name": name, "data": payload])
  }
}
