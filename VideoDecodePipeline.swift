import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// Video half of the playback engine: compressed MKV packets → VideoToolbox →
// PTS-ordered CVImageBuffers in a bounded FrameQueue that draw(in:) pulls from
// by media time. Mirrors the destination-buffer negotiation the AVPlayer path
// used, so the Metal intake pass downstream is unchanged.

// MARK: - Format description

// VT does NOT parse colorimetry out of a plain avcC/hvcC extension atom, but
// CMVideoFormatDescriptionCreateFrom*ParameterSets does — so when the container
// carries no Colour element we build a scratch description from the parameter
// sets and merge the VUI-derived color extensions (verified: an untagged-
// container HDR10 WEB-DL then classifies as BT.2100 PQ, exactly like its MP4
// remux did).
func makeVideoFormatDescription(track: MKVTrack) throws -> CMVideoFormatDescription {
    let codecType: CMVideoCodecType
    let atomKey: String
    switch track.codecID {
    case "V_MPEG4/ISO/AVC":  codecType = kCMVideoCodecType_H264; atomKey = "avcC"
    case "V_MPEGH/ISO/HEVC": codecType = kCMVideoCodecType_HEVC; atomKey = "hvcC"
    case "V_AV1":            codecType = kCMVideoCodecType_AV1;  atomKey = "av1C"
    default:
        throw MKVError.corrupt("video codec \(track.codecID) is not supported")
    }
    guard let priv = track.codecPrivate, !priv.isEmpty else {
        throw MKVError.corrupt("\(track.codecID) track missing CodecPrivate")
    }

    var ext: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomKey: priv],
    ]

    if let c = track.colour {
        switch c.primaries {
        case 1:    ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9:    ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case 11:   ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_DCI_P3
        case 12:   ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_P3_D65
        case 5, 6: ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_SMPTE_C
        case 4:    ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_EBU_3213
        default: break
        }
        switch c.transferCharacteristics {
        case 1, 6, 14, 15: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case 13: ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_sRGB
        case 8:  ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_Linear
        default: break
        }
        switch c.matrixCoefficients {
        case 1:     ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 9, 10: ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case 5, 6:  ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case 7:     ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        default: break
        }
        if let range = c.range {
            ext[kCMFormatDescriptionExtension_FullRangeVideo] = (range == 2)
        }
        // HDR10 static metadata → SEI-shaped payloads (G,B,R order; 0.00002
        // chromaticity units; 0.0001 cd/m² luminance units) that VT propagates
        // onto output pixel buffers.
        if let m = c.mastering,
           let rx = m.primaryRX, let ry = m.primaryRY,
           let gx = m.primaryGX, let gy = m.primaryGY,
           let bx = m.primaryBX, let by = m.primaryBY,
           let wx = m.whitePointX, let wy = m.whitePointY,
           let lmax = m.luminanceMax, let lmin = m.luminanceMin {
            var payload = Data()
            func u16(_ v: Double, scale: Double) {
                let x = UInt16(max(0, min(65535, (v * scale).rounded())))
                payload.append(UInt8(x >> 8)); payload.append(UInt8(x & 0xFF))
            }
            func u32(_ v: Double, scale: Double) {
                let x = UInt32(max(0, min(4_294_967_295, (v * scale).rounded())))
                payload.append(UInt8((x >> 24) & 0xFF)); payload.append(UInt8((x >> 16) & 0xFF))
                payload.append(UInt8((x >> 8) & 0xFF)); payload.append(UInt8(x & 0xFF))
            }
            for (x, y) in [(gx, gy), (bx, by), (rx, ry)] { u16(x, scale: 50000); u16(y, scale: 50000) }
            u16(wx, scale: 50000); u16(wy, scale: 50000)
            u32(lmax, scale: 10000); u32(lmin, scale: 10000)
            ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = payload
        }
        if let maxCLL = c.maxCLL, let maxFALL = c.maxFALL {
            var payload = Data()
            for v in [maxCLL, maxFALL] {
                payload.append(UInt8((v >> 8) & 0xFF)); payload.append(UInt8(v & 0xFF))
            }
            ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] = payload
        }
    }

    if ext[kCMFormatDescriptionExtension_ColorPrimaries] == nil,
       let vuiExt = vuiColorExtensions(codecID: track.codecID, codecPrivate: priv) {
        for (k, v) in vuiExt where ext[k] == nil { ext[k] = v }
    }

    var desc: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: Int32(track.pixelWidth), height: Int32(track.pixelHeight),
        extensions: ext as CFDictionary,
        formatDescriptionOut: &desc)
    guard status == noErr, let desc else {
        throw MKVError.corrupt("CMVideoFormatDescriptionCreate failed (\(status))")
    }
    return desc
}

// Extract SPS/PPS(/VPS) from avcC/hvcC, let CoreMedia parse the VUI, and
// return the colorimetry extensions it derived. AV1 has no equivalent API;
// AV1-in-MKV relies on the container Colour element (present in practice).
private func vuiColorExtensions(codecID: String, codecPrivate priv: Data) -> [CFString: Any]? {
    let p = [UInt8](priv)
    var nalus: [[UInt8]] = []
    var scratch: CMVideoFormatDescription?

    if codecID == "V_MPEG4/ISO/AVC" {
        guard p.count > 6 else { return nil }
        var off = 5
        let numSPS = Int(p[off] & 0x1F); off += 1
        for _ in 0..<numSPS {
            guard off + 2 <= p.count else { return nil }
            let len = (Int(p[off]) << 8) | Int(p[off + 1]); off += 2
            guard off + len <= p.count else { return nil }
            nalus.append(Array(p[off..<off + len])); off += len
        }
        guard off < p.count else { return nil }
        let numPPS = Int(p[off]); off += 1
        for _ in 0..<numPPS {
            guard off + 2 <= p.count else { return nil }
            let len = (Int(p[off]) << 8) | Int(p[off + 1]); off += 2
            guard off + len <= p.count else { return nil }
            nalus.append(Array(p[off..<off + len])); off += len
        }
        guard nalus.count >= 2 else { return nil }
        let status = withNALPointers(nalus) { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: ptrs.count,
                parameterSetPointers: ptrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &scratch)
        }
        guard status == noErr else { return nil }
    } else if codecID == "V_MPEGH/ISO/HEVC" {
        guard p.count > 23 else { return nil }
        var off = 22
        let numArrays = Int(p[off]); off += 1
        for _ in 0..<numArrays {
            guard off + 3 <= p.count else { return nil }
            off += 1  // array_completeness + NAL_unit_type
            let numNALs = (Int(p[off]) << 8) | Int(p[off + 1]); off += 2
            for _ in 0..<numNALs {
                guard off + 2 <= p.count else { return nil }
                let len = (Int(p[off]) << 8) | Int(p[off + 1]); off += 2
                guard off + len <= p.count else { return nil }
                nalus.append(Array(p[off..<off + len])); off += len
            }
        }
        guard nalus.count >= 3 else { return nil }
        let status = withNALPointers(nalus) { ptrs, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: ptrs.count,
                parameterSetPointers: ptrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &scratch)
        }
        guard status == noErr else { return nil }
    } else {
        return nil
    }

    guard let scratch,
          let all = CMFormatDescriptionGetExtensions(scratch) as? [CFString: Any] else { return nil }
    var out: [CFString: Any] = [:]
    for key in [kCMFormatDescriptionExtension_ColorPrimaries,
                kCMFormatDescriptionExtension_TransferFunction,
                kCMFormatDescriptionExtension_YCbCrMatrix,
                kCMFormatDescriptionExtension_FullRangeVideo,
                kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
                kCMFormatDescriptionExtension_ContentLightLevelInfo] {
        if let v = all[key] { out[key] = v }
    }
    return out.isEmpty ? nil : out
}

private func withNALPointers(_ nalus: [[UInt8]],
                             _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus) -> OSStatus {
    let sizes = nalus.map(\.count)
    func recurse(_ idx: Int, _ acc: inout [UnsafePointer<UInt8>]) -> OSStatus {
        if idx == nalus.count { return body(acc, sizes) }
        return nalus[idx].withUnsafeBufferPointer { buf in
            acc.append(buf.baseAddress!)
            defer { acc.removeLast() }
            return recurse(idx + 1, &acc)
        }
    }
    var acc: [UnsafePointer<UInt8>] = []
    return recurse(0, &acc)
}

// MARK: - Sample buffer packaging (shared with the audio pipeline)

func makeCompressedSampleBuffer(data: Data, format: CMFormatDescription,
                                ptsNs: Int64, durationNs: Int64?) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw MKVError.io("CMBlockBufferCreate failed (\(status))")
    }
    _ = data.withUnsafeBytes { buf in
        CMBlockBufferReplaceDataBytes(with: buf.baseAddress!, blockBuffer: blockBuffer,
                                      offsetIntoDestination: 0, dataLength: data.count)
    }
    var timing = CMSampleTimingInfo(
        duration: durationNs.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? .invalid,
        presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
        decodeTimeStamp: .invalid)
    var sampleSize = data.count
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sampleBuffer else {
        throw MKVError.io("CMSampleBufferCreate failed (\(status))")
    }
    return sampleBuffer
}

// MARK: - Frame queue

struct DecodedFrame {
    let ptsNs: Int64
    let durationNs: Int64
    let buffer: CVImageBuffer
}

// Bounded queue of display-ordered decoded frames. The producer (VT output
// path) blocks while full — that's the engine's decode backpressure. The
// consumer (draw(in:) on the render thread) never blocks.
final class FrameQueue {
    private let condition = NSCondition()
    private var frames: [DecodedFrame] = []
    private var flushing = false
    private let capacity: Int

    init(capacity: Int = 6) {
        self.capacity = capacity
    }

    // Blocks while full. Returns false if the frame was rejected by a flush.
    @discardableResult
    func append(_ frame: DecodedFrame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while frames.count >= capacity && !flushing {
            condition.wait()
        }
        if flushing { return false }
        frames.append(frame)
        return true
    }

    // Newest frame with pts ≤ time; older frames are discarded. Nil when no
    // frame is due yet (caller keeps showing the previous frame).
    func take(atOrBefore timeNs: Int64) -> DecodedFrame? {
        condition.lock()
        defer { condition.unlock() }
        var picked: DecodedFrame?
        while let first = frames.first, first.ptsNs <= timeNs {
            picked = first
            frames.removeFirst()
        }
        if picked != nil { condition.broadcast() }
        return picked
    }

    var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return frames.isEmpty
    }

    var firstPtsNs: Int64? {
        condition.lock()
        defer { condition.unlock() }
        return frames.first?.ptsNs
    }

    // Flush mode rejects producers instead of blocking them, so a seek can
    // drain VT's async callbacks without deadlocking on a full queue.
    func beginFlush() {
        condition.lock()
        flushing = true
        frames.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    func endFlush() {
        condition.lock()
        flushing = false
        condition.unlock()
    }
}

// MARK: - Decode pipeline

final class VideoDecodePipeline {
    let track: MKVTrack
    let formatDescription: CMVideoFormatDescription
    let frameQueue = FrameQueue()
    private(set) var usingHardware = false
    private(set) var decodeErrorCount = 0

    private var session: VTDecompressionSession?
    // Decode-order → presentation-order reorder buffer: min-heap by PTS, popped
    // once deeper than the reorder window.
    private let reorderLock = NSLock()
    private var reorderHeap: [DecodedFrame] = []
    private let reorderDepth = 8
    // Seek support: decoded frames before this PTS are reference-only — drop
    // them instead of queueing (frame-accurate seek).
    private var dropBeforeNsValue: Int64 = Int64.min
    var dropBeforeNs: Int64 {
        get { reorderLock.withLock { dropBeforeNsValue } }
        set { reorderLock.withLock { dropBeforeNsValue = newValue } }
    }

    init(track: MKVTrack) throws {
        self.track = track
        formatDescription = try makeVideoFormatDescription(track: track)

        // Mirror the pixel formats the AVPlayer path negotiated — the Metal
        // intake shader handles exactly these four.
        let destAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: [
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            ],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        // Prefer hardware; VT falls back to software for H.264/HEVC where
        // needed (AV1 has no software decoder on macOS).
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, infoFlags, imageBuffer, pts, duration in
                guard let refcon else { return }
                let pipeline = Unmanaged<VideoDecodePipeline>.fromOpaque(refcon).takeUnretainedValue()
                pipeline.handleDecodedFrame(status: status, infoFlags: infoFlags,
                                            imageBuffer: imageBuffer, pts: pts, duration: duration)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: destAttrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            throw MKVError.corrupt("VTDecompressionSessionCreate failed (\(status)) for \(track.codecID)")
        }
        session = newSession
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let hwOut = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        hwOut.initialize(to: nil)
        defer { hwOut.deallocate() }
        if VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                 allocator: nil, valueOut: hwOut) == noErr {
            usingHardware = (hwOut.pointee as? Bool) ?? false
        }
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    // Called on the engine's video decode thread. Blocks (via FrameQueue)
    // when playback is far enough ahead — that's the backpressure that keeps
    // decode ~6 frames in front of the display.
    func decode(_ packet: MKVPacket) {
        guard let session else { return }
        let duration = packet.durationNs ?? track.defaultDurationNs.map(Int64.init)
        guard let sampleBuffer = try? makeCompressedSampleBuffer(
            data: packet.data, format: formatDescription,
            ptsNs: packet.ptsNs, durationNs: duration) else {
            decodeErrorCount += 1
            return
        }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: nil)
        if status != noErr {
            // Never stall the pipeline on a bad frame: count it and move on.
            decodeErrorCount += 1
        }
    }

    private func handleDecodedFrame(status: OSStatus, infoFlags: VTDecodeInfoFlags,
                                    imageBuffer: CVImageBuffer?, pts: CMTime, duration: CMTime) {
        guard status == noErr, let imageBuffer, !infoFlags.contains(.frameDropped) else {
            if status != noErr { decodeErrorCount += 1 }
            return
        }
        let frame = DecodedFrame(
            ptsNs: pts.isNumeric ? pts.convertScale(1_000_000_000, method: .default).value : 0,
            durationNs: duration.isNumeric ? duration.convertScale(1_000_000_000, method: .default).value : 0,
            buffer: imageBuffer)

        // Push in decode order, emit in presentation order once the heap is
        // deeper than the reorder window.
        var emit: [DecodedFrame] = []
        reorderLock.lock()
        heapPush(frame)
        while reorderHeap.count > reorderDepth {
            emit.append(heapPop())
        }
        let dropBefore = dropBeforeNsValue
        reorderLock.unlock()

        for f in emit {
            if f.ptsNs + f.durationNs <= dropBefore { continue }  // seek pre-target frame
            frameQueue.append(f)
        }
    }

    // Drain everything still in flight (EOF): finish async decodes, then flush
    // the reorder heap into the queue in presentation order.
    func finish() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        var remaining: [DecodedFrame] = []
        reorderLock.lock()
        while !reorderHeap.isEmpty { remaining.append(heapPop()) }
        let dropBefore = dropBeforeNsValue
        reorderLock.unlock()
        for f in remaining {
            if f.ptsNs + f.durationNs <= dropBefore { continue }
            frameQueue.append(f)
        }
    }

    // Seek: reject producers, drain VT, clear all buffered frames.
    func flush() {
        frameQueue.beginFlush()
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        reorderLock.lock()
        reorderHeap.removeAll()
        reorderLock.unlock()
        frameQueue.beginFlush()  // clear anything appended during the drain
        frameQueue.endFlush()
    }

    // MARK: min-heap by PTS (callers hold reorderLock)

    private func heapPush(_ f: DecodedFrame) {
        reorderHeap.append(f)
        var i = reorderHeap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard reorderHeap[i].ptsNs < reorderHeap[parent].ptsNs else { break }
            reorderHeap.swapAt(i, parent)
            i = parent
        }
    }

    private func heapPop() -> DecodedFrame {
        let top = reorderHeap[0]
        let last = reorderHeap.removeLast()
        if !reorderHeap.isEmpty {
            reorderHeap[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var smallest = i
                if l < reorderHeap.count, reorderHeap[l].ptsNs < reorderHeap[smallest].ptsNs { smallest = l }
                if r < reorderHeap.count, reorderHeap[r].ptsNs < reorderHeap[smallest].ptsNs { smallest = r }
                if smallest == i { break }
                reorderHeap.swapAt(i, smallest)
                i = smallest
            }
        }
        return top
    }
}
