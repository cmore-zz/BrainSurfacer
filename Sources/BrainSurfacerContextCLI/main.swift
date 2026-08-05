import BrainSurfacerCore
import Darwin
import Foundation

@main
struct BrainSurfacerContextCommand {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments.dropFirst())
            if arguments.showsHelp {
                print(Arguments.usage)
                return
            }

            let update = try arguments.editorContextUpdate()
            let url = BrainSurfacerDeepLink.context(update).url
            if arguments.onlyPrintsURL {
                print(url.absoluteString)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments.openArguments(for: url)
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CommandError.launchFailed(process.terminationStatus)
            }
        } catch {
            FileHandle.standardError.write(
                Data("brainsurfacer-context: \(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}

private struct Arguments {
    static let usage = """
    Usage:
      brainsurfacer-context --provider ID [--ttl SECONDS]
        [--selected PATH] [--visible PATH] [--open PATH]
        [--application APP] [--print-url]
      brainsurfacer-context --input FILE [--application APP] [--print-url]

    Send a complete, expiring editor snapshot to BrainSurfacer. Repeat document
    flags as needed, or read grouped path arrays from a JSON file. Use --input -
    to read bounded JSON from standard input. Sending no documents clears that
    provider's live context. Use --application to target an exact app bundle
    instead of asking Launch Services to choose a URL-scheme handler.
    """

    var providerID = ""
    var timeToLive = EditorContextUpdate.defaultTimeToLive
    var documents: [EditorContextDocument] = []
    var inputPath: String?
    var applicationPath: String?
    var onlyPrintsURL = false
    var showsHelp = false
    private var hasProviderOption = false
    private var hasTimeToLiveOption = false
    private var hasDocumentOptions = false

    init<S: Sequence>(_ rawArguments: S) throws where S.Element == String {
        let arguments = Array(rawArguments)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                showsHelp = true
                index += 1
            case "--print-url":
                onlyPrintsURL = true
                index += 1
            case "--provider":
                providerID = try Self.value(after: argument, in: arguments, at: index)
                hasProviderOption = true
                index += 2
            case "--ttl":
                let value = try Self.value(after: argument, in: arguments, at: index)
                guard let seconds = TimeInterval(value) else {
                    throw CommandError.invalidValue(option: argument, value: value)
                }
                timeToLive = seconds
                hasTimeToLiveOption = true
                index += 2
            case "--input":
                inputPath = try Self.value(after: argument, in: arguments, at: index)
                index += 2
            case "--application":
                applicationPath = try Self.value(
                    after: argument,
                    in: arguments,
                    at: index
                )
                index += 2
            case "--selected", "--visible", "--open":
                let value = try Self.value(after: argument, in: arguments, at: index)
                documents.append(
                    EditorContextDocument(
                        fileURL: Self.fileURL(for: value),
                        relevance: Self.relevance(for: argument)
                    )
                )
                hasDocumentOptions = true
                index += 2
            default:
                throw CommandError.unknownOption(argument)
            }
        }

        guard !showsHelp else {
            return
        }
        if inputPath != nil,
           hasProviderOption || hasTimeToLiveOption || hasDocumentOptions {
            throw CommandError.conflictingInputOptions
        }
        if inputPath == nil, providerID.isEmpty {
            throw CommandError.missingOption("--provider")
        }
    }

    func editorContextUpdate() throws -> EditorContextUpdate {
        guard let inputPath else {
            return try EditorContextUpdate(
                providerID: providerID,
                timeToLive: timeToLive,
                documents: documents
            )
        }

        let input: Data
        let baseDirectory: URL
        if inputPath == "-" {
            input = try Self.readStandardInput()
            baseDirectory = Self.workingDirectory
        } else {
            let inputURL = Self.fileURL(for: inputPath)
            let fileSize = try inputURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
            if let fileSize, fileSize > EditorContextInput.maximumJSONBytes {
                throw EditorContextInput.Error.payloadTooLarge
            }
            input = try Data(contentsOf: inputURL, options: .mappedIfSafe)
            baseDirectory = inputURL.deletingLastPathComponent()
        }
        let context = try EditorContextInput.decodeJSON(input)
        return try context.update(relativeTo: baseDirectory)
    }

    func openArguments(for url: URL) -> [String] {
        var result = ["-g"]
        if let applicationPath {
            result.append(contentsOf: ["-a", applicationPath])
        }
        result.append(url.absoluteString)
        return result
    }

    private static func value(
        after option: String,
        in arguments: [String],
        at index: Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CommandError.missingValue(option)
        }
        return arguments[valueIndex]
    }

    private static func fileURL(for path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: workingDirectory)
            .standardizedFileURL
    }

    private static var workingDirectory: URL {
        URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    }

    private static func readStandardInput() throws -> Data {
        var result = Data()
        let maximumRead = EditorContextInput.maximumJSONBytes + 1
        while result.count < maximumRead {
            let remaining = maximumRead - result.count
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(8_192, remaining)
            ), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private static func relevance(for option: String) -> ContextRelevance {
        switch option {
        case "--selected": .selected
        case "--visible": .visible
        default: .open
        }
    }
}

private enum CommandError: LocalizedError {
    case unknownOption(String)
    case missingOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case conflictingInputOptions
    case launchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .unknownOption(option):
            "Unknown option \(option).\n\n\(Arguments.usage)"
        case let .missingOption(option):
            "Missing required option \(option).\n\n\(Arguments.usage)"
        case let .missingValue(option):
            "Missing value after \(option)."
        case let .invalidValue(option, value):
            "Invalid value \(value) for \(option)."
        case .conflictingInputOptions:
            "--input cannot be combined with --provider, --ttl, or document flags."
        case let .launchFailed(status):
            "Could not deliver context to BrainSurfacer (open exited \(status))."
        }
    }
}
