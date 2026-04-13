import XCTest

// FramingParser is in the Daemon module — added to DaemonTests target in Xcode.

final class SocketServerFramingTests: XCTestCase {

    // MARK: - 1. Single complete message

    func testSingleCompleteMessage() {
        var parser = FramingParser()
        let input = Data(#"{"type":"getStatus"}"#.utf8 + [UInt8(ascii: "\n")])
        let lines = parser.feed(input)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], Data(#"{"type":"getStatus"}"#.utf8))
    }

    // MARK: - 2. Two messages in one chunk

    func testTwoMessagesInOneChunk() {
        var parser = FramingParser()
        let input = Data(#"{"type":"getStatus"}\n{"type":"enableCharging"}\n"#
            .replacingOccurrences(of: "\\n", with: "\n").utf8)
        let lines = parser.feed(input)
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: - 3. Message split across two reads

    func testMessageSplitAcrossTwoReads() {
        var parser = FramingParser()
        let part1 = Data(#"{"type":"get"#.utf8)
        let part2 = Data(#"Status"}\n"#.replacingOccurrences(of: "\\n", with: "\n").utf8)

        let lines1 = parser.feed(part1)
        XCTAssertEqual(lines1.count, 0, "Incomplete message should not be yielded")

        let lines2 = parser.feed(part2)
        XCTAssertEqual(lines2.count, 1)
        XCTAssertEqual(lines2[0], Data(#"{"type":"getStatus"}"#.utf8))
    }

    // MARK: - 4. Empty lines are ignored

    func testEmptyLinesAreIgnored() {
        var parser = FramingParser()
        let input = Data("\n\n".utf8) + Data(#"{"type":"getStatus"}"#.utf8) + Data("\n".utf8)
        let lines = parser.feed(input)
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: - 5. Partial followed by complete in separate feed

    func testPartialThenCompleteInSeparateFeed() {
        var parser = FramingParser()
        _ = parser.feed(Data(#"{"type":"setLim"#.utf8))
        _ = parser.feed(Data(#"it","percentage":80}"#.utf8))
        let lines = parser.feed(Data("\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].count > 0)
    }
}
