import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// The native playback engine: MKVDemuxer → VideoDecodePipeline (VideoToolbox)
// + AudioPipeline (AVSampleBufferAudioRenderer), clocked by an
// AVSampleBufferRenderSynchronizer whose timebase the audio device disciplines.
// The renderer's draw(in:) stays a pull-by-timestamp consumer, exactly like
// the AVPlayer path it replaces: it converts the display link's target host
// time to media time and takes the newest decoded frame at or before it.
//
// Threads:
//   control queue — start/seek/track-switch/shutdown (serialized)
//   demux thread  — sequential cluster reads, routes packets
//   video thread  — compressed packet queue → VT session
//   audio pump    — inside AudioPipeline (requestMediaDataWhenReady)
//   VT callbacks  — reorder heap → FrameQueue (bounded, blocking = backpressure)

// Bounded blocking queue for compressed video packets: demux → decode thread.
final class BoundedPacketQueue {
    private let condition = NSCondition()
    private var items: [MKVPacket] = []
    private var closed = false
    private var eof = false
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    // Blocks while full; false once closed.
    func push(_ item: MKVPacket) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while items.count >= capacity && !closed {
            condition.wait()
        }
        if closed { return false }
        items.append(item)
        condition.signal()
        return true
    }

    // Blocks while empty; nil once closed, or drained after EOF.
    func pop() -> MKVPacket? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !closed && !eof {
            condition.wait()
        }
        if items.isEmpty { return nil }
        let item = items.removeFirst()
        condition.signal()
        return item
    }

    func markEOF() {
        condition.lock()
        eof = true
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        items.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    func reset() {
        condition.lock()
        closed = false
        eof = false
        items.removeAll()
        condition.unlock()
    }
}

struct SubtitleCue {
    let startNs: Int64
    let endNs: Int64
    let text: String
}

final class PlaybackEngine {
    // Immutable after init.
    private let demuxer: MKVDemuxer
    let videoTrack: MKVTrack
    let audioTracks: [MKVTrack]
    let subtitleTracks: [MKVTrack]
    let durationSeconds: Double
    var usingHardwareDecode: Bool { videoPipeline.usingHardware }
    var contentFPS: Double? {
        videoTrack.defaultDurationNs.map { 1e9 / Double($0) }
    }
    var displayAspect: Double? { videoTrack.displayAspect }

    private let videoPipeline: VideoDecodePipeline
    private let audioPipeline = AudioPipeline()
    private var synchronizer: AVSampleBufferRenderSynchronizer { audioPipeline.synchronizer }

    private let controlQueue = DispatchQueue(label: "metalframe.engine.control")
    private let videoQueue = BoundedPacketQueue(capacity: 64)

    // Cross-thread state.
    private let stateLock = NSLock()
    private var selectedAudioIndexValue = -1   // index into audioTracks; -1 = none
    private var selectedAudioTrackNumber: UInt64 = 0
    private var desiredPlaying = false
    private var demuxEOF = false
    private var videoDrained = false
    private var streamEndNs = Int64.max        // max(video end, audio end) once EOF seen
    private var endFired = false
    private var shutdownRequested = false
    // True from restart() entry until the new run's setRate re-anchors the
    // timebase. pullFrame returns nil during this window — otherwise draw()
    // keeps pulling against the STALE timebase (e.g. ~EOF time) and eats the
    // new run's first frames before the clock snaps back to the seek target.
    private var restarting = false
    // After a seek, audio packets ending before this are not fed: the seek
    // cluster can start several seconds before the target, and flooding the
    // renderer with pre-target audio stalls priming (it stops accepting
    // before the target is even buffered). Video still decodes from the
    // keyframe — dropBeforeNs handles display-side accuracy.
    private var audioSkipBeforeNs = Int64.min

    // Active run (demux + decode threads). Replaced wholesale on seeks.
    private final class RunToken {
        let group = DispatchGroup()
        private let lock = NSLock()
        private var stoppedValue = false
        var stopped: Bool {
            get { lock.withLock { stoppedValue } }
            set { lock.withLock { stoppedValue = newValue } }
        }
    }
    private var currentRun: RunToken?

    // Subtitle cue store, indexed like subtitleTracks. Cleared on seeks and
    // repopulated from the demux position (packets stream in ahead of the
    // playhead, so cues exist before they're due).
    private let subtitleLock = NSLock()
    private var subtitleCues: [[SubtitleCue]]

    // Callbacks (set before start; invoked on the main queue).
    var onEnded: (() -> Void)?
    var onStatus: ((String) -> Void)?

    var selectedAudioIndex: Int { stateLock.withLock { selectedAudioIndexValue } }
    var isPlaying: Bool { synchronizer.rate > 0 }

    init(url: URL) throws {
        demuxer = try MKVDemuxer(url: url)
        guard let video = demuxer.tracks.first(where: { $0.type == .video }) else {
            throw MKVError.corrupt("no video track")
        }
        videoTrack = video
        audioTracks = demuxer.tracks.filter { $0.type == .audio }
        subtitleTracks = demuxer.tracks.filter {
            $0.type == .subtitle && ($0.codecID == "S_TEXT/UTF8" || $0.codecID == "S_TEXT/ASS"
                                     || $0.codecID == "S_TEXT/SSA" || $0.codecID == "S_TEXT/SRT")
        }
        durationSeconds = demuxer.durationSeconds ?? 0
        subtitleCues = Array(repeating: [], count: subtitleTracks.count)
        videoPipeline = try VideoDecodePipeline(track: video)
    }

    // MARK: - Public control surface

    func start(playing: Bool) {
        stateLock.withLock { desiredPlaying = playing }
        controlQueue.async { [self] in
            let status = selectInitialAudioTrack()
            if let status {
                DispatchQueue.main.async { self.onStatus?(status) }
            }
            launchRun(fromNs: 0, initialStart: true)
        }
    }

    // Returns the new playing state immediately; the rate change is applied
    // directly (the synchronizer is thread-safe for rate).
    func togglePlayPause() -> Bool {
        let playing = stateLock.withLock {
            desiredPlaying.toggle()
            return desiredPlaying
        }
        synchronizer.rate = playing ? 1 : 0
        return playing
    }

    func setPlaying(_ playing: Bool) {
        stateLock.withLock { desiredPlaying = playing }
        synchronizer.rate = playing ? 1 : 0
    }

    func seek(toSeconds target: Double, completion: (() -> Void)? = nil) {
        let clampedNs = Int64(max(0, min(target, durationSeconds)) * 1e9)
        controlQueue.async { [self] in
            restart(atNs: clampedNs, reconfigureAudio: nil)
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // Cycle to the next audio track (mirrors the subtitle-cycling UX).
    // Returns the status label for the overlay immediately.
    func cycleAudioTrack() -> String {
        guard !audioTracks.isEmpty else { return "Audio: None" }
        let (nextIndex, label) = stateLock.withLock { () -> (Int, String) in
            let next = (selectedAudioIndexValue + 1) % audioTracks.count
            return (next, audioTrackLabel(index: next))
        }
        controlQueue.async { [self] in
            let nowNs = currentTimeNs()
            restart(atNs: nowNs, reconfigureAudio: nextIndex)
        }
        return label
    }

    func audioTrackLabel(index: Int) -> String {
        guard index >= 0, index < audioTracks.count else { return "Audio: None" }
        let t = audioTracks[index]
        var label = "Audio: \(t.language) \(audioCodecLabel(t.codecID)) \(t.channels)ch"
        if !isPassthroughAudioCodec(t.codecID) {
            label += " — not decodable yet (silent)"
        }
        if audioTracks.count > 1 {
            label = "Audio \(index + 1)/\(audioTracks.count): " + label.dropFirst("Audio: ".count)
        }
        return label
    }

    func shutdown() {
        stateLock.withLock { shutdownRequested = true }
        controlQueue.sync { [self] in
            synchronizer.rate = 0
            stopRun()
            audioPipeline.shutdown()
        }
    }

    // MARK: - Renderer-facing pull surface (main/render thread)

    // Display-link target host time → media time on the synchronizer timebase.
    func mediaTimeNs(forHostSeconds host: Double) -> Int64 {
        let hostTime = CMTime(seconds: host, preferredTimescale: 1_000_000_000)
        let media = CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: synchronizer.timebase)
        guard media.isNumeric else { return 0 }
        return media.convertScale(1_000_000_000, method: .default).value
    }

    func currentTimeSeconds() -> Double {
        let t = CMTimebaseGetTime(synchronizer.timebase)
        return t.isNumeric ? t.seconds : 0
    }

    private func currentTimeNs() -> Int64 {
        Int64(currentTimeSeconds() * 1e9)
    }

    // Newest decoded frame due at or before the given media time. Nil means
    // keep showing the previous frame.
    func pullFrame(atMediaTimeNs t: Int64) -> DecodedFrame? {
        if stateLock.withLock({ restarting }) { return nil }
        let frame = videoPipeline.frameQueue.take(atOrBefore: t)
        checkForEnd(mediaTimeNs: t)
        return frame
    }

    // All cues active at the given time on the given subtitle track.
    func subtitleText(atMediaTimeNs t: Int64, trackIndex: Int) -> String {
        guard trackIndex >= 0 else { return "" }
        subtitleLock.lock()
        defer { subtitleLock.unlock() }
        guard trackIndex < subtitleCues.count else { return "" }
        let active = subtitleCues[trackIndex].filter { $0.startNs <= t && t < $0.endNs }
        return active.map(\.text).joined(separator: "\n")
    }

    // MARK: - Run lifecycle (control queue only)

    private func selectInitialAudioTrack() -> String? {
        guard !audioTracks.isEmpty else { return nil }
        // Default = first FlagDefault track; fall forward to the first track
        // we can actually decode, surfacing the substitution.
        let preferredIndex = audioTracks.firstIndex(where: { $0.flagDefault }) ?? 0
        var chosen = preferredIndex
        var note: String?
        if !isPassthroughAudioCodec(audioTracks[preferredIndex].codecID) {
            if let fallback = audioTracks.firstIndex(where: { isPassthroughAudioCodec($0.codecID) }) {
                chosen = fallback
                let skipped = audioCodecLabel(audioTracks[preferredIndex].codecID)
                note = "Audio: \(skipped) not decodable yet — using \(audioTrackLabel(index: fallback).dropFirst("Audio: ".count))"
            } else {
                let codec = audioCodecLabel(audioTracks[preferredIndex].codecID)
                note = "Audio: \(codec) decoder coming in a later phase — playing silent"
            }
        }
        applyAudioSelection(index: chosen)
        return note
    }

    private func applyAudioSelection(index: Int) {
        let track = (index >= 0 && index < audioTracks.count) ? audioTracks[index] : nil
        if let track, isPassthroughAudioCodec(track.codecID), (try? audioPipeline.configure(track: track)) != nil {
            stateLock.withLock {
                selectedAudioIndexValue = index
                selectedAudioTrackNumber = track.number
            }
        } else {
            stateLock.withLock {
                selectedAudioIndexValue = index      // may point at a not-yet-decodable track
                selectedAudioTrackNumber = 0         // 0 = feed nothing
            }
        }
    }

    private func restart(atNs targetNs: Int64, reconfigureAudio: Int?) {
        let wasPlaying = stateLock.withLock { () -> Bool in
            restarting = true
            return desiredPlaying
        }
        synchronizer.rate = 0
        stopRun()
        videoPipeline.flush()
        audioPipeline.flush()
        if let index = reconfigureAudio {
            applyAudioSelection(index: index)
            if index >= 0, index < audioTracks.count,
               !isPassthroughAudioCodec(audioTracks[index].codecID) {
                let label = audioTrackLabel(index: index)
                DispatchQueue.main.async { self.onStatus?(label) }
            }
        }
        subtitleLock.withLock {
            subtitleCues = Array(repeating: [], count: subtitleTracks.count)
        }
        demuxer.seek(toNs: targetNs)
        let preRoll = stateLock.withLock { () -> Int64 in
            let idx = selectedAudioIndexValue
            guard idx >= 0, idx < audioTracks.count else { return 0 }
            return max(Int64(audioTracks[idx].seekPreRollNs), 0)
        }
        stateLock.withLock {
            demuxEOF = false
            videoDrained = false
            streamEndNs = Int64.max
            endFired = false
            desiredPlaying = wasPlaying
            audioSkipBeforeNs = targetNs - preRoll
        }
        launchRun(fromNs: targetNs, initialStart: false)
    }

    private func stopRun() {
        guard let run = currentRun else { return }
        run.stopped = true
        videoQueue.close()
        videoPipeline.frameQueue.beginFlush()   // release producers blocked on a full queue
        audioPipeline.flush()                    // release demux thread blocked on the audio FIFO
        run.group.wait()
        currentRun = nil
    }

    private func launchRun(fromNs startNs: Int64, initialStart: Bool) {
        let run = RunToken()
        currentRun = run
        videoQueue.reset()
        audioPipeline.reopen()
        videoPipeline.frameQueue.endFlush()
        // Frame-accurate seek: decode from the keyframe, surface only frames
        // that still cover the target.
        videoPipeline.dropBeforeNs = initialStart ? Int64.min : startNs

        run.group.enter()
        Thread.detachNewThread { [self] in
            demuxLoop(run: run)
            run.group.leave()
        }
        run.group.enter()
        Thread.detachNewThread { [self] in
            videoDecodeLoop(run: run)
            run.group.leave()
        }

        // Prime: first video frame decoded and ~200 ms of audio enqueued
        // (or audio EOF) before the clock starts — the A/V start alignment.
        let audioActive = stateLock.withLock { selectedAudioTrackNumber != 0 }
        let deadline = Date(timeIntervalSinceNow: 3.0)
        while Date() < deadline {
            if run.stopped { return }
            let videoReady = !videoPipeline.frameQueue.isEmpty
            let audioReady = !audioActive
                || audioPipeline.lastEnqueuedEndNs >= startNs + 200_000_000
                || audioPipeline.isEOFDrained
            let videoDone = stateLock.withLock { videoDrained }
            if (videoReady || videoDone) && audioReady { break }
            usleep(10_000)
        }
        let playing = stateLock.withLock { desiredPlaying }
        synchronizer.setRate(playing ? 1 : 0, time: CMTime(value: startNs, timescale: 1_000_000_000))
        stateLock.withLock { restarting = false }
    }

    // MARK: - Worker loops

    private func demuxLoop(run: RunToken) {
        var maxVideoEndNs: Int64 = 0
        var maxAudioEndNs: Int64 = 0
        while !run.stopped {
            let packet: MKVPacket?
            do {
                packet = try demuxer.readNextPacket()
            } catch {
                // A corrupt tail shouldn't kill playback of what we have.
                NSLog("MetalFrame demux error: %@", "\(error)")
                packet = nil
            }
            guard let packet else {
                stateLock.withLock {
                    demuxEOF = true
                    streamEndNs = max(maxVideoEndNs, maxAudioEndNs)
                }
                videoQueue.markEOF()
                audioPipeline.markEOF()
                return
            }
            guard let track = demuxer.track(number: packet.trackNumber) else { continue }
            switch track.type {
            case .video where track.number == videoTrack.number:
                maxVideoEndNs = max(maxVideoEndNs, packet.ptsNs + (packet.durationNs ?? 0))
                if !videoQueue.push(packet) { return }
            case .audio:
                let (selected, skipBefore) = stateLock.withLock { (selectedAudioTrackNumber, audioSkipBeforeNs) }
                if track.number == selected {
                    let endNs = packet.ptsNs + (packet.durationNs ?? 0)
                    maxAudioEndNs = max(maxAudioEndNs, endNs)
                    if endNs >= skipBefore {
                        audioPipeline.enqueue(packet)
                    }
                }
            case .subtitle:
                handleSubtitlePacket(packet, track: track)
            default:
                break
            }
        }
    }

    private func videoDecodeLoop(run: RunToken) {
        while !run.stopped, let packet = videoQueue.pop() {
            videoPipeline.decode(packet)
        }
        if !run.stopped {
            // EOF: drain in-flight VT frames + the reorder tail.
            videoPipeline.finish()
            stateLock.withLock { videoDrained = true }
        }
    }

    // MARK: - Subtitles

    private func handleSubtitlePacket(_ packet: MKVPacket, track: MKVTrack) {
        guard let index = subtitleTracks.firstIndex(where: { $0.number == track.number }) else { return }
        guard let raw = String(data: packet.data, encoding: .utf8), !raw.isEmpty else { return }
        let durationNs = packet.durationNs ?? 3_000_000_000
        let text: String
        if track.codecID == "S_TEXT/ASS" || track.codecID == "S_TEXT/SSA" {
            text = Self.parseASSDialogue(raw)
        } else {
            text = Self.stripAngleTags(raw)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cue = SubtitleCue(startNs: packet.ptsNs, endNs: packet.ptsNs + durationNs, text: trimmed)
        subtitleLock.withLock {
            subtitleCues[index].append(cue)
            // Keep memory bounded on very long streams.
            if subtitleCues[index].count > 4096 {
                subtitleCues[index].removeFirst(1024)
            }
        }
    }

    // MKV ASS block payload: "ReadOrder,Layer,Style,Name,MarginL,MarginR,
    // MarginV,Effect,Text" — text is the 9th field and may itself contain
    // commas. Strip {\...} override tags; \N and \n are line breaks, \h is a
    // non-breaking space.
    static func parseASSDialogue(_ payload: String) -> String {
        let fields = payload.split(separator: ",", maxSplits: 8,
                                   omittingEmptySubsequences: false)
        guard fields.count == 9 else { return payload }
        var text = String(fields[8])
        while let open = text.range(of: "{\\"), let close = text.range(of: "}", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(of: "\\h", with: "\u{00A0}")
        return text
    }

    // SRT-in-MKV cue text is plain UTF-8, but tags like <i> ride along.
    static func stripAngleTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
    }

    // MARK: - EOF

    private func checkForEnd(mediaTimeNs t: Int64) {
        let shouldFire: Bool = stateLock.withLock {
            guard demuxEOF, videoDrained, !endFired, desiredPlaying else { return false }
            guard videoPipeline.frameQueue.isEmpty else { return false }
            guard audioPipeline.isEOFDrained || selectedAudioTrackNumber == 0 else { return false }
            guard streamEndNs != Int64.max, t >= streamEndNs else { return false }
            endFired = true
            return true
        }
        if shouldFire {
            DispatchQueue.main.async { self.onEnded?() }
        }
    }
}
