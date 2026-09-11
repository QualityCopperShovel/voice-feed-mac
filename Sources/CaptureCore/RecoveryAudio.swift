import Foundation

/// Private, rolling one-minute PCM WAV files. No audio is uploaded by this writer.
public final class RecoveryAudio {
    private let directory: URL
    private let maxFiles: Int
    private let segmentBytes: Int
    private var file: FileHandle?
    private var bytes = 0
    public init(directory: URL, maxFiles: Int = 30, segmentBytes: Int = 48_000 * 60) throws {
        guard maxFiles > 0, segmentBytes > 0, segmentBytes % 2 == 0 else {
            throw NSError(domain: "VoiceFeedRecovery", code: 1)
        }
        self.directory = directory; self.maxFiles = maxFiles; self.segmentBytes = segmentBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try prune()
    }
    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files.prefix(max(0, files.count - maxFiles)) { try FileManager.default.removeItem(at: url) }
        let cutoff = Date().addingTimeInterval(-1800)
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            if let stamp = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    private func begin() throws {
        let name = String(format: "%024.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".wav"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(0), attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "VoiceFeedRecovery", code: 2)
        }
        file = try FileHandle(forUpdating: url); bytes = 0
        try prune()
    }
    public func append(_ pcm: Data) throws {
        guard pcm.count % 2 == 0 else { throw NSError(domain: "VoiceFeedRecovery", code: 3) }
        var offset = 0
        while offset < pcm.count {
            if file == nil { try begin() }
            guard let file else { throw NSError(domain: "VoiceFeedRecovery", code: 2) }
            let length = min(segmentBytes - bytes, pcm.count - offset)
            try file.seekToEnd(); try file.write(contentsOf: pcm[offset..<offset+length])
            bytes += length; offset += length
            try file.seek(toOffset: 0); try file.write(contentsOf: Self.header(bytes))
            if bytes == segmentBytes { try close() }
        }
    }
    public func close() throws {
        if let file { try file.synchronize(); try file.close() }
        file = nil
    }
    deinit { try? close() }
    private static func header(_ bytes: Int) -> Data {
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func short(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        word(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8)); word(16)
        short(1); short(1); word(24000); word(48000); short(2); short(16)
        data.append(Data("data".utf8)); word(UInt32(bytes)); return data
    }
}
