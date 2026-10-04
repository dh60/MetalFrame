import Foundation
import AppKit
import SwiftUI
import MetalKit
import AVFoundation

@main
struct LoopRegression {
    static func fixture(_ ext: String) -> URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("loop.\(ext)")
    }

    static func check(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    @MainActor
    static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    static func native(_ name: String = "loop") async throws {
        let engine = try PlaybackEngine(demuxer: MKVDemuxer(url: fixture("mkv").deletingLastPathComponent().appendingPathComponent("\(name).mkv")))
        var ended = false
        engine.onEnded = { ended = true }
        engine.setLooping(true)
        engine.start(playing: true)
        var lastPTS: Int64 = -1
        var lastHost = 0.0
        var maxGap = 0.0
        var frames = 0
        let deadline = CACurrentMediaTime() + 4.5
        while CACurrentMediaTime() < deadline {
            let host = CACurrentMediaTime()
            if let frame = engine.pullFrame(atMediaTimeNs: engine.mediaTimeNs(forHostSeconds: host)) {
                check(frame.ptsNs > lastPTS, "native loop timestamps went backwards")
                if lastHost > 0 { maxGap = max(maxGap, host - lastHost) }
                lastHost = host
                lastPTS = frame.ptsNs
                frames += 1
            }
            await wait(0.004)
        }
        check(!ended && engine.isPlaying && lastPTS > 3_500_000_000, "native playback stopped at EOF")
        check(maxGap < 0.15, "native loop stalled: \(maxGap)s")
        check(engine.currentTimeSeconds() < 1.1, "native progress did not wrap")
        engine.setPlaying(false)
        await wait(0.05)
        let paused = engine.currentTimeSeconds()
        await wait(0.15)
        check(abs(engine.currentTimeSeconds() - paused) < 0.02, "native pause failed")
        await withCheckedContinuation { continuation in
            engine.seek(toSeconds: 0.4) { continuation.resume() }
        }
        check(!engine.isPlaying && abs(engine.currentTimeSeconds() - 0.4) < 0.08, "native paused seek failed")
        engine.setLooping(false)
        engine.setPlaying(true)
        let endDeadline = CACurrentMediaTime() + 3
        while !ended && CACurrentMediaTime() < endDeadline {
            _ = engine.pullFrame(atMediaTimeNs: engine.mediaTimeNs(forHostSeconds: CACurrentMediaTime()))
            await wait(0.004)
        }
        check(ended, "disabling native looping did not stop at EOF")
        engine.shutdown()
        print("PASS native \(name): \(frames) frames over four loops, max frame gap \(String(format: "%.1f", maxGap * 1000)) ms; pause, seek, loop off")
    }

    @MainActor
    static func avPlayer() async {
        let renderer = Renderer()
        let url = fixture("mp4")
        renderer.playlist.replace(with: [url])
        renderer.playlist.loopMode = .current
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), device: MTLCreateSystemDefaultDevice())
        renderer.setupVideoPipeline(url: url, view: view)
        renderer.startProducers()
        var previous: AVPlayerItem?
        var passes = 0
        var frames = 0
        var lastFrameHost = 0.0
        var maxGap = 0.0
        let deadline = CACurrentMediaTime() + 5
        while CACurrentMediaTime() < deadline {
            if let item = renderer.player?.currentItem {
                if previous !== item { passes += 1; previous = item }
                if let output = item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first {
                    let host = CACurrentMediaTime()
                    let t = output.itemTime(forHostTime: host)
                    if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil {
                        if lastFrameHost > 0 { maxGap = max(maxGap, host - lastFrameHost) }
                        lastFrameHost = host
                        frames += 1
                    }
                }
            }
            await wait(0.004)
        }
        check(passes >= 4 && frames > 90 && (renderer.player?.rate ?? 0) > 0, "AVPlayer stopped looping")
        check(maxGap < 0.15, "AVPlayer loop stalled: \(maxGap)s")
        renderer.togglePlayback()
        await wait(0.1)
        check(renderer.player?.rate == 0, "AVPlayer pause failed")
        renderer.seek(to: 0.4)
        await wait(0.3)
        check(!renderer.isSeeking && renderer.player?.rate == 0, "AVPlayer paused seek failed")
        renderer.playlist.loopMode = .off
        renderer.updateLooping()
        check((renderer.player as? AVQueuePlayer)?.items().count == 1, "AVPlayer kept queued loops after loop off")
        renderer.togglePlayback()
        await wait(1.1)
        check(renderer.player?.rate == 0 && renderer.currentTime < 0.1 && !renderer.isSeeking, "AVPlayer off did not reset and pause")
        // One-file playlist uses the same prebuffering path.
        renderer.playlist.loopMode = .playlist
        renderer.updateLooping()
        renderer.togglePlayback()
        await wait(2.5)
        check((renderer.player?.rate ?? 0) > 0, "one-file playlist stopped")
        // Exercise the EOF fallback without a queued successor: replay must
        // resume after the zero seek completes, rather than play at EOF first.
        renderer.playlist.loopMode = .off
        renderer.updateLooping()
        renderer.player?.pause()
        renderer.seek(to: 0.85)
        await wait(0.2)
        renderer.playlist.loopMode = .current
        renderer.player?.play()
        await wait(0.7)
        check((renderer.player?.rate ?? 0) > 0 && !renderer.isSeeking,
              "EOF fallback stayed paused after seeking to zero")
        renderer.player?.pause()
        renderer.displayLink?.invalidate()
        renderer.setPlaybackActivity(false)
        print("PASS AVPlayer: \(passes) passes, \(frames) frames, max frame gap \(String(format: "%.1f", maxGap * 1000)) ms; pause, seek, loop off, one-file playlist")
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        try await native()
        try await native("loop-dts")
        await avPlayer()
    }
}
