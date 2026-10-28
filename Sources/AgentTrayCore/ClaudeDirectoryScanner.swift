import Foundation

/// What the UI gets for one session: ready to classify, no JSONL knowledge needed.
public struct SessionSnapshot: Sendable, Equatable, Identifiable {
    /// Unique across tracked directories: `<.claude path>#<sessionId>`.
    public var id: String
    public var sessionId: String
    public var sourceLabel: String
    public var title: String
    /// Last segment of the session's `cwd`.
    public var workingDirectoryName: String?
    public var lastPrompt: String?
    public var lastMessage: String?
    public var lastActivity: Date
    public var facts: SessionFacts
    /// Canonical path of the `.claude` directory the session comes from.
    public var directoryPath: String
    /// `name` from the newest `sessions/<pid>.json` naming this session.
    public var registryName: String?
    /// That file belongs to a terminal session (not Speedwave Desktop, not a background job),
    /// so the session may have a window to bring to the front.
    public var isTerminalSession: Bool

    public init(
        id: String, sessionId: String, sourceLabel: String, title: String,
        workingDirectoryName: String?, lastPrompt: String?, lastMessage: String?,
        lastActivity: Date, facts: SessionFacts, directoryPath: String = "", registryName: String? = nil,
        isTerminalSession: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sourceLabel = sourceLabel
        self.title = title
        self.workingDirectoryName = workingDirectoryName
        self.lastPrompt = lastPrompt
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.facts = facts
        self.directoryPath = directoryPath
        self.registryName = registryName
        self.isTerminalSession = isTerminalSession
    }
}

/// Follows one `.claude` directory: the session registry and the transcripts under `projects/`.
/// Read-only; subagent transcripts are not opened.
public final class ClaudeDirectoryScanner {
    public let directory: TrackedDirectory
    private let windowSize: Int

    private struct FileStamp: Equatable {
        var size: UInt64
        var modificationDate: Date?
        var inode: UInt64?
    }

    private struct Transcript {
        var sessionId: String
        var stamp: FileStamp
        /// Nil while the file is too old to be shown; only its stamp is watched then.
        var reader: TranscriptReader?
    }

    private var transcripts: [String: Transcript] = [:]
    private var registryFiles: [String: (stamp: FileStamp, entry: SessionRegistryEntry?)] = [:]
    private var registry: [String: SessionRegistryEntry] = [:]

    public init(directory: TrackedDirectory, windowSize: Int = 256 * 1024) {
        self.directory = directory
        self.windowSize = windowSize
    }

    private var sessionsURL: URL { directory.url.appendingPathComponent("sessions") }
    private var projectsURL: URL { directory.url.appendingPathComponent("projects") }

    /// Re-reads what changed. `changedPaths` are paths reported by the file watcher;
    /// nil means a full scan. Only files whose size, mtime or inode changed are read.
    @discardableResult
    public func refresh(changedPaths: [String]? = nil, thresholds: Thresholds, now: Date) -> [SessionSnapshot] {
        var scanRegistry = changedPaths == nil
        var projectDirectories: Set<String>? = changedPaths == nil ? nil : []
        for rawPath in changedPaths ?? [] {
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            if path == directory.url.path || path == projectsURL.path {
                // The `.claude` or `projects/` directory itself changed: rescan everything.
                scanRegistry = true
                projectDirectories = nil
            } else if path == sessionsURL.path || path.hasPrefix(sessionsURL.path + "/") {
                scanRegistry = true
            } else if path.hasPrefix(projectsURL.path + "/"),
                      let first = path.dropFirst(projectsURL.path.count + 1).split(separator: "/").first {
                projectDirectories?.insert(String(first))
            }
            // Anything else under `.claude` (logs, todos, caches) does not affect sessions.
        }
        if scanRegistry { refreshRegistry() }
        refreshTranscripts(in: projectDirectories, thresholds: thresholds, now: now)
        return snapshots()
    }

    /// Every decodable `sessions/<pid>.json`, including files left behind by finished processes.
    public var registryEntries: [SessionRegistryEntry] {
        registryFiles.values.compactMap(\.entry)
    }

    public func snapshots() -> [SessionSnapshot] {
        transcripts.values.compactMap { transcript -> SessionSnapshot? in
            guard let reader = transcript.reader else { return nil }
            let facts = reader.facts
            let entry = registry[transcript.sessionId]
            // Bookkeeping appended to an idle session (the away recap, idle compaction) changes
            // the file but must not make an old session fresh again, so the file mtime and the
            // last record count only when nothing in the transcript moved the conversation.
            let transcriptActivity = facts.lastSignificantTimestamp ?? facts.lastRecordTimestamp ?? reader.modificationDate
            let activity = [transcriptActivity, entry?.updatedAt]
                .compactMap { $0 }.max() ?? .distantPast
            let title = facts.transcriptTitle
                ?? facts.firstHumanPrompt.flatMap(Self.shortTitle)
                ?? entry?.name
                ?? String(transcript.sessionId.prefix(8))
            return SessionSnapshot(
                id: directory.url.path + "#" + transcript.sessionId,
                sessionId: transcript.sessionId,
                sourceLabel: directory.sourceLabel,
                title: title,
                workingDirectoryName: facts.cwd.map { ($0 as NSString).lastPathComponent },
                lastPrompt: facts.lastPrompt,
                lastMessage: facts.lastMessage,
                lastActivity: activity,
                facts: facts,
                directoryPath: directory.url.path,
                registryName: entry?.name,
                isTerminalSession: entry?.isTerminalSession ?? false
            )
        }
    }

    /// One line of at most 60 characters.
    static func shortTitle(_ prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count <= 60 ? line : String(line.prefix(59)) + "…"
    }

    private func refreshRegistry() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsURL.path)) ?? []
        var seen: Set<String> = []
        for name in names where name.hasSuffix(".json") {
            let path = sessionsURL.appendingPathComponent(name).path
            seen.insert(path)
            guard let stamp = stamp(path) else { continue }
            if registryFiles[path]?.stamp == stamp { continue }
            let entry = FileManager.default.contents(atPath: path).flatMap { try? SessionRegistryEntry.decode($0) }
            registryFiles[path] = (stamp, entry)
        }
        registryFiles = registryFiles.filter { seen.contains($0.key) }

        registry = [:]
        for (_, file) in registryFiles {
            guard let entry = file.entry else { continue }
            // Several pid files can name the same session; the latest one wins.
            if let existing = registry[entry.sessionId],
               (existing.updatedAt ?? .distantPast) >= (entry.updatedAt ?? .distantPast) {
                continue
            }
            registry[entry.sessionId] = entry
        }
    }

    private func refreshTranscripts(in projectDirectories: Set<String>?, thresholds: Thresholds, now: Date) {
        let fileManager = FileManager.default
        let directories = projectDirectories.map(Array.init)
            ?? ((try? fileManager.contentsOfDirectory(atPath: projectsURL.path)) ?? [])

        for projectName in directories {
            let projectPath = projectsURL.appendingPathComponent(projectName).path
            let prefix = projectPath + "/"
            let names = (try? fileManager.contentsOfDirectory(atPath: projectPath)) ?? []
            var seen: Set<String> = []
            for name in names where name.hasSuffix(".jsonl") {
                let path = prefix + name
                guard let stamp = stamp(path) else { continue }
                seen.insert(path)
                let sessionId = String(name.dropLast(".jsonl".count))
                var transcript = transcripts[path] ?? Transcript(sessionId: sessionId, stamp: stamp, reader: nil)
                let changed = transcript.stamp != stamp
                transcript.stamp = stamp

                if transcript.reader == nil {
                    let lastSeen = [stamp.modificationDate, registry[sessionId]?.updatedAt].compactMap { $0 }.max()
                    if let lastSeen, now.timeIntervalSince(lastSeen) > thresholds.hideAfter {
                        transcripts[path] = transcript
                        continue
                    }
                    transcript.reader = TranscriptReader(url: URL(fileURLWithPath: path), windowSize: windowSize)
                    try? transcript.reader?.update()
                } else if changed {
                    try? transcript.reader?.update()
                }
                transcripts[path] = transcript
            }
            // A session disappears when its transcript disappears.
            for path in transcripts.keys where path.hasPrefix(prefix) && !seen.contains(path) {
                transcripts[path] = nil
            }
        }
        if projectDirectories == nil {
            let present = Set(directories.map { projectsURL.appendingPathComponent($0).path + "/" })
            for path in transcripts.keys {
                let parent = (path as NSString).deletingLastPathComponent + "/"
                if !present.contains(parent) { transcripts[path] = nil }
            }
        }
    }

    private func stamp(_ path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStamp(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
