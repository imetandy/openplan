import ApplicationServices
import Foundation
import Testing
@testable import OpenPlan

@MainActor
struct LivePositionWriterTests {
  @Test func workerFollowsLatestPositionEvenWhenMainThreadIsBusy() async {
    let source = Source()
    let firstWrite = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    let secondWrite = DispatchSemaphore(value: 0)
    let writer = LivePositionWriter(readPosition: { source.position }, write: { position in
      let count = source.record(position)
      if count == 1 {
        firstWrite.signal()
        _ = releaseWrite.wait(timeout: .now() + 2)
      } else { secondWrite.signal() }
      return .success
    })
    writer.start(framesPerSecond: 120)
    #expect(blockMainThread(until: firstWrite) == .success)
    for x in 1...10_000 { source.position = CGPoint(x: x, y: -x) }
    releaseWrite.signal()
    // Deliberately block the main thread: the second write must not need it.
    #expect(blockMainThread(until: secondWrite) == .success)
    let final = await withCheckedContinuation { continuation in
      writer.finish { continuation.resume(returning: $0) }
    }
    #expect(source.positions == [.zero, CGPoint(x: 10_000, y: -10_000)])
    #expect(final == CGPoint(x: 10_000, y: -10_000))
  }

  @Test func cancellingDuringSlowWriteDropsFurtherMoves() {
    let source = Source()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let unexpectedWrite = DispatchSemaphore(value: 0)
    let writer = LivePositionWriter(readPosition: { source.position }, write: { position in
      if source.record(position) == 1 {
        started.signal()
        _ = release.wait(timeout: .now() + 2)
      } else { unexpectedWrite.signal() }
      return .success
    })
    writer.start(framesPerSecond: 120)
    #expect(started.wait(timeout: .now() + 1) == .success)
    source.position = CGPoint(x: 100, y: 100)
    writer.cancel()
    release.signal()
    #expect(unexpectedWrite.wait(timeout: .now() + 0.05) == .timedOut)
    #expect(source.positions == [.zero])
  }

  @Test func invalidWindowStopsWorker() async {
    let source = Source()
    let writer = LivePositionWriter(readPosition: { source.position }, write: { position in
      _ = source.record(position)
      return .invalidUIElement
    })
    await withCheckedContinuation { continuation in
      writer.onInvalidWindow = { continuation.resume() }
      writer.start(framesPerSecond: 120)
    }
    #expect(source.positions == [.zero])
    writer.cancel()
  }

  @Test func finalSampleRetriesTimeoutAndUsesNewestPosition() async {
    let source = Source()
    let attempted = DispatchSemaphore(value: 0)
    let writer = LivePositionWriter(readPosition: { source.position }, write: { position in
      let count = source.record(position)
      attempted.signal()
      return count == 1 ? .cannotComplete : .success
    })
    writer.start(framesPerSecond: 120)
    #expect(blockMainThread(until: attempted) == .success)
    source.position = CGPoint(x: 42, y: 24)
    let final = await withCheckedContinuation { continuation in
      writer.finish { continuation.resume(returning: $0) }
    }
    #expect(final == CGPoint(x: 42, y: 24))
    #expect(source.positions.last == final)
  }

  // Intentional UI starvation models AppKit's native drag tracking loop.
  private func blockMainThread(until semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 1)
  }

  private final class Source: @unchecked Sendable {
    private let lock = NSLock()
    private var current = CGPoint.zero
    private var recorded: [CGPoint] = []
    var position: CGPoint {
      get { lock.lock(); defer { lock.unlock() }; return current }
      set { lock.lock(); defer { lock.unlock() }; current = newValue }
    }
    var positions: [CGPoint] {
      lock.lock(); defer { lock.unlock() }; return recorded
    }
    func record(_ position: CGPoint) -> Int {
      lock.lock(); defer { lock.unlock() }
      recorded.append(position)
      return recorded.count
    }
  }
}
