import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// Audio half of the playback engine, and the playback clock. One
// AVSampleBufferAudioRenderer attached to an AVSampleBufferRenderSynchronizer:
// the audio device disciplines the timebase, video is pulled against it.
// Compressed packets pass straight through — AC3/E-AC-3 (JOC Atmos rides the
// same ID), AAC, FLAC, and Opus all decode in the OS renderer (cookie shapes
// verified by spike: AAC = raw AudioSpecificConfig, FLAC = bare 34-byte
// STREAMINFO, Opus = OpusHead).

func isPassthroughAudioCodec(_ codecID: String) -> Bool {
    switch codecID {
    case "A_AC3", "A_EAC3", "A_AAC", "A_FLAC", "A_OPUS":
        return true
    case let s where s.hasPrefix("A_AAC/"):
        return true
    default:
        return false
    }
}

// Everything we can play: OS-decoded passthrough plus our own decoders.
// DTS (incl. the core of DTS-HD) decodes via DTSDecoder into PCM.
func isDecodableAudioCodec(_ codecID: String) -> Bool {
    isPassthroughAudioCodec(codecID) || codecID == "A_DTS"
}

// Human label for the status overlay, including codecs we know but can't
// decode yet (phase-gated own decoders).
func audioCodecLabel(_ codecID: String) -> String {
    switch codecID {
    case "A_AC3": return "AC-3"
    case "A_EAC3": return "E-AC-3"
    case "A_FLAC": return "FLAC"
    case "A_OPUS": return "Opus"
    case "A_DTS": return "DTS"
    case "A_TRUEHD": return "TrueHD"
    case "A_MLP": return "MLP"
    case let s where s.hasPrefix("A_AAC"): return "AAC"
    case let s where s.hasPrefix("A_PCM"): return "PCM"
    default: return codecID
    }
}

private func parseAudioSpecificConfig(_ asc: Data) -> (sampleRate: Double, channels: Int)? {
    guard asc.count >= 2 else { return nil }
    let b = [UInt8](asc)
    var bitPos = 0
    func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            guard bitPos / 8 < b.count else { return v }
            v = (v << 1) | Int((b[bitPos / 8] >> (7 - bitPos % 8)) & 1)
            bitPos += 1
        }
        return v
    }
    var aot = bits(5)
    if aot == 31 { aot = 32 + bits(6) }
    let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000,
                           24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0]
    let freqIdx = bits(4)
    var rate = freqIdx == 15 ? Double(bits(24)) : rates[freqIdx]
    let chanConfig = bits(4)
    // HE-AAC explicit signaling carries the output (extension) sample rate.
    if aot == 5 || aot == 29 {
        let extIdx = bits(4)
        rate = extIdx == 15 ? Double(bits(24)) : rates[extIdx]
    }
    let channels = chanConfig == 7 ? 8 : chanConfig
    guard rate > 0 else { return nil }
    return (rate, max(1, channels))
}

func makeAudioFormatDescription(track: MKVTrack) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = track.effectiveSampleRate
    asbd.mChannelsPerFrame = UInt32(track.channels)
    var cookie: Data?

    switch track.codecID {
    case "A_AC3":
        asbd.mFormatID = kAudioFormatAC3
        asbd.mFramesPerPacket = 1536
    case "A_EAC3":
        asbd.mFormatID = kAudioFormatEnhancedAC3
        asbd.mFramesPerPacket = 1536
    case let s where s == "A_AAC" || s.hasPrefix("A_AAC/"):
        asbd.mFormatID = kAudioFormatMPEG4AAC
        asbd.mFramesPerPacket = 1024
        if let asc = track.codecPrivate, let cfg = parseAudioSpecificConfig(asc) {
            asbd.mSampleRate = cfg.sampleRate
            asbd.mChannelsPerFrame = UInt32(cfg.channels)
        }
        cookie = track.codecPrivate  // raw AudioSpecificConfig
    case "A_FLAC":
        asbd.mFormatID = kAudioFormatFLAC
        // CodecPrivate = "fLaC" magic + metadata blocks; STREAMINFO is the
        // first block (4-byte magic + 4-byte block header + 34 bytes). The OS
        // decoder wants the bare 34-byte STREAMINFO as its magic cookie.
        guard let priv = track.codecPrivate, priv.count >= 42 else {
            throw MKVError.corrupt("A_FLAC track missing STREAMINFO")
        }
        let si = priv.subdata(in: (priv.startIndex + 8)..<(priv.startIndex + 42))
        let minBlock = (Int(si[si.startIndex]) << 8) | Int(si[si.startIndex + 1])
        let maxBlock = (Int(si[si.startIndex + 2]) << 8) | Int(si[si.startIndex + 3])
        if minBlock == maxBlock { asbd.mFramesPerPacket = UInt32(maxBlock) }
        cookie = si
    case "A_OPUS":
        asbd.mFormatID = kAudioFormatOpus
        asbd.mSampleRate = 48000  // Opus always decodes at 48 kHz
        asbd.mFramesPerPacket = 960
        cookie = track.codecPrivate  // OpusHead
    default:
        throw MKVError.corrupt("audio codec \(track.codecID) is not supported")
    }

    var layout = AudioChannelLayout()
    switch Int(asbd.mChannelsPerFrame) {
    case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    case 3: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_3_0_A
    case 4: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_4_0_A
    case 5: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_0_A
    case 6: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
    case 7: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_6_1_A
    case 8: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
    default: break
    }
    let hasLayout = layout.mChannelLayoutTag != 0
    let cookieBytes = cookie ?? Data()

    var desc: CMAudioFormatDescription?
    let status = withUnsafePointer(to: layout) { lp -> OSStatus in
        cookieBytes.withUnsafeBytes { (cb: UnsafeRawBufferPointer) in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: hasLayout ? MemoryLayout<AudioChannelLayout>.size : 0,
                layout: hasLayout ? lp : nil,
                magicCookieSize: cookieBytes.count,
                magicCookie: cookieBytes.isEmpty ? nil : cb.baseAddress,
                extensions: nil, formatDescriptionOut: &desc)
        }
    }
    guard status == noErr, let desc else {
        throw MKVError.corrupt("CMAudioFormatDescriptionCreate(\(track.codecID)) failed (\(status))")
    }
    return desc
}

// Split an MKV block that carries several AC-3 / E-AC-3 syncframes into
// individual packets (CoreAudio expects one syncframe per packet). Frame sizes
// come from the headers, not from scanning for sync words.
func splitDolbySyncframes(codecID: String, data: Data) -> [Data] {
    let bytes = [UInt8](data)
    guard bytes.count > 6, bytes[0] == 0x0B, bytes[1] == 0x77 else { return [data] }

    func frameSize(at off: Int) -> Int? {
        guard off + 6 <= bytes.count, bytes[off] == 0x0B, bytes[off + 1] == 0x77 else { return nil }
        if codecID == "A_EAC3" {
            let frmsiz = (Int(bytes[off + 2] & 0x07) << 8) | Int(bytes[off + 3])
            return (frmsiz + 1) * 2
        }
        // AC-3: fscod (2 bits) + frmsizecod (6 bits) at byte 4.
        let fscod = Int(bytes[off + 4] >> 6)
        let frmsizecod = Int(bytes[off + 4] & 0x3F)
        let bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128,
                        160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
        guard frmsizecod / 2 < bitrates.count else { return nil }
        let kbps = bitrates[frmsizecod / 2]
        switch fscod {
        case 0: return kbps * 4                                            // 48 kHz
        case 1: return 2 * (Int(Double(kbps) * 96000.0 / 44100.0) + (frmsizecod & 1))  // 44.1 kHz
        case 2: return kbps * 6                                            // 32 kHz
        default: return nil
        }
    }

    guard let first = frameSize(at: 0), first < bytes.count else { return [data] }
    var out: [Data] = []
    var off = 0
    while off < bytes.count {
        guard let size = frameSize(at: off), size > 0, off + size <= bytes.count else {
            // Header didn't parse — keep the remainder as one packet rather
            // than dropping audio.
            out.append(data.subdata(in: (data.startIndex + off)..<data.endIndex))
            break
        }
        out.append(data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + size)))
        off += size
    }
    return out.isEmpty ? [data] : out
}

// MARK: - Pipeline

final class AudioPipeline {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let renderer = AVSampleBufferAudioRenderer()
    private let pumpQueue = DispatchQueue(label: "metalframe.audio.pump")

    private let lock = NSCondition()
    private var fifo: [MKVPacket] = []
    private var closed = false
    private var eof = false
    private static let fifoCapacity = 256

    private var format: CMAudioFormatDescription?
    private var track: MKVTrack?
    // DTS: our own decoder feeds PCM buffers; the format description is built
    // from the first decoded frame (rate/layout come from the bitstream).
    private var dtsDecoder: DTSDecoder?
    private var dtsFormatKey: UInt64 = 0
    // Trim bookkeeping: the first buffer after a configure/flush gets
    // TrimDurationAtStart for codec delay (Opus pre-skip) and seek alignment.
    private var pendingStartTrimNs: Int64 = 0
    private var firstBufferPending = true
    private(set) var lastEnqueuedEndNs: Int64 = Int64.min
    var rendererError: Error? { renderer.error }

    private var repumpScheduled = false

    init() {
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        // Apply rate changes immediately. The deferred default parks the
        // timebase near zero whenever the audio device is slow to spin up
        // (observed intermittently at launch) — playback then looks frozen.
        // A/V start alignment is handled by the engine's prime step instead,
        // and an audio underrun degrades to silence, not a stopped clock.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(renderer)
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pump()
        }
    }

    // Select the track this pipeline feeds.
    func configure(track: MKVTrack) throws {
        let isDTS = track.codecID == "A_DTS"
        let format = isDTS ? nil : try makeAudioFormatDescription(track: track)
        lock.lock()
        self.track = track
        self.format = format
        self.dtsDecoder = isDTS ? DTSDecoder() : nil
        self.dtsFormatKey = 0
        fifo.removeAll()
        eof = false
        firstBufferPending = true
        pendingStartTrimNs = Int64(track.codecDelayNs)
        lastEnqueuedEndNs = Int64.min
        lock.unlock()
    }

    // Demux thread: bounded blocking push (the engine's audio backpressure).
    func enqueue(_ packet: MKVPacket) {
        lock.lock()
        while fifo.count >= Self.fifoCapacity && !closed {
            lock.wait()
        }
        if closed {
            lock.unlock()
            return
        }
        fifo.append(packet)
        lock.unlock()
        pumpQueue.async { [weak self] in self?.pump() }
    }

    func markEOF() {
        lock.lock()
        eof = true
        lock.unlock()
    }

    var isEOFDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eof && fifo.isEmpty
    }

    // Seek: drop everything buffered on both sides, and leave the FIFO closed
    // so a feeder woken mid-flush can't sneak a stale packet in — reopen()
    // re-arms it once the old demux thread is provably gone. No start trim
    // afterwards: codec delay applies to the start of the stream only, and
    // seek alignment is handled by the renderer clipping to the synchronizer's
    // timebase (we deliberately feed from the seek cluster's start so lossy
    // decoders re-converge before the target — that's the seek pre-roll).
    func flush() {
        lock.lock()
        closed = true
        fifo.removeAll()
        lock.broadcast()
        lock.unlock()
        pumpQueue.sync {}  // drain any in-flight pump before flushing the renderer
        renderer.flush()
        dtsDecoder?.reset()   // safe: pump drained above, and closed blocks new work
        lock.lock()
        firstBufferPending = false
        lastEnqueuedEndNs = Int64.min
        lock.unlock()
    }

    func reopen() {
        lock.lock()
        closed = false
        eof = false
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        closed = true
        fifo.removeAll()
        lock.broadcast()
        lock.unlock()
        renderer.stopRequestingMediaData()
        renderer.flush()
    }

    private func pump() {
        defer { scheduleRepumpIfNeeded() }
        while renderer.isReadyForMoreMediaData {
            lock.lock()
            guard !closed, !fifo.isEmpty, let track else {
                lock.unlock()
                return
            }
            let isDTS = track.codecID == "A_DTS"
            let lockedFormat = format
            if !isDTS, lockedFormat == nil {
                lock.unlock()
                return
            }
            let packet = fifo.removeFirst()
            let isFirst = firstBufferPending
            let startTrim = pendingStartTrimNs
            if firstBufferPending { firstBufferPending = false }
            lock.broadcast()
            lock.unlock()

            if isDTS {
                enqueueDTS(packet: packet, isFirst: isFirst, startTrimNs: startTrim)
                continue
            }
            guard let format = lockedFormat else { continue }

            // One MKV block can hold several Dolby syncframes; CoreAudio wants
            // one per sample. Other codecs are one frame per block already.
            let pieces: [Data]
            if track.codecID == "A_AC3" || track.codecID == "A_EAC3" {
                pieces = splitDolbySyncframes(codecID: track.codecID, data: packet.data)
            } else {
                pieces = [packet.data]
            }
            let pieceDurNs = packet.durationNs.map { $0 / Int64(pieces.count) }

            for (i, piece) in pieces.enumerated() {
                let ptsNs = packet.ptsNs + Int64(i) * (pieceDurNs ?? 0)
                guard let sb = try? makeCompressedSampleBuffer(
                    data: piece, format: format, ptsNs: ptsNs, durationNs: pieceDurNs) else { continue }
                if isFirst, i == 0, startTrim > 0 {
                    let trim = CMTime(value: startTrim, timescale: 1_000_000_000)
                    CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                    value: CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault),
                                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                if packet.discardPaddingNs > 0, i == pieces.count - 1 {
                    let trim = CMTime(value: packet.discardPaddingNs, timescale: 1_000_000_000)
                    CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                                    value: CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault),
                                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
                }
                renderer.enqueue(sb)
                lock.lock()
                lastEnqueuedEndNs = max(lastEnqueuedEndNs, ptsNs + (pieceDurNs ?? 0))
                lock.unlock()
            }
        }
    }

    // MARK: DTS decode path (pump queue only)

    private func dtsLayoutTag(_ f: DTSDecodedFrame) -> AudioChannelLayoutTag? {
        switch (f.channelCount, f.amode, f.hasLFE) {
        case (1, _, false): return kAudioChannelLayoutTag_Mono
        case (2, _, false): return kAudioChannelLayoutTag_Stereo
        case (3, 5, false): return kAudioChannelLayoutTag_MPEG_3_0_A   // L R C
        case (3, 6, false): return kAudioChannelLayoutTag_ITU_2_1      // L R Cs
        case (3, _, true):  return kAudioChannelLayoutTag_DVD_4        // L R LFE
        case (4, 7, false): return kAudioChannelLayoutTag_MPEG_4_0_A   // L R C Cs
        case (4, 8, false): return kAudioChannelLayoutTag_Quadraphonic // L R Ls Rs
        case (5, 9, false): return kAudioChannelLayoutTag_MPEG_5_0_A   // L R C Ls Rs
        case (6, 9, true):  return kAudioChannelLayoutTag_MPEG_5_1_A   // L R C LFE Ls Rs
        default: return nil
        }
    }

    private func makeDTSFormat(frame f: DTSDecodedFrame) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Double(f.sampleRate)
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = UInt32(f.channelCount)
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = UInt32(4 * f.channelCount)
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        var layout = AudioChannelLayout()
        if let tag = dtsLayoutTag(f) { layout.mChannelLayoutTag = tag }
        let hasLayout = layout.mChannelLayoutTag != 0
        var desc: CMAudioFormatDescription?
        let status = withUnsafePointer(to: layout) { lp in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: hasLayout ? MemoryLayout<AudioChannelLayout>.size : 0,
                layout: hasLayout ? lp : nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else {
            throw MKVError.io("DTS PCM format description failed (\(status))")
        }
        return desc
    }

    private func makePCMSampleBuffer(pcm: [Float], format: CMAudioFormatDescription,
                                     frameCount: Int, ptsNs: Int64) throws -> CMSampleBuffer {
        let byteCount = pcm.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MKVError.io("CMBlockBufferCreate failed (\(status))")
        }
        pcm.withUnsafeBytes { buf in
            _ = CMBlockBufferReplaceDataBytes(with: buf.baseAddress!, blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sb: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: format, sampleCount: frameCount,
            presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
            packetDescriptions: nil, sampleBufferOut: &sb)
        guard status == noErr, let sb else {
            throw MKVError.io("PCM CMSampleBuffer failed (\(status))")
        }
        return sb
    }

    private func enqueueDTS(packet: MKVPacket, isFirst: Bool, startTrimNs: Int64) {
        guard let decoder = dtsDecoder else { return }
        let frames = decoder.decode(packet: packet.data)
        var offsetNs: Int64 = 0
        for (i, f) in frames.enumerated() {
            let key = UInt64(f.sampleRate) << 8 | UInt64(f.channelCount)
            if key != dtsFormatKey {
                guard let fmt = try? makeDTSFormat(frame: f) else { continue }
                lock.lock()
                format = fmt
                dtsFormatKey = key
                lock.unlock()
            }
            lock.lock()
            let fmt = format
            lock.unlock()
            guard let fmt else { continue }
            let ptsNs = packet.ptsNs + offsetNs
            let durNs = Int64(f.samplesPerChannel) * 1_000_000_000 / Int64(f.sampleRate)
            offsetNs += durNs
            guard let sb = try? makePCMSampleBuffer(pcm: f.pcm, format: fmt,
                                                    frameCount: f.samplesPerChannel,
                                                    ptsNs: ptsNs) else { continue }
            if isFirst, i == 0, startTrimNs > 0 {
                let trim = CMTime(value: startTrimNs, timescale: 1_000_000_000)
                CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                                value: CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault),
                                attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            renderer.enqueue(sb)
            lock.lock()
            lastEnqueuedEndNs = max(lastEnqueuedEndNs, ptsNs + durNs)
            lock.unlock()
        }
    }

    // Watchdog: while data is waiting and the renderer isn't accepting, poll.
    // requestMediaDataWhenReady alone proved unreliable when the audio device
    // is slow to start — if its callback goes quiet and the demux thread is
    // blocked on a full FIFO (no push-kicks), feeding would deadlock.
    private func scheduleRepumpIfNeeded() {
        lock.lock()
        let pending = !closed && !fifo.isEmpty && format != nil
        let shouldSchedule = pending && !repumpScheduled
        if shouldSchedule { repumpScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        pumpQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.repumpScheduled = false
            self.lock.unlock()
            self.pump()
        }
    }
}
