import Foundation

// The pinned engine exposes its profile publicly, but MEL/FEL and composition counters only in diagnostics.
final class DolbyVisionDiagnostics: @unchecked Sendable {
  struct Snapshot {
    var enhancementLayer: String?
    var felSelected = false
    var composedFrames = 0
    var compositionBlocked = false

    var felActive: Bool { felSelected && composedFrames > 0 && !compositionBlocked }
  }

  private let lock = NSLock()
  private var state = Snapshot()
  private var accepting = false

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    state = Snapshot()
    accepting = false
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  func record(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    if line.hasPrefix("[AetherEngine] #361 startup 0/8 dispatched") {
      state = Snapshot()
      accepting = true
      return
    }
    guard accepting else { return }
    if line.hasPrefix("[AetherEngine] DV P7 dual-layer route:") {
      state = Snapshot()
      if line.contains("el_type=FEL") { state.enhancementLayer = "FEL" }
      if line.contains("el_type=MEL") { state.enhancementLayer = "MEL" }
      state.felSelected = state.enhancementLayer == "FEL"
        && line.hasPrefix("[AetherEngine] DV P7 dual-layer route: taken ")
      return
    }
    guard state.felSelected, line.hasPrefix("[DualLayerVideoDecoder] ") else { return }
    let totalsPrefix = "[DualLayerVideoDecoder] totals: composed="
    if line.hasPrefix(totalsPrefix),
      let count = Int(line.dropFirst(totalsPrefix.count).prefix(while: { $0.isNumber }))
    {
      state.composedFrames = count
    } else if line.contains("compose stalled") || line.contains("FEL composition disabled")
      || line.contains("failed to initialize EL decoder")
    {
      state.compositionBlocked = true
    } else if line.contains("compose resumed after") {
      state.compositionBlocked = false
    }
  }
}
