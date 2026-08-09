@testable import BrainSurfacerFilesystem
import BrainSurfacerModel
import Foundation
import Testing

@Test
func bbcodeParserInfersOnlyTopLevelStandaloneBoldHeadings() throws {
    let document = try bbcodeFixture()

    let entities = BBCodeParser().parseResult(document).entities
    let note = try #require(entities.first)
    let overview = try #require(entities.first { $0.title == "Overview and context" })
    let media = try #require(entities.first { $0.title == "Media" })

    #expect(entities.count == 3)
    #expect(note.title == "section-content")
    #expect(!entities.contains { $0.title == "Inline label" })
    #expect(!entities.contains { $0.title == "Quoted emphasis" })
    #expect(!entities.contains { $0.title == "literal markup" })
    #expect(overview.body?.contains("1. Inline label - remains list prose.") == true)
    #expect(overview.body?.contains("2. Second item with https://example.com/bare.") == true)
    #expect(overview.body?.contains("Quote from Alice:") == true)
    #expect(overview.body?.contains("Quoted emphasis\nQuoted body.") == true)
    #expect(overview.body?.contains("• Unordered item") == true)
    #expect(overview.body?.contains("1. Ordered item") == true)
    #expect(overview.body?.contains("Hard can be found at helper@example.com.") == true)
    #expect(overview.body?.contains("Opening design & café notes.") == true)
    #expect(media.body?.contains("Image: https://example.com/image.png") == true)
    #expect(media.body?.contains("[b]literal markup[/b]") == true)
    #expect(media.body?.contains("Spoiler (Details):\nHidden text.") == true)
    #expect(media.body?.contains("[UNKNOWN]kept[/UNKNOWN]") == true)
    #expect(overview.links == [
        URL(string: "https://example.com/design")!,
        URL(string: "https://example.com/bare")!,
        URL(string: "mailto:helper@example.com")!
    ])
    #expect(media.links == [URL(string: "https://example.com/image.png")!])
    #expect(overview.relationships == [Relationship(kind: .parent, target: note.id)])
    #expect(overview.source.line == 1)
    #expect(overview.source.endLine == 19)
    #expect(media.source.line == 20)
    #expect(sourceText(for: overview.source, in: document).hasPrefix("[b]Overview"))
    #expect(!sourceText(for: overview.source, in: document).contains("[B]Media[/B]"))
    #expect(note.attributes[EntityIdentityMetadata.structuralFingerprint] != nil)
    #expect(overview.attributes[EntityIdentityMetadata.structuralFingerprint] != nil)
}

@Test
func bbcodeParserRecoversConservativelyFromMalformedAndUnknownMarkup() throws {
    let document = SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/Malformed.bb.txt"),
        format: .bbcode,
        filenameSuffix: ".bb.txt",
        contents: """
        [b]Retained heading[/b]
        Before the malformed quote.
        [quote=Someone
        [b]Not promoted[/b]
        [custom=value]Unknown content[/custom]
        """
    )

    let entities = BBCodeParser().parseResult(document).entities

    #expect(entities.count == 2)
    #expect(entities[0].title == "Malformed")
    #expect(entities[0].body?.contains("[quote=Someone") == true)
    #expect(entities[0].body?.contains("[custom=value]Unknown content[/custom]") == true)
    #expect(entities[1].title == "Retained heading")
}

@Test
func bbcodeParserRequiresOneBoldSpanAndAcceptsSpacedTags() throws {
    let document = SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/Spaced.bb.txt"),
        format: .bbcode,
        filenameSuffix: ".bb.txt",
        contents: """
        [b]Alpha[/b] ordinary prose [b]Beta[/b]
        [quote = Alice]
        [b]Quoted emphasis[/b]
        [/quote ]
        [b]Actual [i]heading[/i][/b]
        [url = https://example.com/search?a=1&amp;b=2]Search[/url ]
        """
    )

    let entities = BBCodeParser().parseResult(document).entities
    let note = try #require(entities.first)
    let heading = try #require(entities.first { $0.title == "Actual heading" })

    #expect(entities.count == 2)
    #expect(!entities.contains { $0.title == "Alpha ordinary prose Beta" })
    #expect(!entities.contains { $0.title == "Quoted emphasis" })
    #expect(note.body?.contains("Alpha ordinary prose Beta") == true)
    #expect(note.body?.contains("Quote from Alice:") == true)
    #expect(note.body?.contains("Quoted emphasis") == true)
    #expect(heading.links == [URL(string: "https://example.com/search?a=1&b=2")!])
}

@Test
func bbcodeParserHandlesBracketDenseInputInLinearPasses() throws {
    let bracketRun = String(
        repeating: "[",
        count: OutlineParser.maximumSectionBodyBytes
    )
    let document = SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/Brackets.bb.txt"),
        format: .bbcode,
        filenameSuffix: ".bb.txt",
        contents: bracketRun
    )

    let entities = BBCodeParser().parseResult(document).entities
    let note = try #require(entities.first)

    #expect(entities.count == 1)
    #expect(note.body == bracketRun)
}

@Test
func scannerRegistersBBCodeWithoutAdmittingBackupsOrPlainText() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "BrainSurfacerBBCode-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let forumFile = root.appending(path: "Forum.BB.TXT")
    try "[b]Topic[/b]\nSearchable body.".write(
        to: forumFile,
        atomically: true,
        encoding: .utf8
    )
    try "[b]Backup[/b]".write(
        to: root.appending(path: "Forum.bb.txt#"),
        atomically: true,
        encoding: .utf8
    )
    try "ordinary text".write(
        to: root.appending(path: "Forum.txt"),
        atomically: true,
        encoding: .utf8
    )

    let result = try await SourceDirectoryScanner().scan(SourceDirectory(url: root))

    #expect(result.fileCount == 1)
    #expect(result.parsedFileCount == 1)
    #expect(result.entities.map(\.title) == ["Topic", "Forum"])
    #expect(result.fingerprints[forumFile.standardizedFileURL]?.parserIdentifier
        == "org.brainsurfacer.bbcode")
    #expect(result.fingerprints[forumFile.standardizedFileURL]?.parserRevision
        == BBCodeParser.outputRevision)
    #expect(result.diagnostics.isEmpty)
}

@Test
func bbcodeParserBoundsRenderedUnicodeBodiesWithoutBreakingCharacters() throws {
    let document = SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/Large.bb.txt"),
        format: .bbcode,
        filenameSuffix: ".bb.txt",
        contents: "[b]Large section[/b]\n"
            + String(repeating: "🧠", count: 140_000)
            + "\nhttps://example.com/outside"
    )

    let entities = BBCodeParser().parseResult(document).entities
    let note = try #require(entities.first)
    let section = try #require(entities.first { $0.title == "Large section" })

    #expect((note.body?.utf8.count ?? 0) <= OutlineParser.maximumDocumentBodyBytes)
    #expect((note.body?.utf8.count ?? 0) > OutlineParser.maximumDocumentBodyBytes - 64)
    #expect(note.attributes["bodyTruncated"] == "true")
    #expect(section.body?.utf8.count == OutlineParser.maximumSectionBodyBytes)
    #expect(section.attributes["bodyTruncated"] == "true")
    #expect(note.body?.last == "🧠")
    #expect(section.body?.last == "🧠")
    #expect(note.links.isEmpty)
    #expect(section.links.isEmpty)
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["BRAINSURFACER_BBCODE_CORPUS"] != nil,
        "Set BRAINSURFACER_BBCODE_CORPUS to scan a local BBCode corpus."
    )
)
func configuredBBCodeCorpusParsesWithoutDiagnostics() async throws {
    let path = try #require(
        ProcessInfo.processInfo.environment["BRAINSURFACER_BBCODE_CORPUS"]
    )
    let source = SourceDirectory(
        url: URL(fileURLWithPath: path, isDirectory: true),
        pathPolicy: SourcePathPolicy(includePatterns: ["**/*.bb.txt"])
    )

    let result = try await SourceDirectoryScanner().scan(source)

    #expect(result.fileCount > 0)
    #expect(result.parsedFileCount == result.fileCount)
    #expect(result.fingerprints.count == result.fileCount)
    #expect(result.entities.contains { $0.kind == .heading })
    #expect(result.diagnostics.isEmpty)
}

private func bbcodeFixture() throws -> SourceDocument {
    let fixtureURL = try #require(
        Bundle.module.url(
            forResource: "section-content.bb",
            withExtension: "txt",
            subdirectory: "Fixtures"
        )
    )
    return SourceDocument(
        fileURL: URL(fileURLWithPath: "/tmp/section-content.bb.txt"),
        format: .bbcode,
        filenameSuffix: ".bb.txt",
        contents: try String(contentsOf: fixtureURL, encoding: .utf8)
    )
}

private func sourceText(for anchor: SourceAnchor, in document: SourceDocument) -> String {
    guard let offset = anchor.byteOffset, let length = anchor.byteLength else {
        return ""
    }
    let bytes = Array(document.contents.utf8)
    return String(decoding: bytes[offset ..< offset + length], as: UTF8.self)
}
