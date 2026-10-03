import Foundation
import CoreMedia

@main
enum PlaybackRegression {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func uint(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    static func element(_ id: UInt32, _ payload: Data) -> Data {
        var bytes = withUnsafeBytes(of: id.bigEndian) { Data($0) }
        while bytes.first == 0 { bytes.removeFirst() }
        var length = 1
        while payload.count >= (1 << (7 * length)) - 1 { length += 1 }
        let size = UInt64(payload.count) | (1 << (7 * length))
        return bytes + uint(size).suffix(length) + payload
    }

    static func cue(_ ms: UInt64, _ positions: [(UInt64, UInt64)]) -> Data {
        element(0xBB, element(0xB3, uint(ms)) + positions.reduce(Data()) {
            // Put ClusterPosition before CueTrack as well as subtitle before
            // video: neither ordering is part of the seek contract.
            $0 + element(0xB7, element(0xF1, uint($1.1)) + element(0xF7, uint($1.0)))
        })
    }

    static func checkCues() throws {
        let header = element(0x1A45DFA3, element(0x4282, Data("matroska".utf8)))
        let info = element(0x1549A966, element(0x2AD7B1, uint(1_000_000)))
        let tracks = element(0x1654AE6B, [(1, 1, "V_MPEGH/ISO/HEVC"),
                                         (2, 2, "A_DTS"), (3, 17, "S_TEXT/UTF8")].reduce(Data()) {
            $0 + element(0xAE, element(0xD7, uint(UInt64($1.0)))
                         + element(0x83, uint(UInt64($1.1)))
                         + element(0x86, Data($1.2.utf8)))
        })
        func cluster(_ ms: UInt64, key: Bool) -> Data {
            element(0x1F43B675, element(0xE7, uint(ms))
                    + element(0xA3, Data([0x81, 0, 0, key ? 0x80 : 0, 0x42])))
        }
        let first = cluster(0, key: true), middle = cluster(5_000, key: false)
        let last = cluster(10_000, key: true)
        func cues(_ offset: UInt64) -> Data {
            element(0x1C53BB6B, cue(0, [(3, offset + UInt64(first.count)), (1, offset)])
                    + cue(5_000, [(3, offset + UInt64(first.count))])
                    + cue(10_000, [(1, offset + UInt64(first.count + middle.count))]))
        }
        let offset = UInt64(info.count + tracks.count + cues(0).count)
        let file = header + element(0x18538067, info + tracks + cues(offset) + first + middle + last)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metalframe-cues-\(UUID()).mkv")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let demux = try MKVDemuxer(url: url)
        check(demux.hasCues, "video cues missing")
        for (target, expected) in [(6_000_000_000 as Int64, 0 as Int64), (11_000_000_000, 10_000_000_000)] {
            check(demux.seek(toNs: target) == expected, "seek selected a subtitle cue")
            let packet = try demux.readNextPacket()
            check(packet?.keyframe == true && packet?.ptsNs == expected, "seek did not land on video keyframe")
        }
        print("PASS mixed-track cues, including multiple tracks in one cue point")
    }

    static func checkTimeline() {
        for rate in [48_000, 44_100] {
            var timeline = DTSPCMTimeline()
            var previousEnd = CMTime.invalid
            let count = rate * 3_600 / 512
            for i in 0..<count {
                // A whole hour of millisecond-rounded packet times, including
                // rounding in either direction, must remain sample-contiguous.
                let ms = (Double(i * 512) * 1_000 / Double(rate)).rounded()
                let pts = timeline.timestamp(packetPTS: CMTime(value: Int64(ms), timescale: 1_000),
                                             sampleRate: rate, sampleCount: 512, resolutionNs: 1_000_000)
                if previousEnd.isNumeric { check(CMTimeCompare(pts, previousEnd) == 0, "PCM gap at frame \(i), rate \(rate)") }
                previousEnd = CMTimeAdd(pts, CMTime(value: 512, timescale: Int32(rate)))
            }
            check(CMTimeCompare(previousEnd, CMTime(value: Int64(count * 512), timescale: Int32(rate))) == 0,
                  "sample clock accumulated drift")
            let gap = CMTime(seconds: 3_610, preferredTimescale: Int32(rate))
            let jumped = timeline.timestamp(packetPTS: gap, sampleRate: rate, sampleCount: 512, resolutionNs: 1_000_000)
            check(CMTimeCompare(jumped, gap) == 0, "real discontinuity was hidden")
            timeline.reset()
            let reset = timeline.timestamp(packetPTS: .zero, sampleRate: rate, sampleCount: 512, resolutionNs: 1_000_000)
            check(CMTimeCompare(reset, .zero) == 0, "seek reused old sample clock")
        }
        var timeline = DTSPCMTimeline()
        _ = timeline.timestamp(packetPTS: .zero, sampleRate: 48_000, sampleCount: 512, resolutionNs: 1)
        let changed = timeline.timestamp(packetPTS: CMTime(value: 1, timescale: 1), sampleRate: 44_100,
                                         sampleCount: 512, resolutionNs: 1)
        check(changed.timescale == 44_100 && changed.seconds == 1, "rate change kept stale timing")
        print("PASS hour-long PCM timing at 48/44.1 kHz, real gaps, reset and rate changes")
    }

    static func checkMovie(_ path: String) throws {
        let demux = try MKVDemuxer(url: URL(fileURLWithPath: path))
        guard let video = demux.tracks.first(where: { $0.type == .video }),
              let audio = demux.tracks.first(where: { $0.codecID == "A_DTS" }) else {
            fatalError("real-file check expects video and DTS")
        }
        for seconds in [2_700, 2_710, 3_600, 3_610, 4_500, 4_510, 6_000, 6_010] {
            let target = Int64(seconds) * 1_000_000_000
            let landing = demux.seek(toNs: target)
            var keyPTS: Int64?
            let decoder = DTSDecoder()
            var timeline = DTSPCMTimeline()
            var end = CMTime.invalid
            var frameCount = 0, jitter = 0
            var containerEnd: Int64?
            while let packet = try demux.readNextPacket() {
                if packet.trackNumber == video.number, packet.keyframe, keyPTS == nil { keyPTS = packet.ptsNs }
                if packet.trackNumber == audio.number {
                    if let previous = containerEnd, abs(packet.ptsNs - previous) > 1_000 { jitter += 1 }
                    containerEnd = packet.ptsNs + (packet.durationNs ?? 0)
                    var offset: Int64 = 0
                    for frame in decoder.decode(packet: packet.data) {
                        let pts = timeline.timestamp(packetPTS: CMTime(value: packet.ptsNs + offset, timescale: 1_000_000_000),
                                                     sampleRate: frame.sampleRate, sampleCount: frame.samplesPerChannel,
                                                     resolutionNs: packet.timestampResolutionNs)
                        if end.isNumeric { check(CMTimeCompare(pts, end) == 0, "real-file PCM gap at \(seconds)s") }
                        end = CMTimeAdd(pts, CMTime(value: Int64(frame.samplesPerChannel), timescale: Int32(frame.sampleRate)))
                        offset += Int64(frame.samplesPerChannel) * 1_000_000_000 / Int64(frame.sampleRate)
                        frameCount += 1
                    }
                }
                if packet.ptsNs > target + 5_000_000_000 { break }
            }
            check(keyPTS != nil && keyPTS! <= target && landing <= target, "real-file seek missed preceding keyframe")
            check(frameCount > 0, "no DTS PCM decoded")
            print("PASS \(seconds)s: preceding keyframe \(Double(keyPTS!) / 1e9)s; \(frameCount) contiguous PCM frames (\(jitter) rounded block boundaries)")
        }
    }

    static func main() throws {
        try checkCues()
        checkTimeline()
        if CommandLine.arguments.count > 1 { try checkMovie(CommandLine.arguments[1]) }
    }
}
