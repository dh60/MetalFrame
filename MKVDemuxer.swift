import Foundation
import Compression

// Pure-Swift Matroska (and structurally WebM) demuxer. No third-party code —
// EBML is parsed from scratch against the IETF Matroska specification.
//
// Design: init() reads only the file's metadata (EBML header, SeekHead, Info,
// Tracks, Cues) via random access, so open time is independent of file size.
// Packets then stream lazily cluster-by-cluster through readNextPacket() on
// whatever single thread owns the demuxer (the engine's demux thread). Seeks
// reposition the cluster cursor through the Cues index.

enum MKVError: Error, CustomStringConvertible {
    case notMatroska(String)
    case io(String)
    case corrupt(String)

    var description: String {
        switch self {
        case .notMatroska(let s): return "Not a Matroska file: \(s)"
        case .io(let s): return "MKV read error: \(s)"
        case .corrupt(let s): return "MKV corrupt: \(s)"
        }
    }
}

// MARK: - Positioned file reads

// pread-based reader: thread-safe positioned reads, no shared file offset,
// no mmap (80 GB files stay off the memory map).
final class MKVFileReader {
    private let fd: Int32
    let size: Int64

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw MKVError.io("open(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw MKVError.io("fstat failed")
        }
        size = st.st_size
    }

    deinit { close(fd) }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { buf in
            pread(fd, buf.baseAddress, count, offset)
        }
        guard n >= 0 else { throw MKVError.io("pread failed: \(String(cString: strerror(errno)))") }
        if n < count { data.removeSubrange(n..<count) }
        return data
    }
}

// Buffered sequential cursor over MKVFileReader. Small reads come out of a
// refillable window; large reads (video keyframes) bypass the buffer.
final class MKVReader {
    private let file: MKVFileReader
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private static let bufferSize = 1 << 19  // 512 KiB

    private(set) var position: Int64 = 0
    var size: Int64 { file.size }

    init(file: MKVFileReader) {
        self.file = file
    }

    func seek(to offset: Int64) {
        position = offset
    }

    func skip(_ n: Int64) {
        position += n
    }

    var atEnd: Bool { position >= size }

    func readBytes(_ count: Int) throws -> Data {
        guard count >= 0 else { throw MKVError.corrupt("negative read") }
        guard position + Int64(count) <= size else {
            throw MKVError.io("read past end (pos \(position), count \(count), size \(size))")
        }
        defer { position += Int64(count) }
        if count > Self.bufferSize / 2 {
            return try file.read(at: position, count: count)
        }
        try ensureBuffered(count)
        let lo = Int(position - bufferStart)
        return buffer.subdata(in: lo..<(lo + count))
    }

    func readByte() throws -> UInt8 {
        try ensureBuffered(1)
        let b = buffer[buffer.startIndex + Int(position - bufferStart)]
        position += 1
        return b
    }

    private func ensureBuffered(_ count: Int) throws {
        if position >= bufferStart, position + Int64(count) <= bufferStart + Int64(buffer.count) {
            return
        }
        guard position + Int64(count) <= size else {
            throw MKVError.io("read past end (pos \(position), size \(size))")
        }
        let want = min(Int64(Self.bufferSize), size - position)
        buffer = try file.read(at: position, count: Int(want))
        bufferStart = position
        if buffer.count < count {
            throw MKVError.io("short read at \(position)")
        }
    }

    // EBML element ID: length from leading-one position, value KEEPS the marker
    // bit (IDs are conventionally quoted with it, e.g. Segment = 0x18538067).
    func readElementID() throws -> UInt32 {
        let first = try readByte()
        guard first != 0 else { throw MKVError.corrupt("invalid element ID at \(position - 1)") }
        let extraBytes: Int
        if first & 0x80 != 0 { extraBytes = 0 }
        else if first & 0x40 != 0 { extraBytes = 1 }
        else if first & 0x20 != 0 { extraBytes = 2 }
        else if first & 0x10 != 0 { extraBytes = 3 }
        else { throw MKVError.corrupt("element ID longer than 4 bytes at \(position - 1)") }
        var value = UInt32(first)
        for _ in 0..<extraBytes {
            value = (value << 8) | UInt32(try readByte())
        }
        return value
    }

    // EBML size varint: marker bit stripped; all-ones payload = unknown size.
    func readElementSize() throws -> Int64? {
        let first = try readByte()
        guard first != 0 else { throw MKVError.corrupt("invalid size varint at \(position - 1)") }
        var length = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            length += 1
            mask >>= 1
        }
        var value = UInt64(first & (mask - 1))
        var allOnes = (first & (mask - 1)) == (mask - 1)
        for _ in 1..<length {
            let b = try readByte()
            value = (value << 8) | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        if allOnes { return nil }
        return Int64(value)
    }

    // Varint inside block payloads (track number, EBML lace sizes): marker stripped.
    func readVarint() throws -> (value: UInt64, length: Int) {
        let first = try readByte()
        guard first != 0 else { throw MKVError.corrupt("invalid varint at \(position - 1)") }
        var length = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            length += 1
            mask >>= 1
        }
        var value = UInt64(first & (mask - 1))
        for _ in 1..<length {
            value = (value << 8) | UInt64(try readByte())
        }
        return (value, length)
    }
}

// MARK: - Element IDs

private enum EBML {
    static let header: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067
    static let seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackUID: UInt32 = 0x73C5
    static let trackType: UInt32 = 0x83
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let defaultDuration: UInt32 = 0x23E383
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let name: UInt32 = 0x536E
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let seekPreRoll: UInt32 = 0x56BB
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let range: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let maxCLL: UInt32 = 0x55BC
    static let maxFALL: UInt32 = 0x55BD
    static let masteringMetadata: UInt32 = 0x55D0
    static let primaryRX: UInt32 = 0x55D1
    static let primaryRY: UInt32 = 0x55D2
    static let primaryGX: UInt32 = 0x55D3
    static let primaryGY: UInt32 = 0x55D4
    static let primaryBX: UInt32 = 0x55D5
    static let primaryBY: UInt32 = 0x55D6
    static let whitePointX: UInt32 = 0x55D7
    static let whitePointY: UInt32 = 0x55D8
    static let luminanceMax: UInt32 = 0x55D9
    static let luminanceMin: UInt32 = 0x55DA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let cluster: UInt32 = 0x1F43B675
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB
    static let discardPadding: UInt32 = 0x75A2
    static let cues: UInt32 = 0x1C53BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1
    static let chapters: UInt32 = 0x1043A770
    static let attachments: UInt32 = 0x1941A469
    static let tags: UInt32 = 0x1254C367
    static let void: UInt32 = 0xEC
    static let crc32: UInt32 = 0xBF

    // Elements that can follow a Cluster at segment level — hitting one of
    // these IDs terminates an unknown-size Cluster.
    static let segmentLevelIDs: Set<UInt32> = [
        cluster, cues, chapters, attachments, tags, seekHead, info, tracks,
    ]
}

// MARK: - Track / packet models

enum MKVTrackType {
    case video, audio, subtitle, other

    init(raw: UInt64) {
        switch raw {
        case 1: self = .video
        case 2: self = .audio
        case 17: self = .subtitle
        default: self = .other
        }
    }
}

struct MKVMasteringMetadata {
    var primaryRX: Double?, primaryRY: Double?
    var primaryGX: Double?, primaryGY: Double?
    var primaryBX: Double?, primaryBY: Double?
    var whitePointX: Double?, whitePointY: Double?
    var luminanceMax: Double?, luminanceMin: Double?
}

struct MKVColour {
    var matrixCoefficients: Int?          // ISO 23001-8: 1=709, 9=2020nc
    var primaries: Int?                   // 1=709, 9=2020
    var transferCharacteristics: Int?     // 1/6/14/15=709-family, 13=sRGB, 16=PQ, 18=HLG
    var range: Int?                       // 1=broadcast, 2=full
    var maxCLL: Int?
    var maxFALL: Int?
    var mastering: MKVMasteringMetadata?
}

struct MKVTrack {
    var number: UInt64 = 0
    var uid: UInt64 = 0
    var type: MKVTrackType = .other
    var codecID: String = ""
    var codecPrivate: Data?
    var language: String = "eng"
    var name: String?
    var flagDefault: Bool = true          // spec default is 1
    var flagForced: Bool = false
    var defaultDurationNs: UInt64?        // per-frame duration
    var codecDelayNs: UInt64 = 0
    var seekPreRollNs: UInt64 = 0
    // Video
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var displayWidth: Int?
    var displayHeight: Int?
    var displayUnit: Int = 0              // 0 = pixels, 3 = display aspect ratio
    var colour: MKVColour?
    // Audio
    var sampleRate: Double = 8000
    var outputSampleRate: Double?
    var channels: Int = 1
    var bitDepth: Int?
    // ContentEncodings (only the two shapes seen in the wild for tracks)
    var headerStripBytes: Data?           // ContentCompAlgo 3: prepend to every frame
    var zlibCompressed: Bool = false      // ContentCompAlgo 0: zlib per frame

    var effectiveSampleRate: Double { outputSampleRate ?? sampleRate }

    // Display aspect ratio for the renderer, folding in PAR / DisplayUnit.
    var displayAspect: Double? {
        guard type == .video, pixelWidth > 0, pixelHeight > 0 else { return nil }
        if let dw = displayWidth, let dh = displayHeight, dw > 0, dh > 0 {
            return Double(dw) / Double(dh)  // valid for both pixel and DAR units
        }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

struct MKVPacket {
    let trackNumber: UInt64
    let ptsNs: Int64
    let durationNs: Int64?      // BlockDuration, or DefaultDuration, or codec-derived (laced)
    let keyframe: Bool
    let discardPaddingNs: Int64 // Opus end-trim (last packet), 0 otherwise
    let data: Data
}

// MARK: - Demuxer

final class MKVDemuxer {
    private let file: MKVFileReader
    private let reader: MKVReader         // cluster-streaming cursor

    private(set) var tracks: [MKVTrack] = []
    private(set) var durationSeconds: Double?
    private(set) var timestampScale: UInt64 = 1_000_000  // ns per tick
    private(set) var isWebM = false
    private(set) var hasCues = false

    private var segmentDataStart: Int64 = 0
    private var segmentEnd: Int64                        // file end if unknown
    private var firstClusterOffset: Int64 = 0
    private var cuePoints: [(timeNs: Int64, clusterOffset: Int64)] = []
    private var tracksByNumber: [UInt64: MKVTrack] = [:]

    // Cluster streaming state.
    private var clusterTimestampTicks: Int64 = 0
    private var clusterEnd: Int64?        // nil = unknown-size cluster
    private var insideCluster = false
    private var pendingPackets: [MKVPacket] = []  // laced frames queue up here

    init(url: URL) throws {
        file = try MKVFileReader(url: url)
        reader = MKVReader(file: file)
        segmentEnd = file.size
        try parseHeaderAndSegmentMetadata()
        guard tracks.contains(where: { $0.type == .video || $0.type == .audio }) else {
            throw MKVError.corrupt("no playable tracks found")
        }
        reader.seek(to: firstClusterOffset)
    }

    func track(number: UInt64) -> MKVTrack? { tracksByNumber[number] }

    // MARK: Top-level parse (metadata only — no cluster contents)

    private func parseHeaderAndSegmentMetadata() throws {
        // EBML header
        let headerID = try reader.readElementID()
        guard headerID == EBML.header else {
            throw MKVError.notMatroska("missing EBML header")
        }
        let headerSize = try reader.readElementSize() ?? 0
        let headerEnd = reader.position + headerSize
        while reader.position < headerEnd {
            let (id, size) = try readChildHeader()
            if id == EBML.docType {
                let doc = try readString(size)
                if doc == "webm" { isWebM = true }
                else if doc != "matroska" {
                    throw MKVError.notMatroska("DocType \(doc)")
                }
            } else {
                reader.skip(size)
            }
        }

        // Segment
        let segmentID = try reader.readElementID()
        guard segmentID == EBML.segment else {
            throw MKVError.notMatroska("missing Segment element")
        }
        if let segSize = try reader.readElementSize() {
            segmentEnd = min(reader.position + segSize, file.size)
        }
        segmentDataStart = reader.position

        // Walk segment children until the first Cluster; note SeekHead offsets
        // for anything (Cues, Info, Tracks) that lives after the clusters.
        var seekHeadOffsets: [UInt32: Int64] = [:]  // element ID → absolute offset
        var sawInfo = false, sawTracks = false, sawCues = false

        while reader.position < segmentEnd {
            let elementStart = reader.position
            let (id, size) = try readChildHeaderAllowUnknown()
            switch id {
            case EBML.seekHead:
                guard let size else { throw MKVError.corrupt("unknown-size SeekHead") }
                try parseSeekHead(end: reader.position + size, into: &seekHeadOffsets)
            case EBML.info:
                guard let size else { throw MKVError.corrupt("unknown-size Info") }
                try parseInfo(end: reader.position + size)
                sawInfo = true
            case EBML.tracks:
                guard let size else { throw MKVError.corrupt("unknown-size Tracks") }
                try parseTracks(end: reader.position + size)
                sawTracks = true
            case EBML.cues:
                guard let size else { throw MKVError.corrupt("unknown-size Cues") }
                try parseCues(end: reader.position + size)
                sawCues = true
            case EBML.cluster:
                firstClusterOffset = elementStart
                // Metadata that lives after the clusters is reachable through
                // SeekHead — never by scanning.
                if !sawInfo, let off = seekHeadOffsets[EBML.info] {
                    try parseElementAt(offset: off, expect: EBML.info) { try self.parseInfo(end: $0) }
                }
                if !sawTracks, let off = seekHeadOffsets[EBML.tracks] {
                    try parseElementAt(offset: off, expect: EBML.tracks) { try self.parseTracks(end: $0) }
                }
                if !sawCues, let off = seekHeadOffsets[EBML.cues] {
                    try parseElementAt(offset: off, expect: EBML.cues) { try self.parseCues(end: $0) }
                }
                hasCues = !cuePoints.isEmpty
                return
            default:
                guard let size else { throw MKVError.corrupt("unknown-size element 0x\(String(id, radix: 16))") }
                reader.skip(size)
            }
        }
        throw MKVError.corrupt("no Cluster found")
    }

    private func parseElementAt(offset: Int64, expect: UInt32, body: (Int64) throws -> Void) throws {
        let saved = reader.position
        defer { reader.seek(to: saved) }
        reader.seek(to: segmentDataStart + offset)
        let id = try reader.readElementID()
        guard id == expect, let size = try reader.readElementSize() else { return }
        try body(reader.position + size)
    }

    private func parseSeekHead(end: Int64, into offsets: inout [UInt32: Int64]) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            guard id == EBML.seek else { reader.skip(size); continue }
            let seekEnd = reader.position + size
            var targetID: UInt32 = 0
            var targetPos: Int64 = -1
            while reader.position < seekEnd {
                let (cid, csize) = try readChildHeader()
                switch cid {
                case EBML.seekID:
                    let data = try reader.readBytes(Int(csize))
                    targetID = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                case EBML.seekPosition:
                    targetPos = Int64(try readUInt(csize))
                default:
                    reader.skip(csize)
                }
            }
            if targetPos >= 0 { offsets[targetID] = targetPos }
        }
    }

    private func parseInfo(end: Int64) throws {
        var durationTicks: Double?
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.timestampScale:
                timestampScale = try readUInt(size)
            case EBML.duration:
                durationTicks = try readFloat(size)
            default:
                reader.skip(size)
            }
        }
        if let durationTicks {
            durationSeconds = durationTicks * Double(timestampScale) / 1e9
        }
    }

    private func parseTracks(end: Int64) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            guard id == EBML.trackEntry else { reader.skip(size); continue }
            let track = try parseTrackEntry(end: reader.position + size)
            tracks.append(track)
            tracksByNumber[track.number] = track
        }
    }

    private func parseTrackEntry(end: Int64) throws -> MKVTrack {
        var t = MKVTrack()
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.trackNumber: t.number = try readUInt(size)
            case EBML.trackUID: t.uid = try readUInt(size)
            case EBML.trackType: t.type = MKVTrackType(raw: try readUInt(size))
            case EBML.flagDefault: t.flagDefault = try readUInt(size) != 0
            case EBML.flagForced: t.flagForced = try readUInt(size) != 0
            case EBML.defaultDuration: t.defaultDurationNs = try readUInt(size)
            case EBML.language: t.language = try readString(size)
            case EBML.languageBCP47: t.language = try readString(size)
            case EBML.name: t.name = try readString(size)
            case EBML.codecID: t.codecID = try readString(size)
            case EBML.codecPrivate: t.codecPrivate = try reader.readBytes(Int(size))
            case EBML.codecDelay: t.codecDelayNs = try readUInt(size)
            case EBML.seekPreRoll: t.seekPreRollNs = try readUInt(size)
            case EBML.video: try parseVideo(end: reader.position + size, into: &t)
            case EBML.audio: try parseAudio(end: reader.position + size, into: &t)
            case EBML.contentEncodings: try parseContentEncodings(end: reader.position + size, into: &t)
            default: reader.skip(size)
            }
        }
        return t
    }

    private func parseVideo(end: Int64, into t: inout MKVTrack) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.pixelWidth: t.pixelWidth = Int(try readUInt(size))
            case EBML.pixelHeight: t.pixelHeight = Int(try readUInt(size))
            case EBML.displayWidth: t.displayWidth = Int(try readUInt(size))
            case EBML.displayHeight: t.displayHeight = Int(try readUInt(size))
            case EBML.displayUnit: t.displayUnit = Int(try readUInt(size))
            case EBML.colour: t.colour = try parseColour(end: reader.position + size)
            default: reader.skip(size)
            }
        }
    }

    private func parseColour(end: Int64) throws -> MKVColour {
        var c = MKVColour()
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.matrixCoefficients: c.matrixCoefficients = Int(try readUInt(size))
            case EBML.primaries: c.primaries = Int(try readUInt(size))
            case EBML.transferCharacteristics: c.transferCharacteristics = Int(try readUInt(size))
            case EBML.range: c.range = Int(try readUInt(size))
            case EBML.maxCLL: c.maxCLL = Int(try readUInt(size))
            case EBML.maxFALL: c.maxFALL = Int(try readUInt(size))
            case EBML.masteringMetadata: c.mastering = try parseMastering(end: reader.position + size)
            default: reader.skip(size)
            }
        }
        return c
    }

    private func parseMastering(end: Int64) throws -> MKVMasteringMetadata {
        var m = MKVMasteringMetadata()
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.primaryRX: m.primaryRX = try readFloat(size)
            case EBML.primaryRY: m.primaryRY = try readFloat(size)
            case EBML.primaryGX: m.primaryGX = try readFloat(size)
            case EBML.primaryGY: m.primaryGY = try readFloat(size)
            case EBML.primaryBX: m.primaryBX = try readFloat(size)
            case EBML.primaryBY: m.primaryBY = try readFloat(size)
            case EBML.whitePointX: m.whitePointX = try readFloat(size)
            case EBML.whitePointY: m.whitePointY = try readFloat(size)
            case EBML.luminanceMax: m.luminanceMax = try readFloat(size)
            case EBML.luminanceMin: m.luminanceMin = try readFloat(size)
            default: reader.skip(size)
            }
        }
        return m
    }

    private func parseAudio(end: Int64, into t: inout MKVTrack) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.samplingFrequency: t.sampleRate = try readFloat(size)
            case EBML.outputSamplingFrequency: t.outputSampleRate = try readFloat(size)
            case EBML.channels: t.channels = Int(try readUInt(size))
            case EBML.bitDepth: t.bitDepth = Int(try readUInt(size))
            default: reader.skip(size)
            }
        }
    }

    private func parseContentEncodings(end: Int64, into t: inout MKVTrack) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            guard id == EBML.contentEncoding else { reader.skip(size); continue }
            let encEnd = reader.position + size
            var encodingType: UInt64 = 0  // 0 = compression, 1 = encryption
            var compAlgo: UInt64 = 0
            var compSettings: Data?
            while reader.position < encEnd {
                let (cid, csize) = try readChildHeader()
                switch cid {
                case EBML.contentEncodingType: encodingType = try readUInt(csize)
                case EBML.contentCompression:
                    let compEnd = reader.position + csize
                    while reader.position < compEnd {
                        let (kid, ksize) = try readChildHeader()
                        switch kid {
                        case EBML.contentCompAlgo: compAlgo = try readUInt(ksize)
                        case EBML.contentCompSettings: compSettings = try reader.readBytes(Int(ksize))
                        default: reader.skip(ksize)
                        }
                    }
                default: reader.skip(csize)
                }
            }
            guard encodingType == 0 else {
                throw MKVError.corrupt("encrypted track \(t.number) unsupported")
            }
            switch compAlgo {
            case 0: t.zlibCompressed = true
            case 3: t.headerStripBytes = compSettings ?? Data()
            default:
                throw MKVError.corrupt("track \(t.number) uses unsupported compression algo \(compAlgo)")
            }
        }
    }

    private func parseCues(end: Int64) throws {
        while reader.position < end {
            let (id, size) = try readChildHeader()
            guard id == EBML.cuePoint else { reader.skip(size); continue }
            let pointEnd = reader.position + size
            var timeTicks: Int64 = -1
            var clusterPos: Int64 = -1
            while reader.position < pointEnd {
                let (cid, csize) = try readChildHeader()
                switch cid {
                case EBML.cueTime:
                    timeTicks = Int64(try readUInt(csize))
                case EBML.cueTrackPositions:
                    let posEnd = reader.position + csize
                    while reader.position < posEnd {
                        let (kid, ksize) = try readChildHeader()
                        switch kid {
                        case EBML.cueClusterPosition:
                            // Keep the FIRST track's position per point — video
                            // cues carry the keyframe clusters.
                            if clusterPos < 0 { clusterPos = Int64(try readUInt(ksize)) }
                            else { reader.skip(ksize) }
                        default: reader.skip(ksize)
                        }
                    }
                default:
                    reader.skip(csize)
                }
            }
            if timeTicks >= 0, clusterPos >= 0 {
                cuePoints.append((timeNs: timeTicks * Int64(timestampScale),
                                  clusterOffset: segmentDataStart + clusterPos))
            }
        }
        cuePoints.sort { $0.timeNs < $1.timeNs }
    }

    // MARK: Packet streaming

    // Returns nil at end of stream. Single-threaded use only.
    func readNextPacket() throws -> MKVPacket? {
        if !pendingPackets.isEmpty {
            return pendingPackets.removeFirst()
        }
        while true {
            if insideCluster {
                if let end = clusterEnd, reader.position >= end {
                    insideCluster = false
                    continue
                }
                if reader.atEnd || reader.position >= segmentEnd {
                    return nil
                }
                // Unknown-size cluster: peek the next ID; a segment-level ID
                // means this cluster ended.
                let elementStart = reader.position
                let id = try reader.readElementID()
                if clusterEnd == nil, EBML.segmentLevelIDs.contains(id) {
                    insideCluster = false
                    reader.seek(to: elementStart)
                    continue
                }
                guard let size = try reader.readElementSize() else {
                    throw MKVError.corrupt("unknown-size element inside cluster")
                }
                switch id {
                case EBML.clusterTimestamp:
                    clusterTimestampTicks = Int64(try readUInt(size))
                case EBML.simpleBlock:
                    if let packet = try parseBlock(size: size, simple: true,
                                                   blockDurationTicks: nil,
                                                   hasReference: false,
                                                   discardPaddingNs: 0) {
                        return packet
                    }
                case EBML.blockGroup:
                    if let packet = try parseBlockGroup(end: reader.position + size) {
                        return packet
                    }
                default:
                    reader.skip(size)
                }
            } else {
                if reader.atEnd || reader.position >= segmentEnd {
                    return nil
                }
                let id = try reader.readElementID()
                let size = try reader.readElementSize()
                switch id {
                case EBML.cluster:
                    insideCluster = true
                    clusterEnd = size.map { reader.position + $0 }
                    clusterTimestampTicks = 0
                default:
                    guard let size else {
                        throw MKVError.corrupt("unknown-size non-cluster element at segment level")
                    }
                    reader.skip(size)
                }
            }
        }
    }

    private func parseBlockGroup(end: Int64) throws -> MKVPacket? {
        // Block must be materialized before we know duration/reference, so
        // remember its bounds and parse it after walking the group.
        var blockRange: (start: Int64, size: Int64)?
        var durationTicks: Int64?
        var hasReference = false
        var discardPaddingNs: Int64 = 0

        while reader.position < end {
            let (id, size) = try readChildHeader()
            switch id {
            case EBML.block:
                blockRange = (reader.position, size)
                reader.skip(size)
            case EBML.blockDuration:
                durationTicks = Int64(try readUInt(size))
            case EBML.referenceBlock:
                hasReference = true
                reader.skip(size)
            case EBML.discardPadding:
                discardPaddingNs = try readSInt(size)
            default:
                reader.skip(size)  // BlockAdditions (DV RPUs) parsed in a later phase
            }
        }
        guard let blockRange else { return nil }
        let groupEnd = reader.position
        reader.seek(to: blockRange.start)
        let packet = try parseBlock(size: blockRange.size, simple: false,
                                    blockDurationTicks: durationTicks,
                                    hasReference: hasReference,
                                    discardPaddingNs: discardPaddingNs)
        reader.seek(to: groupEnd)
        return packet
    }

    private func parseBlock(size: Int64, simple: Bool,
                            blockDurationTicks: Int64?,
                            hasReference: Bool,
                            discardPaddingNs: Int64) throws -> MKVPacket? {
        let blockEnd = reader.position + size
        let (trackNumber, trackVarintLen) = try reader.readVarint()
        let tsHi = try reader.readByte()
        let tsLo = try reader.readByte()
        let relTicks = Int64(Int16(bitPattern: (UInt16(tsHi) << 8) | UInt16(tsLo)))
        let flags = try reader.readByte()
        var headerLen = trackVarintLen + 3

        guard let track = tracksByNumber[trackNumber] else {
            reader.seek(to: blockEnd)
            return nil
        }

        let keyframe = simple ? (flags & 0x80) != 0 : !hasReference
        let lacing = (flags >> 1) & 0x03
        let ptsTicks = clusterTimestampTicks + relTicks
        let ptsNs = ptsTicks * Int64(timestampScale)

        var frameSizes: [Int] = []
        if lacing == 0 {
            frameSizes = [Int(size) - headerLen]
        } else {
            let frameCount = Int(try reader.readByte()) + 1
            headerLen += 1
            switch lacing {
            case 1:  // Xiph
                var declared = 0
                for _ in 0..<(frameCount - 1) {
                    var s = 0
                    while true {
                        let b = try reader.readByte()
                        headerLen += 1
                        s += Int(b)
                        if b != 255 { break }
                    }
                    frameSizes.append(s)
                    declared += s
                }
                frameSizes.append(Int(size) - headerLen - declared)
            case 2:  // fixed
                let total = Int(size) - headerLen
                guard frameCount > 0, total % frameCount == 0 else {
                    throw MKVError.corrupt("fixed lacing not divisible at \(reader.position)")
                }
                frameSizes = Array(repeating: total / frameCount, count: frameCount)
            case 3:  // EBML
                var declared = 0
                var prev = 0
                for i in 0..<(frameCount - 1) {
                    let (value, len) = try reader.readVarint()
                    headerLen += len
                    if i == 0 {
                        prev = Int(value)
                    } else {
                        // Signed varint: subtract the mid-range bias.
                        let bias = (Int64(1) << (7 * len - 1)) - 1
                        prev += Int(Int64(value) - bias)
                    }
                    guard prev >= 0 else { throw MKVError.corrupt("negative EBML lace size") }
                    frameSizes.append(prev)
                    declared += prev
                }
                frameSizes.append(Int(size) - headerLen - declared)
            default:
                fatalError("unreachable")
            }
        }
        guard frameSizes.allSatisfy({ $0 >= 0 }) else {
            throw MKVError.corrupt("negative lace size at \(reader.position)")
        }

        // Per-frame duration: BlockDuration split over the lace, DefaultDuration,
        // or codec-derived (needed for laced audio without DefaultDuration).
        let defaultFrameDurNs: Int64? = track.defaultDurationNs.map(Int64.init)
        let blockDurNs: Int64? = blockDurationTicks.map { $0 * Int64(timestampScale) }

        var packets: [MKVPacket] = []
        var frameOffsetNs: Int64 = 0
        for (i, frameSize) in frameSizes.enumerated() {
            var data = try reader.readBytes(frameSize)
            if let strip = track.headerStripBytes, !strip.isEmpty {
                data = strip + data
            }
            if track.zlibCompressed {
                data = try Self.zlibInflate(data)
            }
            var frameDurNs: Int64?
            if let d = defaultFrameDurNs {
                frameDurNs = d
            } else if let bd = blockDurNs {
                frameDurNs = bd / Int64(frameSizes.count)
            } else if frameSizes.count > 1 || track.type == .audio {
                frameDurNs = Self.codecFrameDurationNs(codecID: track.codecID,
                                                       data: data,
                                                       sampleRate: track.effectiveSampleRate)
            }
            packets.append(MKVPacket(trackNumber: trackNumber,
                                     ptsNs: ptsNs + frameOffsetNs,
                                     durationNs: frameDurNs,
                                     keyframe: keyframe,
                                     discardPaddingNs: i == frameSizes.count - 1 ? discardPaddingNs : 0,
                                     data: data))
            frameOffsetNs += frameDurNs ?? 0
        }
        reader.seek(to: blockEnd)

        guard let first = packets.first else { return nil }
        pendingPackets.append(contentsOf: packets.dropFirst())
        return first
    }

    // MARK: Seeking

    // Repositions the cluster cursor at the keyframe cluster ≤ target (via Cues)
    // or the first cluster when the file has none (linear fallback — correct,
    // just slow for big files). Returns the cue time landed on, for diagnostics.
    @discardableResult
    func seek(toNs target: Int64) -> Int64 {
        pendingPackets.removeAll()
        insideCluster = false
        clusterEnd = nil
        clusterTimestampTicks = 0

        guard !cuePoints.isEmpty else {
            reader.seek(to: firstClusterOffset)
            return 0
        }
        // Last cue point with time ≤ target (binary search).
        var lo = 0, hi = cuePoints.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cuePoints[mid].timeNs <= target {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        reader.seek(to: cuePoints[best].clusterOffset)
        return cuePoints[best].timeNs
    }

    // MARK: Element helpers

    private func readChildHeader() throws -> (UInt32, Int64) {
        let id = try reader.readElementID()
        guard let size = try reader.readElementSize() else {
            throw MKVError.corrupt("unexpected unknown-size element 0x\(String(id, radix: 16))")
        }
        return (id, size)
    }

    private func readChildHeaderAllowUnknown() throws -> (UInt32, Int64?) {
        let id = try reader.readElementID()
        let size = try reader.readElementSize()
        return (id, size)
    }

    private func readUInt(_ size: Int64) throws -> UInt64 {
        guard size <= 8 else { throw MKVError.corrupt("uint size \(size)") }
        let data = try reader.readBytes(Int(size))
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func readSInt(_ size: Int64) throws -> Int64 {
        guard size >= 1, size <= 8 else { return 0 }
        let data = try reader.readBytes(Int(size))
        var value = Int64(Int8(bitPattern: data[data.startIndex]))  // sign-extend
        for b in data.dropFirst() {
            value = (value << 8) | Int64(b)
        }
        return value
    }

    private func readFloat(_ size: Int64) throws -> Double {
        let data = try reader.readBytes(Int(size))
        switch data.count {
        case 4:
            let bits = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float(bitPattern: bits))
        case 8:
            let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return Double(bitPattern: bits)
        default:
            throw MKVError.corrupt("float size \(data.count)")
        }
    }

    private func readString(_ size: Int64) throws -> String {
        let data = try reader.readBytes(Int(size))
        // Strings may be zero-padded per EBML.
        let trimmed = data.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8) ?? ""
    }

    // MARK: Codec frame durations (for laced audio without DefaultDuration)

    static func codecFrameDurationNs(codecID: String, data: Data, sampleRate: Double) -> Int64? {
        guard sampleRate > 0 else { return nil }
        func ns(samples: Double, rate: Double) -> Int64 { Int64(samples / rate * 1e9) }
        switch codecID {
        case "A_AC3":
            return ns(samples: 1536, rate: sampleRate)
        case "A_EAC3":
            // numblkscod at a fixed bit position: byte 4 bits 5..4 (after
            // syncword, strmtyp/substreamid, frmsiz).
            guard data.count >= 5 else { return ns(samples: 1536, rate: sampleRate) }
            let b4 = data[data.startIndex + 4]
            let fscod = (b4 >> 6) & 0x3
            let numblkscod = fscod == 0x3 ? 3 : Int((b4 >> 4) & 0x3)
            let blocks = [1, 2, 3, 6][numblkscod]
            return ns(samples: Double(blocks * 256), rate: sampleRate)
        case let s where s == "A_AAC" || s.hasPrefix("A_AAC/"):
            return ns(samples: 1024, rate: sampleRate)
        case "A_FLAC":
            return nil  // variable; caller falls back to next-pts deltas
        case "A_OPUS":
            guard let samples = opusPacketSamples(data) else { return nil }
            // Opus always decodes at 48 kHz regardless of input rate.
            return ns(samples: Double(samples), rate: 48000)
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            return nil
        default:
            return nil
        }
    }

    // RFC 6716 §3.1 TOC parsing → samples at 48 kHz.
    static func opusPacketSamples(_ data: Data) -> Int? {
        guard let toc = data.first else { return nil }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0...11:       // SILK: 10/20/40/60 ms per group of 4
            frameSamples = [480, 960, 1920, 2880][config % 4]
        case 12...15:      // Hybrid: 10/20 ms
            frameSamples = [480, 960][config % 2]
        default:           // CELT: 2.5/5/10/20 ms
            frameSamples = [120, 240, 480, 960][config % 4]
        }
        let code = toc & 0x03
        let frameCount: Int
        switch code {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        default:
            guard data.count >= 2 else { return nil }
            frameCount = Int(data[data.startIndex + 1] & 0x3F)
        }
        return frameSamples * frameCount
    }

    // MKV zlib compression (ContentCompAlgo 0): full zlib stream — strip the
    // 2-byte header + 4-byte adler and inflate the raw deflate payload with the
    // OS Compression framework (self-containment holds: it ships with macOS).
    static func zlibInflate(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw MKVError.corrupt("zlib frame too short") }
        let deflate = data.subdata(in: (data.startIndex + 2)..<(data.endIndex - 4))
        var capacity = max(data.count * 8, 1 << 16)
        for _ in 0..<8 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                deflate.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    compression_decode_buffer(
                        dst.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        src.baseAddress!.assumingMemoryBound(to: UInt8.self), deflate.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < capacity {
                out.removeSubrange(written..<capacity)
                return out
            }
            capacity *= 4  // exactly-full output may be truncated — retry bigger
        }
        throw MKVError.corrupt("zlib inflate failed")
    }
}
