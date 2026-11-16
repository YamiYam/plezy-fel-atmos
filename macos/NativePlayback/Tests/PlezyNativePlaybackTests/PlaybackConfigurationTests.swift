import AetherEngine
import XCTest
@testable import PlezyNativePlayback

@available(macOS 26, *)
final class PlaybackConfigurationTests: XCTestCase {
  func testFELAndObjectAudioAreRequestedTogetherWithoutCurveApproximation() {
    let options = NativePlaybackConfiguration().options(headers: ["X-Test": "test"], autoplay: false)
    XCTAssertTrue(options.preferDualLayerDolbyVision)
    XCTAssertFalse(options.foldsDolbyVisionFEL)
    XCTAssertEqual(options.objectAudioRendering, .apac(.l714))
    XCTAssertEqual(options.httpHeaders, ["X-Test": "test"])
    XCTAssertFalse(options.autoplay)
    XCTAssertTrue(AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn)
    XCTAssertTrue(AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn)
  }

  func testSoftwareDecodeDisablesDualLayerHardwareRoute() {
    var configuration = NativePlaybackConfiguration()
    configuration.hardwareDecoding = false
    let options = configuration.options(headers: [:], autoplay: true)
    XCTAssertFalse(options.preferDualLayerDolbyVision)
    XCTAssertEqual(options.preferredDecodePath, .software)
    XCTAssertEqual(options.objectAudioRendering, .apac(.l714))
  }

  func testMediaURIValidationPreservesEscapedPathsAndRejectsOtherProtocols() throws {
    XCTAssertEqual(
      try PlaybackSession.mediaURL("/tmp/a movie.mkv"),
      URL(fileURLWithPath: "/tmp/a movie.mkv")
    )
    XCTAssertEqual(
      try PlaybackSession.mediaURL("https://example.org/movie.mkv?key=a%20b").query,
      "key=a%20b"
    )
    XCTAssertThrowsError(try PlaybackSession.mediaURL("ftp://example.org/movie.mkv"))
    XCTAssertThrowsError(try PlaybackSession.flag("maybe"))
  }

  func testDolbyVisionDiagnosticsRequireComposedFramesAndResetForNextSource() {
    let diagnostics = DolbyVisionDiagnostics()
    diagnostics.record("[AetherEngine] #361 startup 0/8 dispatched (gen 1)")
    diagnostics.record("[AetherEngine] DV P7 dual-layer route: taken (el_type=FEL, 3840x2160@23.976, budget 80%)")
    XCTAssertEqual(diagnostics.snapshot().enhancementLayer, "FEL")
    XCTAssertFalse(diagnostics.snapshot().felActive)
    diagnostics.record("[DualLayerVideoDecoder] totals: composed=240, bypassDeadline=0, bypassHeldWall=0, bypassBackstop=0")
    XCTAssertTrue(diagnostics.snapshot().felActive)
    diagnostics.record("[AetherEngine] #361 startup 0/8 dispatched (gen 2)")
    XCTAssertNil(diagnostics.snapshot().enhancementLayer)
    diagnostics.record("[DualLayerVideoDecoder] totals: composed=241, bypassDeadline=0")
    XCTAssertFalse(diagnostics.snapshot().felActive)
    diagnostics.record("[AetherEngine] DV P7 dual-layer route: not taken (el_type=MEL, nothing to compose), keeps the native route (8.1 where the display takes Dolby Vision)")
    XCTAssertEqual(diagnostics.snapshot().enhancementLayer, "MEL")
    XCTAssertEqual(diagnostics.snapshot().composedFrames, 0)
    diagnostics.reset()
    diagnostics.record("[DualLayerVideoDecoder] totals: composed=500, bypassDeadline=0")
    XCTAssertNil(diagnostics.snapshot().enhancementLayer)
    XCTAssertFalse(diagnostics.snapshot().felActive)
  }

  func testUnclassifiedAndStalledCompositionDoNotClaimActiveFEL() {
    let diagnostics = DolbyVisionDiagnostics()
    diagnostics.record("[AetherEngine] #361 startup 0/8 dispatched (gen 1)")
    diagnostics.record("[AetherEngine] DV P7 dual-layer route: not taken (el_type unknown, no enhancement layer classified in the first RPU)")
    XCTAssertNil(diagnostics.snapshot().enhancementLayer)
    diagnostics.record("[AetherEngine] DV P7 dual-layer route: taken (el_type=FEL, 3840x2160@23.976, budget 80%)")
    diagnostics.record("[DualLayerVideoDecoder] totals: composed=240, bypassDeadline=0")
    diagnostics.record("[DualLayerVideoDecoder] compose stalled: no GPU slot; sending frames as the base layer")
    XCTAssertFalse(diagnostics.snapshot().felActive)
    diagnostics.record("[DualLayerVideoDecoder] compose resumed after 20 base-layer frames")
    XCTAssertTrue(diagnostics.snapshot().felActive)
    diagnostics.record("[DualLayerVideoDecoder] No composer available; FEL composition disabled")
    XCTAssertFalse(diagnostics.snapshot().felActive)
  }
}
