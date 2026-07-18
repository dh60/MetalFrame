import Foundation

// Hand-written DTS Coherent Acoustics core decoder (ETSI TS 102 114 clauses
// 5.4-5.6, Annex C algorithms, Annex D tables). Decodes the core substream
// only: up to 5 primary channels + LFE, 8-48 kHz, all core coding tools
// (Huffman/block/linear quantization, ADPCM prediction, high-frequency VQ,
// joint intensity coding, sum/difference, transients). Extension payloads
// (XCh/X96/XBR/EXSS incl. DTS-HD) inside or after the core frame are skipped
// by frame-size accounting — DTS-HD MA streams decode as their embedded core.
// Embedded DRC and dialog normalization are parsed but not applied (matches
// common player behavior and the ffmpeg reference the SNR harness compares
// against).

enum DTSError: Error, CustomStringConvertible {
    case badSync
    case corrupt(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .badSync: return "DTS: no sync"
        case .corrupt(let s): return "DTS corrupt: \(s)"
        case .unsupported(let s): return "DTS unsupported: \(s)"
        }
    }
}

struct DTSDecodedFrame {
    let sampleRate: Int
    let channelCount: Int          // primary channels + LFE if present
    let samplesPerChannel: Int
    let hasLFE: Bool
    let amode: Int
    // Interleaved Float32 in output order (FL FR FC LFE Ls Rs style — matches
    // both CoreAudio's MPEG layouts and ffmpeg's native order, so the SNR
    // harness compares files directly).
    let pcm: [Float]
}

// MARK: - Bit reader (MSB first)

private struct BitReader {
    let bytes: [UInt8]
    var bitPos: Int = 0
    var bitsLeft: Int { bytes.count * 8 - bitPos }

    mutating func bit() throws -> UInt32 {
        guard bitPos < bytes.count * 8 else { throw DTSError.corrupt("out of bits") }
        let v = (bytes[bitPos >> 3] >> (7 - (bitPos & 7))) & 1
        bitPos += 1
        return UInt32(v)
    }

    mutating func bits(_ n: Int) throws -> UInt32 {
        guard n <= 32, bitPos + n <= bytes.count * 8 else { throw DTSError.corrupt("out of bits") }
        var v: UInt32 = 0
        var remaining = n
        while remaining > 0 {
            let byteIdx = bitPos >> 3
            let bitInByte = bitPos & 7
            let take = min(8 - bitInByte, remaining)
            let chunk = (UInt32(bytes[byteIdx]) >> (8 - bitInByte - take)) & ((1 << take) - 1)
            v = (v << take) | chunk
            bitPos += take
            remaining -= take
        }
        return v
    }

    // n-bit two's complement
    mutating func sbits(_ n: Int) throws -> Int32 {
        let v = try bits(n)
        let shift = 32 - n
        return Int32(bitPattern: v << shift) >> shift
    }
}

// MARK: - Huffman codebook (canonical (level, length, code) triples from Annex D.5)

struct DTSHuffmanBook {
    let maxLen: Int
    // key = length << 24 | code
    let map: [UInt32: Int32]

    init(_ triples: [[Int32]]) {
        var m: [UInt32: Int32] = [:]
        var maxL = 1
        for t in triples {
            let level = t[0], len = Int(t[1]), code = UInt32(t[2])
            m[UInt32(len) << 24 | code] = level
            maxL = max(maxL, len)
        }
        maxLen = maxL
        map = m
    }
}

private func huffDecode(_ br: inout BitReader, _ book: DTSHuffmanBook) throws -> Int32 {
    var code: UInt32 = 0
    for len in 1...book.maxLen {
        code = (code << 1) | (try br.bit())
        if let sym = book.map[UInt32(len) << 24 | code] { return sym }
    }
    throw DTSError.corrupt("huffman code not in book")
}

// MARK: - Frame header

private struct CoreHeader {
    var normalFrame = true
    var deficitSamples = 0
    var crcPresent = false
    var pcmBlocks = 0            // 32-sample blocks per channel
    var frameBytes = 0
    var amode = 0
    var sampleRate = 0
    var rateIndex = 0
    var drcPresent = false
    var timestampPresent = false
    var auxPresent = false
    var extAudioID = 0
    var extAudio = false
    var syncEverySubsubframe = false   // ASPF
    var lfeFlag = 0                    // LFF: 0 none, 1 = 128x interp, 2 = 64x
    var useHistory = true              // HFLAG
    var perfectFilter = false          // FILTS
}

// MARK: - Channel arrangement (Table 5-4)

// DTS transmits primary channels in its own order (centre first for 3/2 etc.).
// outputMap[i] = index into the DTS primary-channel array for output slot i;
// LFE (if present) is inserted at output slot lfeOutputSlot. The output order
// follows the FL FR FC LFE ... convention shared by CoreAudio MPEG layouts and
// ffmpeg's native order.
private struct ChannelArrangement {
    let primaries: Int
    let outputMap: [Int]
    let lfeOutputSlot: Int        // slot LFE occupies when present
    let frontPair: (Int, Int)?    // DTS indices for SUMF decode
    let surroundPair: (Int, Int)? // DTS indices for SUMS decode
}

private func channelArrangement(amode: Int) throws -> ChannelArrangement {
    switch amode {
    case 0:  return .init(primaries: 1, outputMap: [0], lfeOutputSlot: 1, frontPair: nil, surroundPair: nil)
    case 1:  return .init(primaries: 2, outputMap: [0, 1], lfeOutputSlot: 2, frontPair: nil, surroundPair: nil)
    case 2, 3, 4:
        // L+R stereo, (L+R)(L-R) sum-diff (decoded to L/R), Lt/Rt
        return .init(primaries: 2, outputMap: [0, 1], lfeOutputSlot: 2, frontPair: (0, 1), surroundPair: nil)
    case 5:  // C L R -> L R C
        return .init(primaries: 3, outputMap: [1, 2, 0], lfeOutputSlot: 3, frontPair: (1, 2), surroundPair: nil)
    case 6:  // L R S -> L R (LFE) S
        return .init(primaries: 3, outputMap: [0, 1, 2], lfeOutputSlot: 2, frontPair: (0, 1), surroundPair: nil)
    case 7:  // C L R S -> L R C S
        return .init(primaries: 4, outputMap: [1, 2, 0, 3], lfeOutputSlot: 3, frontPair: (1, 2), surroundPair: nil)
    case 8:  // L R SL SR
        return .init(primaries: 4, outputMap: [0, 1, 2, 3], lfeOutputSlot: 2, frontPair: (0, 1), surroundPair: (2, 3))
    case 9:  // C L R SL SR -> L R C SL SR
        return .init(primaries: 5, outputMap: [1, 2, 0, 3, 4], lfeOutputSlot: 3, frontPair: (1, 2), surroundPair: (3, 4))
    default:
        throw DTSError.unsupported("AMODE \(amode)")
    }
}

// MARK: - Decoder

final class DTSDecoder {
    static let numSubbands = 32

    // Cross-frame filter state, per primary channel
    private var qmfHistory: [[Double]] = []      // 512 each
    private var qmfOverlap: [[Double]] = []      // 64 each
    private var adpcmHistory: [[Double]] = []    // 32 bands × 4, flattened [band*4+k]
    private var lfeHistory = [Double](repeating: 0, count: 8)
    private var stateChannels = -1

    // QMF output gain: the Annex D scale-factor tables put subband samples in
    // a 24-bit-ish integer domain and the C.3.6 filterbank contributes its own
    // constant; the net full-scale normalization is exactly 2^-15.5 (measured
    // against the reference decode by least-squares fit: 2^7.5 relative to a
    // 2^-23 provisional, matching to the fit's precision at 106 dB SNR).
    private let outputGain = Double(2).squareRoot() / 65536.0
    // The LFE path bypasses the QMF and with it the filterbank's 2^7.5 net
    // gain, so it normalizes straight from the scale-factor domain.
    private let lfeGain = 1.0 / Double(1 << 23)

    // Cosine modulation coefficients, precomputed per Annex C.3.6 PreCalCosMod.
    private static let cosMod: [Double] = {
        var t = [Double]()
        t.reserveCapacity(544)
        for k in 0..<16 {
            for i in 0..<16 { t.append(cos(Double(2 * i + 1) * Double(2 * k + 1) * .pi / 64)) }
        }
        for k in 0..<16 {
            for i in 0..<16 { t.append(cos(Double(i) * Double(2 * k + 1) * .pi / 32)) }
        }
        for k in 0..<16 { t.append(0.25 / (2 * cos(Double(2 * k + 1) * .pi / 128))) }
        for k in 0..<16 { t.append(-0.25 / (2 * sin(Double(2 * k + 1) * .pi / 128))) }
        return t
    }()

    private static let sampleRates = [0, 8000, 16000, 32000, 0, 0, 11025, 22050,
                                      44100, 0, 0, 12000, 24000, 48000, 0, 0]

    func reset() {
        stateChannels = -1
        lfeHistory = [Double](repeating: 0, count: 8)
    }

    private func ensureState(channels: Int) {
        guard channels != stateChannels else { return }
        stateChannels = channels
        qmfHistory = Array(repeating: [Double](repeating: 0, count: 512), count: channels)
        qmfOverlap = Array(repeating: [Double](repeating: 0, count: 64), count: channels)
        adpcmHistory = Array(repeating: [Double](repeating: 0, count: Self.numSubbands * 4), count: channels)
        lfeHistory = [Double](repeating: 0, count: 8)
    }

    // Decode every complete core frame in the packet. Damaged frames are
    // skipped (logged), never fatal — the pipeline must not stall on one bad
    // frame mid-file.
    func decode(packet: Data) -> [DTSDecodedFrame] {
        let stream = normalizeTo16BitBE(packet)
        var frames: [DTSDecodedFrame] = []
        var offset = 0
        while let sync = findCoreSync(stream, from: offset) {
            // FSIZE is bits 46..59 relative to sync start
            guard sync + 8 <= stream.count else { break }
            let fsize = ((Int(stream[sync + 5]) & 0x03) << 12)
                      | (Int(stream[sync + 6]) << 4)
                      | (Int(stream[sync + 7]) >> 4)
            let frameLen = fsize + 1
            guard frameLen >= 96 else { offset = sync + 4; continue }
            guard sync + frameLen <= stream.count else { break }
            do {
                let frame = try decodeCoreFrame(Array(stream[sync..<(sync + frameLen)]))
                frames.append(frame)
                offset = sync + frameLen
            } catch {
                NSLog("MetalFrame DTS: frame at +\(sync) dropped: \(error)")
                // Don't trust this frame's size field — rescan just past its sync.
                offset = sync + 4
            }
        }
        return frames
    }

    // MARK: Stream normalization (16-bit LE / 14-bit BE / 14-bit LE -> 16-bit BE)

    private func normalizeTo16BitBE(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        guard b.count >= 16 else { return b }
        // 16-bit BE core sync 0x7FFE8001 — the normal case, return as-is.
        if b[0] == 0x7F && b[1] == 0xFE && b[2] == 0x80 && b[3] == 0x01 { return b }
        // 16-bit LE: 0xFE7F0180
        if b[0] == 0xFE && b[1] == 0x7F && b[2] == 0x01 && b[3] == 0x80 {
            var out = [UInt8](repeating: 0, count: b.count & ~1)
            for i in stride(from: 0, to: out.count, by: 2) {
                out[i] = b[i + 1]; out[i + 1] = b[i]
            }
            return out
        }
        // 14-bit variants: each 16-bit word carries 14 payload bits.
        // BE: 0x1FFF, 0xE800...; LE: 0xFF1F, 0x00E8...
        let is14BE = b[0] == 0x1F && b[1] == 0xFF && b[2] == 0xE8 && b[3] == 0x00
        let is14LE = b[0] == 0xFF && b[1] == 0x1F && b[2] == 0x00 && b[3] == 0xE8
        if is14BE || is14LE {
            var out = [UInt8]()
            out.reserveCapacity(b.count * 14 / 16 + 2)
            var acc: UInt32 = 0
            var accBits = 0
            for i in stride(from: 0, to: b.count & ~1, by: 2) {
                let word = is14BE ? (UInt16(b[i]) << 8 | UInt16(b[i + 1]))
                                  : (UInt16(b[i + 1]) << 8 | UInt16(b[i]))
                acc = (acc << 14) | UInt32(word & 0x3FFF)
                accBits += 14
                while accBits >= 8 {
                    out.append(UInt8((acc >> (accBits - 8)) & 0xFF))
                    accBits -= 8
                }
            }
            return out
        }
        return b   // unknown leader; the sync scanner will search within
    }

    private func findCoreSync(_ b: [UInt8], from: Int) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = max(0, from)
        while i + 4 <= b.count {
            if b[i] == 0x7F && b[i + 1] == 0xFE && b[i + 2] == 0x80 && b[i + 3] == 0x01 { return i }
            i += 1
        }
        return nil
    }

    // MARK: Core frame

    private func decodeCoreFrame(_ frame: [UInt8]) throws -> DTSDecodedFrame {
        var br = BitReader(bytes: frame)
        _ = try br.bits(32)   // sync, validated by caller

        var h = CoreHeader()
        h.normalFrame = try br.bits(1) == 1
        h.deficitSamples = Int(try br.bits(5))
        h.crcPresent = try br.bits(1) == 1
        let nblks = Int(try br.bits(7))
        guard nblks >= 5 else { throw DTSError.corrupt("NBLKS \(nblks)") }
        h.pcmBlocks = nblks + 1
        h.frameBytes = Int(try br.bits(14)) + 1
        h.amode = Int(try br.bits(6))
        let sfreqIdx = Int(try br.bits(4))
        h.sampleRate = Self.sampleRates[sfreqIdx]
        guard h.sampleRate > 0 else { throw DTSError.corrupt("SFREQ \(sfreqIdx)") }
        h.rateIndex = Int(try br.bits(5))
        _ = try br.bits(1)                       // FixedBit
        h.drcPresent = try br.bits(1) == 1
        h.timestampPresent = try br.bits(1) == 1
        h.auxPresent = try br.bits(1) == 1
        _ = try br.bits(1)                       // HDCD
        h.extAudioID = Int(try br.bits(3))
        h.extAudio = try br.bits(1) == 1
        h.syncEverySubsubframe = try br.bits(1) == 1
        h.lfeFlag = Int(try br.bits(2))
        guard h.lfeFlag != 3 else { throw DTSError.corrupt("LFF 3") }
        h.useHistory = try br.bits(1) == 1
        if h.crcPresent { _ = try br.bits(16) }  // HCRC (not verified, per spec)
        h.perfectFilter = try br.bits(1) == 1
        let vernum = Int(try br.bits(4))
        guard vernum <= 7 else { throw DTSError.unsupported("VERNUM \(vernum)") }
        _ = try br.bits(2)                       // CHIST
        _ = try br.bits(3)                       // PCMR
        let sumF = try br.bits(1) == 1
        let sumS = try br.bits(1) == 1
        _ = try br.bits(4)                       // DIALNORM/UNSPEC (not applied)

        let arrangement = try channelArrangement(amode: h.amode)

        // --- Primary audio coding header (Table 5-21) ---
        let nSubframes = Int(try br.bits(4)) + 1
        let nCh = Int(try br.bits(3)) + 1
        guard nCh == arrangement.primaries else {
            // Extended channels beyond 5 live in extension arrays we skip; the
            // core primary count must still match a supported arrangement.
            throw DTSError.unsupported("PCHS \(nCh) vs AMODE \(h.amode)")
        }
        var nSubs = [Int](repeating: 0, count: nCh)      // active subbands
        var nVQStart = [Int](repeating: 0, count: nCh)   // first VQ subband
        var joinX = [Int](repeating: 0, count: nCh)
        var tHuff = [Int](repeating: 0, count: nCh)
        var sHuff = [Int](repeating: 0, count: nCh)
        var bHuff = [Int](repeating: 0, count: nCh)
        for ch in 0..<nCh { nSubs[ch] = Int(try br.bits(5)) + 2 }
        for ch in 0..<nCh { nVQStart[ch] = Int(try br.bits(5)) + 1 }
        for ch in 0..<nCh { joinX[ch] = Int(try br.bits(3)) }
        for ch in 0..<nCh { tHuff[ch] = Int(try br.bits(2)) }
        for ch in 0..<nCh { sHuff[ch] = Int(try br.bits(3)) }
        for ch in 0..<nCh { bHuff[ch] = Int(try br.bits(3)) }
        for ch in 0..<nCh {
            guard nSubs[ch] <= Self.numSubbands, sHuff[ch] != 7, bHuff[ch] != 7 else {
                throw DTSError.corrupt("audio header ch\(ch)")
            }
            // VQ start beyond the active range means no VQ subbands.
            nVQStart[ch] = min(nVQStart[ch], nSubs[ch])
        }

        // SEL: quantization index codebook select, per codebook group 0..9
        // (ABITS 1..10). Groups 11+ always use plain binary (Table 5-26).
        var sel = Array(repeating: [Int](repeating: 0, count: 10), count: nCh)
        for ch in 0..<nCh { sel[ch][0] = Int(try br.bits(1)) }
        for n in 1..<5 { for ch in 0..<nCh { sel[ch][n] = Int(try br.bits(2)) } }
        for n in 5..<10 { for ch in 0..<nCh { sel[ch][n] = Int(try br.bits(3)) } }

        // Scale-factor adjustment, transmitted only when SEL picked a Huffman book.
        var adj = Array(repeating: [Double](repeating: 1.0, count: 10), count: nCh)
        for ch in 0..<nCh where sel[ch][0] == 0 {
            adj[ch][0] = DTSTables.scaleFactorAdj[Int(try br.bits(2))]
        }
        for n in 1..<5 { for ch in 0..<nCh where sel[ch][n] < 3 {
            adj[ch][n] = DTSTables.scaleFactorAdj[Int(try br.bits(2))]
        } }
        for n in 5..<10 { for ch in 0..<nCh where sel[ch][n] < 7 {
            adj[ch][n] = DTSTables.scaleFactorAdj[Int(try br.bits(2))]
        } }
        if h.crcPresent { _ = try br.bits(16) }  // AHCRC

        // --- Per-frame working buffers ---
        let pcmPerChannel = h.pcmBlocks * 32
        let subbandLen = h.pcmBlocks           // one subband sample per 32 PCM
        var subband = Array(repeating: [Double](repeating: 0, count: Self.numSubbands * subbandLen), count: nCh)
        var lfeSamples: [Double] = []
        let stepTable = h.rateIndex == 0x1F ? DTSTables.stepSizeLossless : DTSTables.stepSizeLossy

        ensureState(channels: nCh)
        if !h.useHistory {
            for ch in 0..<nCh { adpcmHistory[ch] = [Double](repeating: 0, count: Self.numSubbands * 4) }
        }

        var frameSampleBase = 0   // subband-sample index where this subframe starts

        for _ in 0..<nSubframes {
            // --- Side information (Table 5-28) ---
            let nSSC = Int(try br.bits(2)) + 1
            _ = try br.bits(3)   // PSC (partial subsubframe, termination frames only)
            let subframeSamples = nSSC * 8
            guard frameSampleBase + subframeSamples <= subbandLen else {
                throw DTSError.corrupt("subframe overrun")
            }

            var pmode = Array(repeating: [Bool](repeating: false, count: Self.numSubbands), count: nCh)
            var predVQ = Array(repeating: [[Double]](repeating: [0, 0, 0, 0], count: Self.numSubbands), count: nCh)
            for ch in 0..<nCh { for n in 0..<nSubs[ch] { pmode[ch][n] = try br.bits(1) == 1 } }
            for ch in 0..<nCh { for n in 0..<nSubs[ch] where pmode[ch][n] {
                predVQ[ch][n] = DTSTables.adpcmCoeffs[Int(try br.bits(12))]
            } }

            var abits = Array(repeating: [Int](repeating: 0, count: Self.numSubbands), count: nCh)
            for ch in 0..<nCh {
                for n in 0..<nVQStart[ch] {
                    let v: Int
                    switch bHuff[ch] {
                    case 6: v = Int(try br.bits(5))
                    case 5: v = Int(try br.bits(4))
                    default: v = Int(try huffDecode(&br, DTSTables.huffBitAlloc[bHuff[ch]]))
                    }
                    guard v >= 0, v <= 26 else { throw DTSError.corrupt("ABITS \(v)") }
                    abits[ch][n] = v
                }
            }

            var tmode = Array(repeating: [Int](repeating: 0, count: Self.numSubbands), count: nCh)
            if nSSC > 1 {
                for ch in 0..<nCh {
                    for n in 0..<nVQStart[ch] where abits[ch][n] > 0 {
                        tmode[ch][n] = Int(try huffDecode(&br, DTSTables.huffTransientMode[tHuff[ch]]))
                    }
                }
            }

            // Scale factors: differential when Huffman-coded (SHUFF < 5).
            var scales = Array(repeating: [[Double]](repeating: [0, 0], count: Self.numSubbands), count: nCh)
            for ch in 0..<nCh {
                let sevenBit = sHuff[ch] == 6
                let table = sevenBit ? DTSTables.scaleFactorQuant7 : DTSTables.scaleFactorQuant6
                var accum = 0
                func nextScale() throws -> Double {
                    if sHuff[ch] < 5 {
                        accum += Int(try huffDecode(&br, DTSTables.huffScaleFactor[sHuff[ch]]))
                    } else {
                        accum = Int(try br.bits(sevenBit ? 7 : 6))
                    }
                    guard accum >= 0, accum < table.count else { throw DTSError.corrupt("scale idx \(accum)") }
                    return table[accum]
                }
                for n in 0..<nVQStart[ch] where abits[ch][n] > 0 {
                    scales[ch][n][0] = try nextScale()
                    scales[ch][n][1] = tmode[ch][n] > 0 ? try nextScale() : scales[ch][n][0]
                }
                for n in nVQStart[ch]..<nSubs[ch] {
                    scales[ch][n][0] = try nextScale()
                }
            }

            // Joint intensity coding scale factors (absolute, biased by 64).
            var joinScales = Array(repeating: [Double](repeating: 0, count: Self.numSubbands), count: nCh)
            var joinShuff = [Int](repeating: 0, count: nCh)
            for ch in 0..<nCh where joinX[ch] > 0 { joinShuff[ch] = Int(try br.bits(3)) }
            for ch in 0..<nCh where joinX[ch] > 0 {
                let src = joinX[ch] - 1
                guard src < nCh, nSubs[src] >= nSubs[ch] else { throw DTSError.corrupt("JOINX") }
                for n in nSubs[ch]..<nSubs[src] {
                    let idx: Int
                    if joinShuff[ch] < 5 {
                        idx = Int(try huffDecode(&br, DTSTables.huffScaleFactor[joinShuff[ch]])) + 64
                    } else {
                        idx = Int(try br.bits(joinShuff[ch] == 6 ? 7 : 6))
                    }
                    guard idx >= 0, idx < DTSTables.jointScaleFactors.count else {
                        throw DTSError.corrupt("joint scale idx")
                    }
                    joinScales[ch][n] = DTSTables.jointScaleFactors[idx]
                }
            }

            if h.drcPresent { _ = try br.bits(8) }   // RANGE (not applied)
            if h.crcPresent { _ = try br.bits(16) }  // SICRC

            // --- Data arrays (Table 5-29) ---
            // High-frequency VQ subbands: one 10-bit vector index covers the
            // whole subframe, scaled by the first scale factor.
            for ch in 0..<nCh {
                for n in nVQStart[ch]..<nSubs[ch] {
                    let vq = DTSTables.highFreqVQ[Int(try br.bits(10))]
                    let scale = scales[ch][n][0] * (1.0 / 16.0)
                    for m in 0..<subframeSamples {
                        subband[ch][n * subbandLen + frameSampleBase + m] = Double(vq[m]) * scale
                    }
                }
            }

            // LFE: 2*LFF*nSSC decimated samples + 8-bit scale index (7-bit RMS
            // table, 0.035 quantizer step).
            if h.lfeFlag > 0 {
                let count = 2 * h.lfeFlag * nSSC
                var raw = [Double](repeating: 0, count: count)
                for i in 0..<count { raw[i] = Double(try br.sbits(8)) }
                let scaleIdx = min(Int(try br.bits(8)), DTSTables.scaleFactorQuant7.count - 1)
                let scale = DTSTables.scaleFactorQuant7[scaleIdx] * 0.035
                for i in 0..<count { lfeSamples.append(raw[i] * scale) }
            }

            // Audio: nSSC subsubframes × 8 samples per subband.
            for ssf in 0..<nSSC {
                for ch in 0..<nCh {
                    for n in 0..<nVQStart[ch] {
                        let a = abits[ch][n]
                        var audio = [Double](repeating: 0, count: 8)
                        if a > 0 {
                            let groupIdx = a - 1
                            let s = groupIdx < 10 ? sel[ch][groupIdx] : 0
                            if a <= 10 && s < DTSTables.huffQuantBookCount[groupIdx] {
                                let book = DTSTables.huffQuant[groupIdx][s]
                                for m in 0..<8 { audio[m] = Double(try huffDecode(&br, book)) }
                            } else if a <= 7 {
                                // Block code: two codes of 4 samples each,
                                // base-L digits, offset to signed (Annex C.3.2).
                                let levels = DTSTables.quantLevels[a]
                                let codeBits = DTSTables.blockCodeBits[a]
                                let offsetVal = (levels - 1) / 2
                                for block in 0..<2 {
                                    var code = Int(try br.bits(codeBits))
                                    for m in 0..<4 {
                                        audio[block * 4 + m] = Double(code % levels - offsetVal)
                                        code /= levels
                                    }
                                    guard code == 0 else { throw DTSError.corrupt("block code") }
                                }
                            } else {
                                // No further encoding: (ABITS-3)-bit two's complement.
                                for m in 0..<8 { audio[m] = Double(try br.sbits(a - 3)) }
                            }
                        }
                        // Step size × scale factor (transient-aware) × adjustment.
                        let effTmode = tmode[ch][n] == 0 ? nSSC : tmode[ch][n]
                        var rScale = 0.0
                        if a > 0 {
                            let sf = ssf < effTmode ? scales[ch][n][0] : scales[ch][n][1]
                            var adjF = 1.0
                            if a <= 10 {
                                let g = a - 1
                                if sel[ch][g] < DTSTables.huffQuantBookCount[g] { adjF = adj[ch][g] }
                            }
                            rScale = stepTable[a] * sf * adjF
                        }
                        let bandStart = n * subbandLen
                        let pos0 = frameSampleBase + ssf * 8   // frame-relative position of audio[0]
                        if pmode[ch][n] {
                            // Inverse ADPCM over the scaled residual (C.3.3);
                            // history carried across subsubframes/subframes,
                            // and across frames via adpcmHistory (position -1
                            // = adpcmHistory[n*4+0], -2 = [n*4+1], ...).
                            let coeffs = predVQ[ch][n]
                            for m in 0..<8 {
                                var v = audio[m] * rScale
                                let p = pos0 + m
                                for k in 0..<4 {
                                    let q = p - k - 1
                                    let prior = q >= 0 ? subband[ch][bandStart + q]
                                                       : adpcmHistory[ch][n * 4 + (-q - 1)]
                                    v += coeffs[k] * prior
                                }
                                subband[ch][bandStart + p] = v
                            }
                        } else {
                            for m in 0..<8 { subband[ch][bandStart + pos0 + m] = audio[m] * rScale }
                        }
                    }
                }
                if ssf == nSSC - 1 || h.syncEverySubsubframe {
                    guard try br.bits(16) == 0xFFFF else { throw DTSError.corrupt("DSYNC") }
                }
            }

            // Joint intensity: copy scaled samples from the source channel.
            for ch in 0..<nCh where joinX[ch] > 0 {
                let src = joinX[ch] - 1
                for n in nSubs[ch]..<nSubs[src] {
                    let base = n * subbandLen + frameSampleBase
                    for m in 0..<subframeSamples {
                        subband[ch][base + m] = joinScales[ch][n] * subband[src][base + m]
                    }
                }
            }

            frameSampleBase += subframeSamples
        }

        // Update ADPCM history with the final reconstructed samples of every band.
        for ch in 0..<nCh {
            for n in 0..<Self.numSubbands {
                let base = n * subbandLen
                for k in 0..<4 {
                    adpcmHistory[ch][n * 4 + k] = subbandLen > k ? subband[ch][base + subbandLen - 1 - k] : 0
                }
            }
        }

        // Sum/difference decoding (Annex C.3.5) on subband samples.
        if sumF || h.amode == 3, let (l, r) = arrangement.frontPair {
            sumDifference(&subband, l, r)
        }
        if sumS, let (l, r) = arrangement.surroundPair {
            sumDifference(&subband, l, r)
        }

        // QMF synthesis per channel; joint channels interpolate up to the
        // source channel's activity.
        var effectiveSubs = nSubs
        for ch in 0..<nCh where joinX[ch] > 0 { effectiveSubs[ch] = nSubs[joinX[ch] - 1] }
        var chPCM = Array(repeating: [Double](repeating: 0, count: pcmPerChannel), count: nCh)
        for ch in 0..<nCh {
            qmfSynthesis(channel: ch, subband: subband[ch], subbandLen: subbandLen,
                         activeSubbands: effectiveSubs[ch], perfect: h.perfectFilter,
                         out: &chPCM[ch])
        }

        // LFE interpolation to the core sample rate.
        var lfePCM: [Double] = []
        if h.lfeFlag > 0 {
            lfePCM = lfeInterpolate(decimated: lfeSamples, factor: h.lfeFlag == 1 ? 128 : 64)
            if lfePCM.count != pcmPerChannel {
                lfePCM = Array((lfePCM + [Double](repeating: 0, count: pcmPerChannel)).prefix(pcmPerChannel))
            }
        }

        // Interleave into output order with LFE inserted at its slot.
        let hasLFE = h.lfeFlag > 0
        let outCh = nCh + (hasLFE ? 1 : 0)
        var order: [Int] = []   // output slot -> source (-1 = LFE)
        var srcIdx = 0
        for slot in 0..<outCh {
            if hasLFE && slot == arrangement.lfeOutputSlot {
                order.append(-1)
            } else {
                order.append(arrangement.outputMap[srcIdx]); srcIdx += 1
            }
        }
        var pcm = [Float](repeating: 0, count: outCh * pcmPerChannel)
        for slot in 0..<outCh {
            let src = order[slot]
            if src == -1 {
                for i in 0..<pcmPerChannel { pcm[i * outCh + slot] = Float(lfePCM[i] * lfeGain) }
            } else {
                for i in 0..<pcmPerChannel { pcm[i * outCh + slot] = Float(chPCM[src][i] * outputGain) }
            }
        }
        return DTSDecodedFrame(sampleRate: h.sampleRate, channelCount: outCh,
                               samplesPerChannel: pcmPerChannel, hasLFE: hasLFE,
                               amode: h.amode, pcm: pcm)
    }

    private func sumDifference(_ subband: inout [[Double]], _ l: Int, _ r: Int) {
        for i in 0..<subband[l].count {
            let s = subband[l][i] + subband[r][i]
            let d = subband[l][i] - subband[r][i]
            subband[l][i] = s; subband[r][i] = d
        }
    }

    // MARK: 32-band QMF synthesis (Annex C.3.6)

    private func qmfSynthesis(channel: Int, subband: [Double], subbandLen: Int,
                              activeSubbands: Int, perfect: Bool, out: inout [Double]) {
        let coeff = perfect ? DTSTables.fir32Perfect : DTSTables.fir32NonPerfect
        let cm = Self.cosMod
        var raX = qmfHistory[channel]
        var raZ = qmfOverlap[channel]
        var raXin = [Double](repeating: 0, count: 32)
        var A = [Double](repeating: 0, count: 16)
        var B = [Double](repeating: 0, count: 16)

        for step in 0..<subbandLen {
            for i in 0..<min(activeSubbands, 32) { raXin[i] = subband[i * subbandLen + step] }
            for i in activeSubbands..<32 { raXin[i] = 0 }

            var j = 0
            for k in 0..<16 {
                var acc = 0.0
                for i in 0..<16 { acc += (raXin[2 * i] + raXin[2 * i + 1]) * cm[j]; j += 1 }
                A[k] = acc
            }
            for k in 0..<16 {
                var acc = 0.0
                for i in 0..<16 {
                    acc += (i > 0 ? raXin[2 * i] + raXin[2 * i - 1] : raXin[0]) * cm[j]; j += 1
                }
                B[k] = acc
            }
            for k in 0..<16 { raX[k] = cm[j] * (A[k] + B[k]); j += 1 }
            for k in 0..<16 { raX[31 - k] = cm[j] * (A[k] - B[k]); j += 1 }

            for i in 0..<32 {
                let k = 31 - i
                var acc = raZ[i]
                var jj = 0
                while jj < 512 {
                    acc += coeff[i + jj] * (raX[i + jj] - raX[jj + k])
                    jj += 64
                }
                raZ[i] = acc
                var acc2 = raZ[32 + i]
                jj = 0
                while jj < 512 {
                    acc2 += coeff[32 + i + jj] * (-raX[i + jj] - raX[jj + k])
                    jj += 64
                }
                raZ[32 + i] = acc2
            }

            let outBase = step * 32
            for i in 0..<32 { out[outBase + i] = raZ[i] }

            for i in stride(from: 511, through: 32, by: -1) { raX[i] = raX[i - 32] }
            for i in 0..<32 { raZ[i] = raZ[i + 32]; raZ[i + 32] = 0 }
        }
        qmfHistory[channel] = raX
        qmfOverlap[channel] = raZ
    }

    // MARK: LFE interpolation FIR (Annex C.3.7)

    private func lfeInterpolate(decimated: [Double], factor: Int) -> [Double] {
        let coeff = factor == 64 ? DTSTables.lfeFir64 : DTSTables.lfeFir128
        let taps = 512 / factor
        var out = [Double](repeating: 0, count: decimated.count * factor)
        // History: previous frame's tail samples precede index 0.
        let hist = lfeHistory   // hist[hist.count-1] = most recent past sample
        var outIdx = 0
        for d in 0..<decimated.count {
            for k in 0..<factor {
                var acc = 0.0
                for j in 0..<taps {
                    let idx = d - j
                    let sample = idx >= 0 ? decimated[idx] : hist[hist.count + idx]
                    acc += sample * coeff[k + j * factor]
                }
                out[outIdx] = acc
                outIdx += 1
            }
        }
        // Carry the last (taps-1) samples forward.
        let keep = max(taps - 1, 0)
        var newHist = [Double](repeating: 0, count: 8)
        for i in 0..<keep {
            let idx = decimated.count - keep + i
            newHist[8 - keep + i] = idx >= 0 ? decimated[idx] : hist[hist.count + idx]
        }
        lfeHistory = newHist
        return out
    }
}
