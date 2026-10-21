import Foundation

/// A `.claude` directory found by expanding the configured patterns.
public struct TrackedDirectory: Sendable, Equatable, Hashable {
    /// Canonical path of the `.claude` directory (symlinks resolved).
    public var url: URL
    /// "lokalny" for `~/.claude`, otherwise the segment matched by the pattern's first `*`
    /// or, without one, the name of the directory holding `.claude` (or the home directory).
    public var sourceLabel: String
    public var pattern: String

    public init(url: URL, sourceLabel: String, pattern: String) {
        self.url = url
        self.sourceLabel = sourceLabel
        self.pattern = pattern
    }
}

/// Path pattern from the settings, e.g. `~/Speedwave/*/home/.claude`.
///
/// `~` at the start is the home directory, `*` matches within exactly one path segment,
/// `**` matches zero or more segments (at most `maxGlobstarDepth`), everything else is literal.
public struct PathPattern: Sendable, Equatable {
    public static let maxGlobstarDepth = 6
    public static let localLabel = "lokalny"

    public let pattern: String
    public let homeDirectory: URL

    public init(_ pattern: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.pattern = pattern
        self.homeDirectory = homeDirectory
    }

    /// Absolute path segments after `~` expansion.
    var segments: [String] {
        var path = pattern.trimmingCharacters(in: .whitespaces)
        if path == "~" {
            path = homeDirectory.path
        } else if path.hasPrefix("~/") {
            path = homeDirectory.path + path.dropFirst(1)
        } else if !path.hasPrefix("/") {
            path = homeDirectory.path + "/" + path
        }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Deepest directory of the pattern without wildcards. Changes below it may add matches.
    public var literalRoot: URL {
        var root = URL(fileURLWithPath: "/")
        for segment in segments {
            if segment.contains("*") { break }
            root.appendPathComponent(segment)
        }
        return root
    }

    /// Number of segments from `literalRoot` to a match, or nil when `**` makes it unbounded.
    public var depthBelowRoot: Int? {
        let all = segments
        guard let first = all.firstIndex(where: { $0.contains("*") }) else { return 0 }
        if all.contains("**") { return nil }
        return all.count - first
    }

    public func expand(fileManager: FileManager = .default) -> [TrackedDirectory] {
        var results: [TrackedDirectory] = []
        var seen: Set<String> = []
        let localClaude = canonical(homeDirectory.appendingPathComponent(".claude"))
        match(Array(segments)[...], at: URL(fileURLWithPath: "/"), globstarDepth: 0, capture: nil, fileManager: fileManager) { matched, capture in
            var directory = matched
            var isHomeFallback = false
            if !isDirectory(directory.appendingPathComponent("sessions"), fileManager),
               !isDirectory(directory.appendingPathComponent("projects"), fileManager),
               isDirectory(directory.appendingPathComponent(".claude"), fileManager) {
                directory = directory.appendingPathComponent(".claude")
                isHomeFallback = true
            }
            let resolved = canonical(directory)
            guard seen.insert(resolved.path).inserted else { return }
            let label: String
            if resolved.path == localClaude.path {
                label = Self.localLabel
            } else if let capture {
                label = capture
            } else {
                // Without a `*`: the directory holding `.claude`, or the one holding the home directory.
                let holder = isHomeFallback ? matched.deletingLastPathComponent() : directory.deletingLastPathComponent()
                label = holder.lastPathComponent
            }
            results.append(TrackedDirectory(url: resolved, sourceLabel: label, pattern: pattern))
        }
        return results.sorted { $0.url.path < $1.url.path }
    }

    private func match(
        _ remaining: ArraySlice<String>,
        at directory: URL,
        globstarDepth: Int,
        capture: String?,
        fileManager: FileManager,
        found: (URL, String?) -> Void
    ) {
        guard let segment = remaining.first else {
            if isDirectory(directory, fileManager) { found(directory, capture) }
            return
        }
        let rest = remaining.dropFirst()
        if segment == "**" {
            match(rest, at: directory, globstarDepth: 0, capture: capture, fileManager: fileManager, found: found)
            guard globstarDepth < Self.maxGlobstarDepth else { return }
            for child in subdirectories(of: directory, fileManager, followSymlinks: false, includeHidden: false) {
                match(remaining, at: child, globstarDepth: globstarDepth + 1, capture: capture, fileManager: fileManager, found: found)
            }
        } else if segment.contains("*") {
            for child in subdirectories(of: directory, fileManager, followSymlinks: true, includeHidden: segment.hasPrefix("."))
            where Self.wildcardMatches(segment, child.lastPathComponent) {
                match(rest, at: child, globstarDepth: 0, capture: capture ?? child.lastPathComponent, fileManager: fileManager, found: found)
            }
        } else {
            let child = directory.appendingPathComponent(segment)
            guard isDirectory(child, fileManager) else { return }
            match(rest, at: child, globstarDepth: 0, capture: capture, fileManager: fileManager, found: found)
        }
    }

    /// Visible subdirectories. Hidden entries only match a pattern segment that starts with `.`.
    private func subdirectories(of directory: URL, _ fileManager: FileManager, followSymlinks: Bool, includeHidden: Bool) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard includeHidden || !name.hasPrefix(".") else { return nil }
            let child = directory.appendingPathComponent(name)
            if !followSymlinks,
               let type = try? fileManager.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                return nil
            }
            return isDirectory(child, fileManager) ? child : nil
        }
    }

    /// Matches one segment where `*` stands for any run of characters.
    static func wildcardMatches(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return pattern == name }
        var rest = Substring(name)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.hasSuffix(parts.last!)
    }
}

/// Expands every pattern and tracks each matched directory once, keeping the first pattern's label.
public func expandPatterns(_ patterns: [String], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> [TrackedDirectory] {
    var seen: Set<String> = []
    var result: [TrackedDirectory] = []
    for pattern in patterns where !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
        for directory in PathPattern(pattern, homeDirectory: homeDirectory).expand(fileManager: fileManager)
        where seen.insert(directory.url.path).inserted {
            result.append(directory)
        }
    }
    return result
}

private func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}
