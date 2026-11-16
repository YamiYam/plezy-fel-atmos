import AppKit
import AVFoundation
import XCTest
@testable import PlezyNativePlayback

@available(macOS 26, *)
final class PlaybackSmokeTests: XCTestCase {
  @MainActor
  func testGeneratedVideoRendersSeeksAndCloses() async throws {
    try await playbackSmoke(software: false)
  }

  @MainActor
  func testSoftwareDecodedVideoRendersSeeksAndCloses() async throws {
    try await playbackSmoke(software: true)
  }

  @MainActor
  private func playbackSmoke(software: Bool) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("plezy-smoke-\(UUID().uuidString).mov")
    defer {
      do { try FileManager.default.removeItem(at: url) }
      catch { XCTFail("Could not remove smoke fixture: \(error)") }
    }
    try await writeVideo(to: url)
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let session = try PlaybackSession()
    if software { try await session.setProperty("hwdec", value: "no") }
    session.view.frame = window.contentView!.bounds
    window.contentView!.addSubview(session.view)
    defer {
      session.close()
      window.close()
    }
    var rendered = false
    var failure: String?
    session.onEvent = { event in
      if event["name"] as? String == "playback-restart" { rendered = true }
      if event["name"] as? String == "end-file",
        let data = event["data"] as? [String: Any], data["reason"] as? String == "error"
      { failure = data["message"] as? String ?? "Playback failed" }
    }
    _ = try await session.open(uri: url.path, headers: [:], start: 0, autoplay: true, isLive: false)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !rendered && failure == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertNil(failure)
    XCTAssertTrue(rendered, "No actual rendered-frame event before the deadline")
    XCTAssertEqual(session.stats()["audioDelivery"] as? String, "noAudioInSource")
    if software { XCTAssertEqual(session.stats()["videoRoute"] as? String, "software") }
    session.pause()
    try await session.seek(1)
    XCTAssertEqual(Double(session.property("time-pos") ?? "") ?? -1, 1, accuracy: 0.3)
    session.stop()
    session.close()
    XCTAssertNil(session.view.superview)
  }

  @MainActor
  private func writeVideo(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 160, AVVideoHeightKey: 90,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
      ]
    )
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? NativePlaybackError.unavailable
    }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<90 {
      while !input.isReadyForMoreMediaData {
        guard writer.status == .writing else {
          throw writer.error ?? NativePlaybackError.unavailable
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      var buffer: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
      guard status == kCVReturnSuccess, let buffer else {
        throw NativePlaybackError.invalidArgument("smoke pixel buffer \(status)")
      }
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(CVPixelBufferGetBaseAddress(buffer), Int32(32 + frame), CVPixelBufferGetDataSize(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
        throw writer.error ?? NativePlaybackError.unavailable
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw writer.error ?? NativePlaybackError.unavailable
    }
  }
}
