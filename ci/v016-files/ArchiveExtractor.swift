import CLibVLC
import Foundation

/// Archive extraction backed by the libarchive implementation already bundled
/// with SwiftVLC's pinned libVLC binary.
public enum ArchiveExtractor {
    public struct ExtractionError: LocalizedError, Sendable {
        public let message: String

        public var errorDescription: String? { message }

        public init(message: String) {
            self.message = message
        }
    }

    private struct SevenZipVolumeDescriptor {
        let archivePrefix: String
        let partNumber: Int
        let numberWidth: Int
    }

    private struct PreparedArchive {
        let archiveURL: URL
        let cleanupURL: URL?
    }

    /// Returns true for 7-Zip split volumes such as file.7z.001, .002, ...
    /// V0.1.6 accepts any volume as the selected file and resolves the complete
    /// sibling set automatically before extraction.
    public static func isSevenZipVolume(_ url: URL) -> Bool {
        sevenZipVolumeDescriptor(for: url) != nil
    }

    /// Human-friendly base name used by the file manager for extraction output.
    /// `movie.7z.001` becomes `movie` rather than `movie.7z`.
    public static func sevenZipVolumeBaseName(_ url: URL) -> String? {
        guard let descriptor = sevenZipVolumeDescriptor(for: url) else { return nil }
        let prefix = descriptor.archivePrefix
        if prefix.lowercased().hasSuffix(".7z") {
            return String(prefix.dropLast(3))
        }
        return prefix
    }

    public static func extract(
        archiveURL: URL,
        destinationURL: URL,
        password: String? = nil
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let prepared: PreparedArchive
        do {
            prepared = try prepareArchiveForExtraction(archiveURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }

        var errorBuffer = [CChar](repeating: 0, count: 2_048)
        let errorBufferSize = errorBuffer.count
        let result: Int32 = prepared.archiveURL.path.withCString { archivePath in
            destinationURL.path.withCString { destinationPath in
                guard let password, !password.isEmpty else {
                    return swiftvlc_archive_extract(
                        archivePath,
                        destinationPath,
                        nil,
                        &errorBuffer,
                        errorBufferSize
                    )
                }

                return password.withCString { passwordCString in
                    swiftvlc_archive_extract(
                        archivePath,
                        destinationPath,
                        passwordCString,
                        &errorBuffer,
                        errorBufferSize
                    )
                }
            }
        }

        guard result == 0 else {
            // Never leave a partially extracted folder looking like a success.
            try? fileManager.removeItem(at: destinationURL)
            let message = errorBuffer.withUnsafeBufferPointer { buffer -> String in
                guard let baseAddress = buffer.baseAddress else { return "Archive extraction failed" }
                let text = String(cString: baseAddress)
                return text.isEmpty ? "Archive extraction failed" : text
            }
            throw ExtractionError(message: message)
        }
    }

    // MARK: - V0.1.6 7-Zip split-volume support

    private static let sevenZipVolumeRegex = try! NSRegularExpression(
        pattern: #"^(.*\.7z)\.(\d{3,})$"#,
        options: [.caseInsensitive]
    )

    private static func sevenZipVolumeDescriptor(for url: URL) -> SevenZipVolumeDescriptor? {
        let name = url.lastPathComponent
        let nsName = name as NSString
        let fullRange = NSRange(location: 0, length: nsName.length)
        guard let match = sevenZipVolumeRegex.firstMatch(in: name, range: fullRange),
              match.numberOfRanges == 3,
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound
        else { return nil }

        let prefix = nsName.substring(with: match.range(at: 1))
        let numberText = nsName.substring(with: match.range(at: 2))
        guard let number = Int(numberText), number > 0 else { return nil }
        return SevenZipVolumeDescriptor(
            archivePrefix: prefix,
            partNumber: number,
            numberWidth: numberText.count
        )
    }

    private static func prepareArchiveForExtraction(_ archiveURL: URL) throws -> PreparedArchive {
        guard let selectedDescriptor = sevenZipVolumeDescriptor(for: archiveURL) else {
            return PreparedArchive(archiveURL: archiveURL, cleanupURL: nil)
        }

        let fileManager = FileManager.default
        let directory = archiveURL.deletingLastPathComponent()
        let siblings: [URL]
        do {
            siblings = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ExtractionError(message: "无法读取 7z 分卷所在目录：\(error.localizedDescription)")
        }

        var numberedParts: [(number: Int, width: Int, url: URL, size: Int64)] = []
        for sibling in siblings {
            guard let descriptor = sevenZipVolumeDescriptor(for: sibling),
                  descriptor.archivePrefix.caseInsensitiveCompare(selectedDescriptor.archivePrefix) == .orderedSame
            else { continue }

            let values = try? sibling.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { continue }
            numberedParts.append((
                number: descriptor.partNumber,
                width: descriptor.numberWidth,
                url: sibling,
                size: Int64(values?.fileSize ?? 0)
            ))
        }

        numberedParts.sort { lhs, rhs in
            if lhs.number == rhs.number { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
            return lhs.number < rhs.number
        }

        guard let first = numberedParts.first, first.number == 1 else {
            throw ExtractionError(message: "7z 分卷不完整：缺少第一分卷 \(selectedDescriptor.archivePrefix).001")
        }

        var seen = Set<Int>()
        for part in numberedParts {
            guard seen.insert(part.number).inserted else {
                throw ExtractionError(message: "7z 分卷编号重复：\(part.url.lastPathComponent)")
            }
        }

        for expected in 1...numberedParts.count {
            guard numberedParts[expected - 1].number == expected else {
                let width = max(selectedDescriptor.numberWidth, 3)
                let suffix = String(format: "%0*d", width, expected)
                throw ExtractionError(message: "7z 分卷不完整：缺少 \(selectedDescriptor.archivePrefix).\(suffix)")
            }
        }

        // Ensure the file the user tapped belongs to the resolved set. This also
        // catches case-only/renamed oddities without changing any file in place.
        guard numberedParts.contains(where: {
            $0.url.standardizedFileURL.path == archiveURL.standardizedFileURL.path
        }) else {
            throw ExtractionError(message: "无法识别所选 7z 分卷")
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("BTMobile-7z-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            throw ExtractionError(message: "无法创建 7z 分卷临时目录：\(error.localizedDescription)")
        }

        let mergedName = selectedDescriptor.archivePrefix
        let mergedURL = tempDirectory.appendingPathComponent(mergedName, isDirectory: false)

        do {
            guard fileManager.createFile(atPath: mergedURL.path, contents: nil) else {
                throw ExtractionError(message: "无法创建 7z 分卷临时文件")
            }
            let output = try FileHandle(forWritingTo: mergedURL)
            defer { try? output.close() }

            for part in numberedParts {
                let input = try FileHandle(forReadingFrom: part.url)
                do {
                    while true {
                        // Keep each 1 MiB read inside its own autorelease pool.
                        // Large multi-GB split archives otherwise allow Foundation
                        // NSData/FileHandle temporaries to accumulate on iOS and can
                        // be killed by jetsam before libarchive even starts.
                        let data: Data = try autoreleasepool {
                            try input.read(upToCount: 1_048_576) ?? Data()
                        }
                        if data.isEmpty { break }
                        try output.write(contentsOf: data)
                    }
                    try input.close()
                } catch {
                    try? input.close()
                    throw error
                }
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            if let extractionError = error as? ExtractionError { throw extractionError }
            throw ExtractionError(message: "合并 7z 分卷失败：\(error.localizedDescription)")
        }

        return PreparedArchive(archiveURL: mergedURL, cleanupURL: tempDirectory)
    }

    public static func isPasswordError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "password",
            "passphrase",
            "encrypted",
            "encryption",
            "decrypt",
            "authentication",
            "crypto",
            "incorrect passphrase",
            "passphrase required",
            "密码",
            "加密"
        ].contains { message.contains($0) }
    }
}
