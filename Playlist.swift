import Foundation
import Observation

enum LoopMode: String, CaseIterable {
    case off = "Off"
    case current = "Current File"
    case playlist = "Playlist"
}

// Playback order is separate from the visible list so shuffle keeps filenames
// in a predictable place, and Previous retraces the shuffled order.
@Observable
final class Playlist {
    private(set) var files: [URL] = []
    private var order: [URL] = []
    private var position = 0
    var loopMode: LoopMode = .off
    var shuffle = false {
        didSet {
            guard shuffle != oldValue else { return }
            rebuildOrder(keeping: currentURL)
        }
    }

    var currentURL: URL? { order.indices.contains(position) ? order[position] : nil }
    var currentIndex: Int? { currentURL.flatMap { files.firstIndex(of: $0) } }
    var canGoPrevious: Bool { position > 0 || (loopMode == .playlist && !order.isEmpty) }
    var canGoNext: Bool { position + 1 < order.count || (loopMode == .playlist && !order.isEmpty) }

    func replace(with urls: [URL]) {
        files = unique(urls)
        rebuildOrder(keeping: nil)
    }

    func append(_ urls: [URL]) {
        let additions = unique(urls).filter { !files.contains($0) }
        files += additions
        order += shuffle ? additions.shuffled() : additions
    }

    func select(_ url: URL) {
        if let index = order.firstIndex(of: url) { position = index }
    }

    @discardableResult
    func next(automatic: Bool = false) -> URL? {
        guard !order.isEmpty else { return nil }
        if automatic && loopMode == .current { return currentURL }
        if position + 1 < order.count {
            position += 1
        } else if loopMode == .playlist {
            position = 0
        } else {
            return nil
        }
        return currentURL
    }

    @discardableResult
    func previous() -> URL? {
        guard !order.isEmpty else { return nil }
        if position > 0 {
            position -= 1
        } else if loopMode == .playlist {
            position = order.count - 1
        } else {
            return nil
        }
        return currentURL
    }

    func remove(_ url: URL) {
        guard let index = order.firstIndex(of: url) else { return }
        files.removeAll { $0 == url }
        order.remove(at: index)
        if index < position { position -= 1 }
        position = max(0, min(position, order.count - 1))
    }

    private func rebuildOrder(keeping current: URL?) {
        order = shuffle ? files.shuffled() : files
        // Begin a newly shuffled run with the file already on screen.
        if shuffle, let current, let index = order.firstIndex(of: current) {
            order.swapAt(0, index)
        }
        position = current.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map { $0.standardizedFileURL }.filter { seen.insert($0).inserted }
    }
}

enum PlaylistFiles {
    static let videoExtensions: Set<String> = [
        "mkv", "webm", "mp4", "m4v", "mov", "avi", "mpg", "mpeg",
        "mts", "m2ts", "ts", "3gp", "3g2", "wmv", "flv", "vob", "ogv"
    ]

    // Directory traversal runs away from the UI thread. Hidden files and app
    // packages are excluded; relative paths sort naturally (clip2 before clip10).
    static func expand(_ urls: [URL]) throws -> [URL] {
        var files: [URL] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                var traversalError: Error?
                guard let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in traversalError = error; return false }
                ) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                var videos: [URL] = []
                for case let file as URL in enumerator {
                    if videoExtensions.contains(file.pathExtension.lowercased()),
                       try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        videos.append(file)
                    }
                }
                if let traversalError { throw traversalError }
                files += videos.sorted {
                    $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
            } else if ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) {
                let content = try String(contentsOf: url, encoding: .utf8)
                for line in content.components(separatedBy: .newlines) {
                    let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                    guard !path.isEmpty, !path.hasPrefix("#") else { continue }
                    if let entry = URL(string: path), entry.scheme != nil {
                        guard entry.isFileURL else { continue }
                        files.append(entry)
                    } else if path.hasPrefix("/") {
                        files.append(URL(fileURLWithPath: path))
                    } else {
                        files.append(url.deletingLastPathComponent().appendingPathComponent(path))
                    }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    static func save(_ urls: [URL], to destination: URL) throws {
        let content = "#EXTM3U\n" + urls.map(\.absoluteString).joined(separator: "\n") + "\n"
        try content.write(to: destination, atomically: true, encoding: .utf8)
    }
}
