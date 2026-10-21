import Foundation
import Testing
@testable import AgentTrayCore

struct PathPatternTests {
    /// Creates a `.claude` directory that looks real (has `projects/`).
    private func makeClaude(_ temp: TemporaryDirectory, _ relative: String) throws {
        try temp.makeDirectory(relative + "/projects")
    }

    @Test func tildeExpandsToHome() throws {
        let temp = try TemporaryDirectory()
        try makeClaude(temp, "home/.claude")
        let home = temp.url.appendingPathComponent("home")
        let found = PathPattern("~/.claude", homeDirectory: home).expand()
        #expect(found.map(\.url.path) == [home.appendingPathComponent(".claude").path])
        #expect(found.first?.sourceLabel == "lokalny")
    }

    @Test func starMatchesExactlyOneSegment() throws {
        let temp = try TemporaryDirectory()
        try makeClaude(temp, "Speedwave/alpha/home/.claude")
        try makeClaude(temp, "Speedwave/beta/home/.claude")
        try makeClaude(temp, "Speedwave/deep/nested/home/.claude")
        try temp.makeDirectory("Speedwave/empty/home")
        try temp.write("Speedwave/file/home", "not a directory")

        let found = PathPattern(temp.url.path + "/Speedwave/*/home/.claude").expand()
        #expect(found.map(\.url.lastPathComponent) == [".claude", ".claude"])
        #expect(found.map(\.sourceLabel) == ["alpha", "beta"])
    }

    @Test func starInsideSegment() {
        #expect(PathPattern.wildcardMatches("proj-*", "proj-a"))
        #expect(PathPattern.wildcardMatches("*-dev", "api-dev"))
        #expect(PathPattern.wildcardMatches("a*b*c", "a-x-b-y-c"))
        #expect(!PathPattern.wildcardMatches("proj-*", "other"))
        #expect(!PathPattern.wildcardMatches("a*b", "a-b-c"))
        #expect(PathPattern.wildcardMatches("*", "anything"))
    }

    @Test func globstarMatchesZeroOrMoreSegmentsUpToDepthLimit() throws {
        let temp = try TemporaryDirectory()
        try makeClaude(temp, "dev/.claude")                       // zero segments
        try makeClaude(temp, "dev/a/.claude")                     // one
        try makeClaude(temp, "dev/a/b/c/d/e/f/.claude")           // six: at the limit
        try makeClaude(temp, "dev/a/b/c/d/e/f/g/.claude")         // seven: too deep
        let found = PathPattern(temp.url.path + "/dev/**/.claude").expand()
        let relative = found.map { String($0.url.path.dropFirst(temp.url.path.count)) }
        #expect(relative == ["/dev/.claude", "/dev/a/.claude", "/dev/a/b/c/d/e/f/.claude"])
        // Without a `*`, the label is the directory holding `.claude`.
        #expect(found.map(\.sourceLabel) == ["dev", "a", "f"])
    }

    @Test func homeDirectoryFallsBackToItsClaudeSubdirectory() throws {
        let temp = try TemporaryDirectory()
        try makeClaude(temp, "Speedwave/alpha/home/.claude")
        let found = PathPattern(temp.url.path + "/Speedwave/*/home").expand()
        #expect(found.map(\.url.path) == [temp.url.path + "/Speedwave/alpha/home/.claude"])
        #expect(found.first?.sourceLabel == "alpha")

        let literal = PathPattern(temp.url.path + "/Speedwave/alpha/home").expand()
        #expect(literal.first?.url.lastPathComponent == ".claude")
        #expect(literal.first?.sourceLabel == "alpha", "label is the directory holding the home directory")
    }

    @Test func directoryWithSessionsIsUsedAsIs() throws {
        let temp = try TemporaryDirectory()
        try temp.makeDirectory("x/sessions")
        try makeClaude(temp, "x/.claude")
        let found = PathPattern(temp.url.path + "/x").expand()
        #expect(found.map(\.url.path) == [temp.url.path + "/x"])
    }

    @Test func duplicatesAreTrackedOnce() throws {
        let temp = try TemporaryDirectory()
        try makeClaude(temp, "real/.claude")
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("link"),
            withDestinationURL: temp.url.appendingPathComponent("real")
        )
        let found = expandPatterns([
            temp.url.path + "/real/.claude",
            temp.url.path + "/link/.claude",
            temp.url.path + "/*/.claude",
            "  ",
        ])
        #expect(found.map(\.url.path) == [temp.url.path + "/real/.claude"])
        #expect(found.first?.sourceLabel == "real")
    }

    @Test func literalRootIsDeepestDirectoryWithoutWildcards() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(PathPattern("~/Speedwave/*/home/.claude", homeDirectory: home).literalRoot.path == "/Users/me/Speedwave")
        #expect(PathPattern("/Volumes/dev/**/.claude", homeDirectory: home).literalRoot.path == "/Volumes/dev")
        #expect(PathPattern("~/.claude", homeDirectory: home).literalRoot.path == "/Users/me/.claude")
        #expect(PathPattern("~/Speedwave/*/home/.claude", homeDirectory: home).depthBelowRoot == 3)
        #expect(PathPattern("/Volumes/dev/**/.claude", homeDirectory: home).depthBelowRoot == nil)
    }

    @Test func missingPathMatchesNothing() {
        #expect(PathPattern("/definitely/not/here/*/.claude").expand().isEmpty)
    }
}
