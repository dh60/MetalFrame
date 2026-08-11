import Foundation
import AVFoundation
import CoreMedia

// ISO-BMFF (MP4/MOV) front-end for the playback engine.
//
// Used when AVFoundation can demux a file but refuses to DECODE its video
// track. The classic case is WEB-DL HEVC tagged 'hev1' (in-band parameter
// sets allowed) instead of 'hvc1': AVPlayer rejects the track by sample-entry
// fourcc even when the stream also carries a normal out-of-band hvcC that
// VideoToolbox decodes fine. AVAssetReader in passthrough mode hands over the
// raw samples regardless, so: demux with AVAssetReader, rebuild the format
// description from the hvcC sample entry (the exact path VideoDecodePipeline
// already takes for MKV CodecPrivate), and feed the engine's normal pipelines.
//
// Sample data needs no re-framing: MP4 samples and MKV block payloads are
// both length-prefixed NAL units for AVC/HEVC, and raw syncframes for Dolby
// audio. Tracks and packets are translated into the engine's MKV structs.
//
// Seek contract (verified empirically on a 4K WEB-DL): a passthrough reader
// whose timeRange starts mid-GOP emits a zero-length marker sample at the
// requested time, then delivers from the sync sample at or before it, in
// decode order — the same contract the engine's cue-based MKV seeks provide,
// so dropBeforeNs frame accuracy and snap-to-first-frame apply unchanged.

final class MP4Demuxer: MediaDemuxer {
    private struct Stream {
        var track: MKVTrack
        let avTrack: AVAssetTrack
        let isTimedText: Bool          // tx3g/QT-text sample → plain-text cue
        var output: AVAssetReaderTrackOutput?
        var pending: [(key: Int64, packet: MKVPacket)] = []
        var finished = true
    }

    private let asset: AVAsset
    private var streams: [Stream] = []
    private var reader: AVAssetReader?
    private var readerOpened = false

    private(set) var tracks: [MKVTrack] = []
    private(set) var durationSeconds: Double?
    let hasCues = true                 // the sample tables give full random access
    let containerLabel = "MP4"

    init(asset: AVAsset) async throws {
        self.asset = asset
        durationSeconds = try await asset.load(.duration).seconds

        var number: UInt64 = 0
        for avTrack in try await asset.load(.tracks) {
            let (fds, naturalSize, fps, language, enabled) = try await avTrack.load(
                .formatDescriptions, .naturalSize, .nominalFrameRate, .languageCode, .isEnabled)
            guard let fd = fds.first else { continue }
            guard var track = Self.makeTrack(formatDescription: fd) else { continue }
            number += 1
            track.number = number
            track.language = language ?? "und"
            track.flagDefault = enabled
            if track.type == .video {
                if naturalSize.width > 0, naturalSize.height > 0 {
                    track.displayWidth = Int(naturalSize.width.rounded())
                    track.displayHeight = Int(naturalSize.height.rounded())
                }
                if fps > 0 {
                    track.defaultDurationNs = UInt64((1e9 / Double(fps)).rounded())
                }
            }
            streams.append(Stream(track: track, avTrack: avTrack,
                                  isTimedText: track.type == .subtitle))
        }
        guard streams.contains(where: { $0.track.type == .video }) else {
            throw MKVError.corrupt("no video track this engine can decode")
        }
        tracks = streams.map(\.track)
    }

    deinit {
        reader?.cancelReading()
    }

    // MARK: - Track translation

    // Map a CMFormatDescription onto the engine's MKV track vocabulary.
    // Returns nil for tracks the engine has no use for (timecode, metadata,
    // codecs with no engine path) — video because init fails without one,
    // audio/subtitle silently (matching MKV behavior for unknown codecs).
    private static func makeTrack(formatDescription fd: CMFormatDescription) -> MKVTrack? {
        let subtype = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
        var track = MKVTrack()

        switch CMFormatDescriptionGetMediaType(fd) {
        case kCMMediaType_Video:
            let atomKey: String
            switch subtype {
            case "hvc1", "hev1", "dvh1", "dvhe":
                track.codecID = "V_MPEGH/ISO/HEVC"; atomKey = "hvcC"
            case "avc1", "avc3", "dva1", "dvav":
                track.codecID = "V_MPEG4/ISO/AVC"; atomKey = "avcC"
            case "av01":
                track.codecID = "V_AV1"; atomKey = "av1C"
            default:
                return nil
            }
            // The decode config atom doubles as MKV CodecPrivate — identical
            // byte layout. Without it (in-band-only parameter sets) we can't
            // build a format description, so the track is unusable.
            guard let atoms = CMFormatDescriptionGetExtension(
                    fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                    as? [String: Any],
                  let priv = atoms[atomKey] as? Data, !priv.isEmpty else {
                return nil
            }
            track.type = .video
            track.codecPrivate = priv
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            track.pixelWidth = Int(dims.width)
            track.pixelHeight = Int(dims.height)
            // No MKVColour: makeVideoFormatDescription falls back to the VUI
            // in the parameter sets, which carries the colorimetry here.
            return track

        case kCMMediaType_Audio:
            switch subtype {
            case "ec-3", "ec+3":
                track.codecID = "A_EAC3"
            case "ac-3":
                track.codecID = "A_AC3"
            case let s where s.hasPrefix("aac"):
                track.codecID = "A_AAC"
                track.codecPrivate = aacAudioSpecificConfig(from: fd)
            case "fLaC":
                // dfLa = version/flags(4) + METADATA_BLOCKs; prepending the
                // magic reproduces the MKV CodecPrivate shape byte-for-byte.
                if let atoms = CMFormatDescriptionGetExtension(
                        fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                        as? [String: Any],
                   let dfLa = atoms["dfLa"] as? Data, dfLa.count >= 42 {
                    track.codecID = "A_FLAC"
                    track.codecPrivate = Data("fLaC".utf8) + dfLa.dropFirst(4)
                } else {
                    track.codecID = "A_MP4/fLaC"   // label-only: plays silent
                }
            default:
                track.codecID = "A_MP4/\(subtype)" // label-only: plays silent
            }
            track.type = .audio
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                track.sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
                track.channels = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : 2
            } else {
                track.sampleRate = 48000
                track.channels = 2
            }
            return track

        default:
            // 3GPP timed text ('sbtl'/tx3g) and QT text: payload converts to a
            // plain UTF-8 cue in makePacket, so downstream it is MKV SRT.
            guard subtype == "tx3g" || subtype == "text" else { return nil }
            track.type = .subtitle
            track.codecID = "S_TEXT/UTF8"
            return track
        }
    }

    // MARK: - MediaDemuxer

    func track(number: UInt64) -> MKVTrack? {
        streams.first(where: { $0.track.number == number })?.track
    }

    func seek(toNs target: Int64) -> Int64 {
        let clamped = max(0, target)
        readerOpened = true
        openReader(atNs: clamped)
        return clamped
    }

    func readNextPacket() throws -> MKVPacket? {
        if !readerOpened {
            readerOpened = true
            openReader(atNs: 0)
        }
        // One pending queue per track; emit the packet earliest in decode
        // order across tracks (≈ file interleave order).
        var best = -1
        var bestKey = Int64.max
        for i in streams.indices {
            if streams[i].pending.isEmpty { refill(streamIndex: i) }
            if let head = streams[i].pending.first, head.key < bestKey {
                bestKey = head.key
                best = i
            }
        }
        guard best >= 0 else {
            if let reader, reader.status == .failed {
                throw MKVError.io("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
            }
            return nil
        }
        return streams[best].pending.removeFirst().packet
    }

    // MARK: - Reader lifecycle

    // (Re)build the reader positioned at targetNs. AVAssetReader and its
    // outputs are one-shot objects — a seek means fresh instances. On failure
    // every stream is left finished, so readNextPacket reports EOF and the
    // engine winds down cleanly rather than spinning.
    private func openReader(atNs targetNs: Int64) {
        reader?.cancelReading()
        reader = nil
        for i in streams.indices {
            streams[i].output = nil
            streams[i].pending.removeAll()
            streams[i].finished = true
        }
        do {
            let newReader = try AVAssetReader(asset: asset)
            if targetNs > 0 {
                newReader.timeRange = CMTimeRange(
                    start: CMTime(value: targetNs, timescale: 1_000_000_000),
                    end: .positiveInfinity)
            }
            for i in streams.indices {
                let output = AVAssetReaderTrackOutput(track: streams[i].avTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false   // we copy into packet Data ourselves
                guard newReader.canAdd(output) else {
                    throw MKVError.io("AVAssetReader rejected track \(streams[i].track.number)")
                }
                newReader.add(output)
                streams[i].output = output
                streams[i].finished = false
            }
            guard newReader.startReading() else {
                throw MKVError.io("AVAssetReader start failed: \(newReader.error?.localizedDescription ?? "unknown")")
            }
            reader = newReader
        } catch {
            NSLog("MetalFrame MP4Demuxer: %@", "\(error)")
            reader = nil
            for i in streams.indices {
                streams[i].output = nil
                streams[i].finished = true
            }
        }
    }

    private func refill(streamIndex i: Int) {
        guard !streams[i].finished, let output = streams[i].output else { return }
        // Loop past zero-length seek markers and empty text cues.
        while streams[i].pending.isEmpty {
            guard let sb = output.copyNextSampleBuffer() else {
                streams[i].finished = true
                return
            }
            streams[i].pending = packets(from: sb, streamIndex: i)
        }
    }

    // MARK: - Sample → packet conversion

    private func packets(from sb: CMSampleBuffer, streamIndex i: Int) -> [(key: Int64, packet: MKVPacket)] {
        let totalSize = CMSampleBufferGetTotalSampleSize(sb)
        guard totalSize > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sb) else {
            return []   // zero-length marker at a seek target
        }
        var data = Data(count: totalSize)
        let copyStatus = data.withUnsafeMutableBytes { buf in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalSize,
                                       destination: buf.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return [] }

        let sampleCount = CMSampleBufferGetNumSamples(sb)
        var sync = [Bool](repeating: true, count: max(sampleCount, 1))
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[CFString: Any]] {
            for (j, dict) in atts.enumerated() where j < sync.count {
                if let notSync = dict[kCMSampleAttachmentKey_NotSync] as? Bool { sync[j] = !notSync }
            }
        }
        func ns(_ t: CMTime) -> Int64? {
            t.isNumeric ? t.convertScale(1_000_000_000, method: .default).value : nil
        }

        if sampleCount <= 1 {
            let pts = ns(CMSampleBufferGetOutputPresentationTimeStamp(sb)) ?? 0
            let dts = ns(CMSampleBufferGetOutputDecodeTimeStamp(sb))
            var dur = ns(CMSampleBufferGetOutputDuration(sb))
            if dur == 0 { dur = nil }
            return makePacket(streamIndex: i, ptsNs: pts, dtsNs: dts, durationNs: dur,
                              sync: sync[0], payload: data).map { [$0] } ?? []
        }

        // Batched passthrough buffer (several compressed audio frames in one
        // CMSampleBuffer): split on the per-sample size + timing arrays.
        var sizes = [Int](repeating: 0, count: sampleCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: sampleCount)
        var needed = 0
        guard CMSampleBufferGetSampleSizeArray(sb, entryCount: sampleCount,
                                               arrayToFill: &sizes, entriesNeededOut: &needed) == noErr,
              CMSampleBufferGetOutputSampleTimingInfoArray(sb, entryCount: sampleCount,
                                                           arrayToFill: &timings, entriesNeededOut: &needed) == noErr
        else {
            // Can't split — hand over the whole buffer; the Dolby syncframe
            // splitter downstream copes with multi-frame packets.
            let pts = ns(CMSampleBufferGetOutputPresentationTimeStamp(sb)) ?? 0
            var dur = ns(CMSampleBufferGetOutputDuration(sb))
            if dur == 0 { dur = nil }
            return makePacket(streamIndex: i, ptsNs: pts, dtsNs: nil, durationNs: dur,
                              sync: true, payload: data).map { [$0] } ?? []
        }
        var out: [(Int64, MKVPacket)] = []
        var offset = 0
        for j in 0..<sampleCount {
            guard sizes[j] > 0, offset + sizes[j] <= data.count else { break }
            let piece = data.subdata(in: offset..<(offset + sizes[j]))
            offset += sizes[j]
            var dur = ns(timings[j].duration)
            if dur == 0 { dur = nil }
            if let p = makePacket(streamIndex: i,
                                  ptsNs: ns(timings[j].presentationTimeStamp) ?? 0,
                                  dtsNs: ns(timings[j].decodeTimeStamp),
                                  durationNs: dur,
                                  sync: sync[j], payload: piece) {
                out.append(p)
            }
        }
        return out
    }

    private func makePacket(streamIndex i: Int, ptsNs: Int64, dtsNs: Int64?, durationNs: Int64?,
                            sync: Bool, payload: Data) -> (key: Int64, packet: MKVPacket)? {
        var body = payload
        if streams[i].isTimedText {
            // tx3g sample: u16 big-endian text length + UTF-8 text (+ style
            // boxes we ignore). Zero length = the gap between cues.
            guard payload.count >= 2 else { return nil }
            let start = payload.startIndex
            let length = Int(payload[start]) << 8 | Int(payload[start + 1])
            guard length > 0, payload.count >= 2 + length else { return nil }
            body = payload.subdata(in: (start + 2)..<(start + 2 + length))
        }
        let packet = MKVPacket(trackNumber: streams[i].track.number,
                               ptsNs: ptsNs,
                               durationNs: durationNs,
                               keyframe: sync,
                               discardPaddingNs: 0,
                               data: body)
        return (dtsNs ?? ptsNs, packet)
    }
}

// MARK: - Helpers

private func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                 UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
}

// CoreAudio's AAC magic cookie is the esds descriptor chain (sometimes the
// whole esds atom); the audio pipeline wants the bare AudioSpecificConfig,
// like MKV CodecPrivate carries. Walk ES_Descriptor(0x03) →
// DecoderConfig(0x04) → DecoderSpecificInfo(0x05); when nothing there parses
// as descriptors, assume the cookie already is a raw ASC.
private func aacAudioSpecificConfig(from fd: CMFormatDescription) -> Data? {
    var size = 0
    guard let raw = CMAudioFormatDescriptionGetMagicCookie(fd, sizeOut: &size), size > 0 else {
        return nil
    }
    var d = [UInt8](Data(bytes: raw, count: size))
    // Whole-atom shape: [u32 size]["esds"][u32 version/flags] before the chain.
    if d.count > 12, d[4] == 0x65, d[5] == 0x73, d[6] == 0x64, d[7] == 0x73 {
        d = Array(d[12...])
    }
    var i = 0
    func readLength() -> Int {
        var length = 0
        for _ in 0..<4 {
            guard i < d.count else { break }
            let b = d[i]; i += 1
            length = (length << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { break }
        }
        return length
    }
    while i < d.count {
        let tag = d[i]; i += 1
        let length = readLength()
        switch tag {
        case 0x03:  // ES_Descriptor: ES_ID(2) + flags(1) + flag-dependent fields
            guard i + 3 <= d.count else { return Data(d) }
            let flags = d[i + 2]
            i += 3
            if flags & 0x80 != 0 { i += 2 }                      // dependsOn ES_ID
            if flags & 0x40 != 0, i < d.count { i += 1 + Int(d[i]) }  // URL string
            if flags & 0x20 != 0 { i += 2 }                      // OCR ES_ID
        case 0x04:  // DecoderConfigDescriptor: 13 fixed bytes, then children
            i += 13
        case 0x05:  // DecoderSpecificInfo = the AudioSpecificConfig
            guard length > 0, i + length <= d.count else { return Data(d) }
            return Data(d[i..<(i + length)])
        default:
            i += max(0, length)
        }
    }
    return Data(d)
}
