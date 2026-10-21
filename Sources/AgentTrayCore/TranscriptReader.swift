import Foundation

/// Reads one transcript file incrementally and keeps its reduced `SessionFacts`.
///
/// The first read covers only the last `windowSize` bytes; later reads consume only
/// bytes appended since. The file is opened read-only and never modified.
public final class TranscriptReader {
    public let url: URL
    public let windowSize: Int
    public private(set) var facts = SessionFacts()
    public private(set) var modificationDate: Date?
    /// Lines skipped because they were not valid JSON, since the reader was created.
    public private(set) var invalidLineCount = 0

    private var offset: UInt64 = 0
    private var inode: UInt64?
    /// Bytes of an unterminated last line, waiting for the rest.
    private var partialLine = Data()

    public init(url: URL, windowSize: Int = 256 * 1024) {
        self.url = url
        self.windowSize = windowSize
    }

    /// Reads whatever changed since the last call. Throws when the file cannot be read.
    public func update() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        modificationDate = attributes[.modificationDate] as? Date

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if inode == nil || fileInode != inode || size < offset {
            inode = fileInode
            try readInitialWindow(handle, size: size)
        } else if size > offset {
            let data = try read(handle, from: offset, to: size)
            offset = size
            consume(data)
        }
    }

    private func readInitialWindow(_ handle: FileHandle, size: UInt64) throws {
        facts = SessionFacts()
        partialLine = Data()
        let start = size > UInt64(windowSize) ? size - UInt64(windowSize) : 0
        var data = try read(handle, from: start, to: size)
        offset = size
        var head = Data()
        if start > 0 {
            // The first line of the window is probably cut; keep it for the backfill.
            let cut = data.firstIndex(of: 0x0A).map { data.index(after: $0) } ?? data.endIndex
            head = data[data.startIndex..<cut]
            data = data[cut...]
        }
        consume(data)
        try backfill(handle, before: start, head: head)
    }

    /// Walks back in `windowSize` steps until the prompt and title are known
    /// or the start of the file is reached. Only metadata is taken from these older
    /// chunks; tool and task state from before the window is not reconstructed.
    private func backfill(_ handle: FileHandle, before windowStart: UInt64, head: Data) throws {
        var chunkEnd = windowStart
        var carried = head
        while chunkEnd > 0 && needsBackfill {
            let chunkStart = chunkEnd > UInt64(windowSize) ? chunkEnd - UInt64(windowSize) : 0
            var chunk = try read(handle, from: chunkStart, to: chunkEnd)
            chunk.append(carried)
            if chunkStart > 0 {
                let cut = chunk.firstIndex(of: 0x0A).map { chunk.index(after: $0) } ?? chunk.endIndex
                carried = chunk[chunk.startIndex..<cut]
                chunk = chunk[cut...]
            }
            var older = SessionFacts()
            forEachLine(in: chunk) { older = reduce(state: older, record: $0) }
            if facts.lastPromptRecord == nil { facts.lastPromptRecord = older.lastPromptRecord }
            if facts.lastHumanPrompt == nil { facts.lastHumanPrompt = older.lastHumanPrompt }
            if facts.customTitle == nil { facts.customTitle = older.customTitle }
            if facts.aiTitle == nil { facts.aiTitle = older.aiTitle }
            if facts.cwd == nil { facts.cwd = older.cwd }
            if facts.lastMessage == nil { facts.lastMessage = older.lastMessage }
            if facts.permissionMode == nil { facts.permissionMode = older.permissionMode }
            chunkEnd = chunkStart
        }
    }

    private var needsBackfill: Bool {
        facts.lastPromptRecord == nil || facts.transcriptTitle == nil
    }

    private func consume(_ data: Data) {
        var buffer = partialLine
        buffer.append(data)
        if let lastNewline = buffer.lastIndex(of: 0x0A) {
            let complete = buffer[buffer.startIndex...lastNewline]
            partialLine = Data(buffer[buffer.index(after: lastNewline)...])
            forEachLine(in: complete) { facts = reduce(state: facts, record: $0) }
        } else {
            partialLine = buffer
        }
    }

    private func forEachLine(in data: Data, _ body: (TranscriptRecord) -> Void) {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            do {
                body(try TranscriptRecord.parse(line: Data(line)))
            } catch {
                invalidLineCount += 1
                Log.parser("Skipping invalid JSON line in \(url.lastPathComponent)")
            }
        }
    }

    private func read(_ handle: FileHandle, from start: UInt64, to end: UInt64) throws -> Data {
        guard end > start else { return Data() }
        try handle.seek(toOffset: start)
        return try handle.read(upToCount: Int(end - start)) ?? Data()
    }
}
