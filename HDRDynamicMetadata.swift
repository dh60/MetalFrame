import Foundation

// Dynamic HDR metadata extraction: per-frame/scene brightness statistics from
// the video bitstream, feeding the renderer's tone mapper.
//
// Two sources, in preference order:
//  - HDR10+ (SMPTE ST 2094-40): HEVC prefix-SEI payload type 4, an ITU-T T.35
//    Samsung message carrying per-scene maxRGB stats (maxscl, average,
//    percentiles). Bit layout cross-checked against ffmpeg's
//    av_dynamic_hdr_plus_from_t35.
//  - Dolby Vision RPU (NAL type 62, profiles 8.x): the vdr_dm_data Level 1
//    extension block carries min/max/avg scene brightness as 12-bit PQ codes.
//    Structure follows dovi_tool's rpu_data_header / rpu_data_mapping /
//    vdr_dm_data parsers. We traverse the (variable-length) mapping payload
//    only to reach the DM data — composer/mapping itself is not applied.
//
// Neither is exposed by VideoToolbox (verified empirically), which is why the
// engine reads the NALs itself. Everything here is defensive: any structural
// surprise aborts that frame's parse and playback continues without dynamic
// metadata (the renderer falls back to static MaxCLL/mastering peak).

struct SceneLightInfo {
    enum Source { case hdr10Plus, doviL1 }
    var peakNits: Double        // scene max component brightness
    var avgNits: Double         // scene average maxRGB brightness
    var source: Source

    var sourceLabel: String {
        switch source {
        case .hdr10Plus: return "HDR10+"
        case .doviL1: return "DoVi L1"
        }
    }
}

// MARK: - PQ helpers (ST 2084)

func pqEncodeNits(_ nits: Double) -> Double {
    let y = max(min(nits / 10000.0, 1.0), 0.0)
    let m1 = 2610.0 / 16384.0
    let m2 = 2523.0 * 128.0 / 4096.0
    let c1 = 3424.0 / 4096.0
    let c2 = 2413.0 * 32.0 / 4096.0
    let c3 = 2392.0 * 32.0 / 4096.0
    let yp = pow(y, m1)
    return pow((c1 + c2 * yp) / (1 + c3 * yp), m2)
}

func pqDecodeToNits(_ e: Double) -> Double {
    let ec = max(min(e, 1.0), 0.0)
    let m1 = 2610.0 / 16384.0
    let m2 = 2523.0 * 128.0 / 4096.0
    let c1 = 3424.0 / 4096.0
    let c2 = 2413.0 * 32.0 / 4096.0
    let c3 = 2392.0 * 32.0 / 4096.0
    let p = pow(ec, 1.0 / m2)
    let num = max(p - c1, 0.0)
    let den = c2 - c3 * p
    guard den > 0 else { return 0 }
    return 10000.0 * pow(num / den, 1.0 / m1)
}

// MARK: - Bit reader

// MSB-first bit reader over a de-escaped RBSP. All reads are bounds-checked;
// running off the end returns nil so malformed data can't wedge the parse.
private struct BitReader {
    let bytes: [UInt8]
    var bitPos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var bitsLeft: Int { bytes.count * 8 - bitPos }

    mutating func read(_ n: Int) -> UInt32? {
        guard n <= 32, bitsLeft >= n else { return nil }
        var v: UInt32 = 0
        for _ in 0..<n {
            let byte = bytes[bitPos >> 3]
            v = (v << 1) | UInt32((byte >> (7 - UInt8(bitPos & 7))) & 1)
            bitPos += 1
        }
        return v
    }

    mutating func skip(_ n: Int) -> Bool {
        guard bitsLeft >= n else { return false }
        bitPos += n
        return true
    }

    // Exp-Golomb ue(v), capped to keep hostile data from looping.
    mutating func readUE() -> UInt32? {
        var zeros = 0
        while true {
            guard let b = read(1) else { return nil }
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard zeros > 0 else { return 0 }
        guard let rest = read(zeros) else { return nil }
        return (1 << zeros) - 1 + rest
    }

    mutating func readSE() -> Int32? {
        guard let ue = readUE() else { return nil }
        let k = Int64(ue) + 1
        return Int32(truncatingIfNeeded: (k & 1) == 0 ? k / 2 : -(k / 2))
    }

    mutating func byteAlign() -> Bool {
        let rem = bitPos & 7
        return rem == 0 ? true : skip(8 - rem)
    }
}

// Strip start-code emulation prevention (00 00 03 -> 00 00).
func deEscapeRBSP(_ data: ArraySlice<UInt8>) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(data.count)
    var zeros = 0
    for b in data {
        if zeros >= 2 && b == 3 { zeros = 0; continue }
        zeros = (b == 0) ? zeros + 1 : 0
        out.append(b)
    }
    return out
}

// MARK: - HDR10+ (ST 2094-40)

// `t35` is the SEI payload for payload type 4, starting at the T.35 country
// code. Returns nil unless it's the Samsung ST 2094-40 message.
func parseHDR10PlusSEI(t35 payload: [UInt8]) -> SceneLightInfo? {
    // itu_t_t35: country 0xB5, provider 0x003C, provider_oriented 0x0001,
    // application_identifier 4.
    guard payload.count > 7,
          payload[0] == 0xB5,
          payload[1] == 0x00, payload[2] == 0x3C,
          payload[3] == 0x00, payload[4] == 0x01,
          payload[5] == 0x04 else { return nil }

    var r = BitReader(Array(payload[6...]))
    guard r.skip(8) else { return nil }                      // application_version
    guard let numWindows = r.read(2), (1...3).contains(numWindows) else { return nil }
    // Elliptical processing windows beyond the first: 153 bits of geometry each.
    for _ in 1..<numWindows {
        guard r.skip(153) else { return nil }
    }
    guard r.skip(27) else { return nil }                     // targeted_system_display_maximum_luminance
    guard let targetedPeakFlag = r.read(1) else { return nil }
    if targetedPeakFlag == 1 {
        guard let rows = r.read(5), let cols = r.read(5),
              r.skip(Int(rows) * Int(cols) * 4) else { return nil }
    }

    // Window 0 statistics are all the tone mapper needs; further windows and
    // the Bezier curve section never affect them, so parsing stops here.
    guard let scl0 = r.read(17), let scl1 = r.read(17), let scl2 = r.read(17),
          let avg = r.read(17) else { return nil }
    var peakRaw = max(scl0, max(scl1, scl2))
    guard let numPercentiles = r.read(4) else { return nil }
    var highestPercentile: UInt32 = 0
    for _ in 0..<numPercentiles {
        guard r.skip(7), let v = r.read(17) else { return nil }
        highestPercentile = max(highestPercentile, v)
    }
    // Some encoders zero maxscl and publish only the percentile ladder.
    if peakRaw == 0 { peakRaw = highestPercentile }
    guard peakRaw > 0 else { return nil }

    // Values are linearized maxRGB in units of 1/100000 of full scale
    // (10000 nits): nits = raw / 10.
    return SceneLightInfo(peakNits: Double(peakRaw) / 10.0,
                          avgNits: Double(avg) / 10.0,
                          source: .hdr10Plus)
}

// MARK: - Dolby Vision RPU (profiles 8.x)

// `rpu` is the de-escaped NAL payload after the 2-byte NAL header, starting
// at the 0x19 rpu_nal_prefix. Traverses header + mapping to reach vdr_dm_data
// and returns the Level 1 scene statistics.
func parseDolbyVisionRPU(rpu: [UInt8]) -> SceneLightInfo? {
    guard rpu.count > 8, rpu[0] == 0x19 else { return nil }
    var r = BitReader(Array(rpu[1...]))

    // --- rpu_data_header ---
    guard let rpuType = r.read(6), rpuType == 2,
          let rpuFormat = r.read(11),
          r.skip(4 + 4),                                     // vdr_rpu_profile, vdr_rpu_level
          let seqInfoPresent = r.read(1) else { return nil }
    var coefficientDataType: UInt32 = 0
    var coefficientLog2Denom: UInt32 = 23
    var blBitDepth = 10
    var disableResidual = true
    if seqInfoPresent == 1 {
        guard r.skip(1),                                     // chroma_resampling_explicit_filter_flag
              let cdt = r.read(2) else { return nil }
        coefficientDataType = cdt
        if cdt == 0 {
            guard let denom = r.readUE(), denom <= 32 else { return nil }
            coefficientLog2Denom = denom
        }
        guard r.skip(2 + 1) else { return nil }              // vdr_rpu_normalized_idc, bl_video_full_range
        if rpuFormat & 0x700 == 0 {
            guard let bl = r.readUE(), bl <= 8,
                  r.readUE() != nil,                         // el_bit_depth_minus8 (+ext_mapping_idc packed)
                  r.readUE() != nil,                         // vdr_bit_depth_minus8
                  r.skip(1 + 3 + 1),                         // spatial_resampling, reserved, el_spatial_resampling
                  let dis = r.read(1) else { return nil }
            blBitDepth = Int(bl) + 8
            disableResidual = dis == 1
        }
    }
    guard let dmPresent = r.read(1),
          let usePrevRPU = r.read(1) else { return nil }
    guard dmPresent == 1 else { return nil }                 // no DM data → nothing for us

    // --- rpu_data_mapping (skipped field-by-field; variable length) ---
    if usePrevRPU == 1 {
        guard r.readUE() != nil else { return nil }          // prev_vdr_rpu_id
    } else {
        guard r.readUE() != nil,                             // vdr_rpu_id
              r.readUE() != nil,                             // mapping_color_space
              r.readUE() != nil else { return nil }          // mapping_chroma_format_idc
        var numPivots = [Int](repeating: 0, count: 3)
        for c in 0..<3 {
            guard let pivotsMinus2 = r.readUE(), pivotsMinus2 <= 6 else { return nil }
            numPivots[c] = Int(pivotsMinus2) + 2
            guard r.skip(numPivots[c] * blBitDepth) else { return nil }
        }
        if rpuFormat & 0x700 == 0 && !disableResidual {
            // Profile 7 dual-layer NLQ pivots (3 pivots at BL depth + method).
            guard r.skip(3), r.skip(2 * blBitDepth) else { return nil }
        }
        guard r.readUE() != nil,                             // num_x_partitions_minus1
              r.readUE() != nil else { return nil }          // num_y_partitions_minus1
        let coefBits = Int(coefficientLog2Denom)
        for c in 0..<3 {
            for _ in 0..<(numPivots[c] - 1) {
                guard let mappingIdc = r.readUE() else { return nil }
                if mappingIdc == 0 {                         // polynomial
                    guard let polyOrderMinus1 = r.readUE(), polyOrderMinus1 <= 1 else { return nil }
                    var linearInterp = false
                    if polyOrderMinus1 == 0 {
                        guard let li = r.read(1) else { return nil }
                        linearInterp = li == 1
                    }
                    guard !linearInterp else { return nil }  // legacy; never in 8.x
                    for _ in 0...(Int(polyOrderMinus1) + 1) {
                        if coefficientDataType == 0 {
                            guard r.readSE() != nil else { return nil }
                        }
                        guard r.skip(coefBits) else { return nil }
                    }
                } else if mappingIdc == 1 {                  // MMR
                    guard let mmrOrderMinus1 = r.read(2), mmrOrderMinus1 <= 2 else { return nil }
                    if coefficientDataType == 0 {
                        guard r.readSE() != nil else { return nil }
                    }
                    guard r.skip(coefBits) else { return nil }
                    for _ in 0..<((Int(mmrOrderMinus1) + 1) * 7) {
                        if coefficientDataType == 0 {
                            guard r.readSE() != nil else { return nil }
                        }
                        guard r.skip(coefBits) else { return nil }
                    }
                } else {
                    return nil
                }
            }
        }
        if rpuFormat & 0x700 == 0 && !disableResidual {
            return nil                                       // profile 7 NLQ payload: out of scope
        }
    }

    // --- vdr_dm_data_payload ---
    guard r.readUE() != nil,                                 // affected_dm_metadata_id
          r.readUE() != nil,                                 // current_dm_metadata_id
          r.readUE() != nil,                                 // scene_refresh_flag
          r.skip(9 * 16 + 3 * 32),                           // ycc_to_rgb coefs + offsets
          r.skip(9 * 16),                                    // rgb_to_lms coefs
          r.skip(16 + 16 + 16 + 32),                         // signal_eotf + params
          r.skip(5 + 2 + 2 + 2),                             // bit depth, color space, chroma, range
          r.skip(12 + 12 + 10)                               // source min/max pq, diagonal
    else { return nil }

    // Extension blocks; Level 1 = scene min/max/avg as 12-bit PQ codes.
    guard let numExtBlocks = r.readUE(), numExtBlocks <= 254,
          r.byteAlign() else { return nil }
    for _ in 0..<numExtBlocks {
        guard let blockLength = r.readUE(), blockLength <= 1024,
              let blockLevel = r.read(8) else { return nil }
        if blockLevel == 1, blockLength >= 5 {
            guard r.skip(12),                                // min_pq
                  let maxPQ = r.read(12),
                  let avgPQ = r.read(12) else { return nil }
            return SceneLightInfo(peakNits: pqDecodeToNits(Double(maxPQ) / 4095.0),
                                  avgNits: pqDecodeToNits(Double(avgPQ) / 4095.0),
                                  source: .doviL1)
        }
        guard r.skip(Int(blockLength) * 8) else { return nil }
    }
    return nil
}

// MARK: - Per-sample extraction

// Walk one HEVC sample's length-prefixed NALs for dynamic HDR metadata.
// HDR10+ wins over DV L1 when a frame carries both (finer-grained stats).
func extractSceneLight(sampleData: Data, codecID: String, codecPrivate: Data?) -> SceneLightInfo? {
    guard codecID == "V_MPEGH/ISO/HEVC" else { return nil }
    var lengthSize = 4
    if let p = codecPrivate {
        let b = [UInt8](p)
        if b.count > 21 { lengthSize = Int(b[21] & 0x3) + 1 }
    }
    let bytes = [UInt8](sampleData)
    var dovi: SceneLightInfo?
    var off = 0
    while off + lengthSize <= bytes.count {
        var nalLen = 0
        for i in 0..<lengthSize { nalLen = (nalLen << 8) | Int(bytes[off + i]) }
        off += lengthSize
        guard nalLen > 0, off + nalLen <= bytes.count else { break }
        let nalType = Int(bytes[off] >> 1) & 0x3F

        if nalType == 39 || nalType == 40, nalLen > 2 {      // prefix/suffix SEI
            let rbsp = deEscapeRBSP(bytes[(off + 2)..<(off + nalLen)])
            var p = 0
            while p + 1 < rbsp.count, rbsp[p] != 0x80 {
                var type = 0
                while p < rbsp.count, rbsp[p] == 0xFF { type += 255; p += 1 }
                guard p < rbsp.count else { break }
                type += Int(rbsp[p]); p += 1
                var size = 0
                while p < rbsp.count, rbsp[p] == 0xFF { size += 255; p += 1 }
                guard p < rbsp.count else { break }
                size += Int(rbsp[p]); p += 1
                guard p + size <= rbsp.count else { break }
                if type == 4,                                 // user_data_registered_itu_t_t35
                   let info = parseHDR10PlusSEI(t35: Array(rbsp[p..<p + size])) {
                    return info
                }
                p += size
            }
        } else if nalType == 62, nalLen > 3, dovi == nil {    // DV RPU
            dovi = parseDolbyVisionRPU(rpu: deEscapeRBSP(bytes[(off + 2)..<(off + nalLen)]))
        }
        off += nalLen
    }
    return dovi
}
