import Foundation
import Testing
@testable import AgentTrayCore

struct TranscriptReaderTests {
    @Test func readsAppendedLinesIncrementally() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.write("s.jsonl", Line.prompt("Hej") + Line.toolUse("t1", "AskUserQuestion"))
        let reader = TranscriptReader(url: file)
        try reader.update()
        #expect(classify(facts: reader.facts, settings: .default, now: fixtureTime(5)) == .askingQuestion)

        try temp.append("s.jsonl", Line.toolResult("t1") + Line.text("Dzięki") + Line.turnDuration())
        try reader.update()
        #expect(classify(facts: reader.facts, settings: .default, now: fixtureTime(5)) == .yourTurn)
        #expect(reader.facts.lastMessage == "Dzięki")
    }

    @Test func incompleteLastLineWaitsForTheRest() throws {
        let temp = try TemporaryDirectory()
        let line = Line.text("Całość")
        let cut = line.index(line.startIndex, offsetBy: 40)
        let file = try temp.write("s.jsonl", Line.prompt("Hej") + String(line[..<cut]))
        let reader = TranscriptReader(url: file)
        try reader.update()
        #expect(reader.facts.lastMessage == nil)
        #expect(reader.invalidLineCount == 0)

        try temp.append("s.jsonl", String(line[cut...]))
        try reader.update()
        #expect(reader.facts.lastMessage == "Całość")
        #expect(reader.invalidLineCount == 0)
    }

    @Test func invalidJSONLineIsSkipped() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.write("s.jsonl", Line.prompt("Hej") + "{to nie jest json\n" + Line.text("Dalej działa"))
        let reader = TranscriptReader(url: file)
        try reader.update()
        #expect(reader.invalidLineCount == 1)
        #expect(reader.facts.lastMessage == "Dalej działa")
        #expect(reader.facts.lastPrompt == "Hej")
    }

    @Test func truncatedFileIsReadAgain() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.write("s.jsonl", Line.prompt("Stary") + Line.text("Stara odpowiedź") + Line.turnDuration())
        let reader = TranscriptReader(url: file)
        try reader.update()
        #expect(reader.facts.turnEnded)

        // Overwrite in place with shorter contents: same inode, smaller size.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(Line.prompt("Nowy").utf8))
        try handle.close()
        try reader.update()
        #expect(reader.facts.lastPrompt == "Nowy")
        #expect(reader.facts.lastMessage == nil)
        #expect(!reader.facts.turnEnded)
    }

    @Test func replacedFileIsReadAgain() throws {
        let temp = try TemporaryDirectory()
        let file = try temp.write("s.jsonl", Line.prompt("Stary") + Line.text("Stara odpowiedź"))
        let reader = TranscriptReader(url: file)
        try reader.update()

        // A new file under the same name, longer than the old one: only the inode tells.
        let replacement = try temp.write("other.jsonl", Line.prompt("Nowy prompt, dłuższy niż poprzedni") + Line.toolUse("t1", "Agent"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        try reader.update()
        #expect(reader.facts.lastPrompt == "Nowy prompt, dłuższy niż poprzedni")
        #expect(reader.facts.lastMessage == nil)
        #expect(classify(facts: reader.facts, settings: .default, now: fixtureTime(5)) == .waitingForSubagents(1))
    }

    @Test func firstWindowDropsCutLineAndBacksOffForPromptAndTitle() throws {
        let temp = try TemporaryDirectory()
        let filler = (0..<200).map { Line.json(["type": "progress", "i": $0, "pad": String(repeating: "x", count: 100)]) }.joined()
        let tail = Line.toolUse("t1", "Bash", input: ["description": "Run tests"], at: 50)
        let contents = Line.aiTitle("Tytuł z początku") + Line.prompt("Pierwszy prompt") + Line.lastPrompt("Pierwszy prompt")
            + Line.text("Stara wiadomość") + filler + tail
        let file = try temp.write("s.jsonl", contents)

        let window = 1024
        let reader = TranscriptReader(url: file, windowSize: window)
        try reader.update()
        #expect(reader.invalidLineCount == 0, "the cut first line of each window must be dropped, not parsed")
        #expect(reader.facts.lastPrompt == "Pierwszy prompt")
        #expect(reader.facts.transcriptTitle == "Tytuł z początku")
        #expect(classify(facts: reader.facts, settings: .default, now: fixtureTime(51)) == .runningTool(name: "Bash", summary: "Run tests"))
    }

    @Test func backoffStopsWhenWindowHasPromptAndTitle() throws {
        let temp = try TemporaryDirectory()
        // The old prompt sits far before the window; a newer one is inside it.
        let filler = (0..<200).map { Line.json(["type": "progress", "i": $0, "pad": String(repeating: "x", count: 100)]) }.joined()
        let contents = Line.lastPrompt("Stary prompt") + filler + Line.aiTitle("Tytuł") + Line.lastPrompt("Nowy prompt")
        let file = try temp.write("s.jsonl", contents)
        let reader = TranscriptReader(url: file, windowSize: 1024)
        try reader.update()
        #expect(reader.facts.lastPrompt == "Nowy prompt")
    }

    @Test func largeTranscriptReadsOnlyTheWindow() throws {
        let temp = try TemporaryDirectory()
        let filler = Line.json(["type": "progress", "pad": String(repeating: "y", count: 1000)])
        var contents = Line.aiTitle("Duża sesja") + Line.lastPrompt("Prompt")
        contents += String(repeating: filler, count: 10_000)  // ~10 MB
        contents += Line.text("Koniec") + Line.turnDuration()
        let file = try temp.write("s.jsonl", contents)
        let reader = TranscriptReader(url: file)
        let start = Date()
        try reader.update()
        #expect(reader.facts.lastMessage == "Koniec")
        #expect(reader.facts.lastPrompt == "Prompt")
        #expect(reader.facts.transcriptTitle == "Duża sesja")
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
