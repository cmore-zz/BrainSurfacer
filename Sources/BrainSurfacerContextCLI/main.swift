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

            let update = try EditorContextUpdate(
                providerID: arguments.providerID,
                timeToLive: arguments.timeToLive,
                documents: arguments.documents
            )
            let url = BrainSurfacerDeepLink.context(update).url
            if arguments.onlyPrintsURL {
                print(url.absoluteString)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", url.absoluteString]
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
        [--selected PATH] [--visible PATH] [--open PATH] [--print-url]

    Send a complete, expiring editor snapshot to BrainSurfacer. Repeat document
    flags as needed. Sending no documents clears that provider's live context.
    """

    var providerID = ""
    var timeToLive = EditorContextUpdate.defaultTimeToLive
    var documents: [EditorContextDocument] = []
    var onlyPrintsURL = false
    var showsHelp = false

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
                index += 2
            case "--ttl":
                let value = try Self.value(after: argument, in: arguments, at: index)
                guard let seconds = TimeInterval(value) else {
                    throw CommandError.invalidValue(option: argument, value: value)
                }
                timeToLive = seconds
                index += 2
            case "--selected", "--visible", "--open":
                let value = try Self.value(after: argument, in: arguments, at: index)
                documents.append(
                    EditorContextDocument(
                        fileURL: Self.fileURL(for: value),
                        relevance: Self.relevance(for: argument)
                    )
                )
                index += 2
            default:
                throw CommandError.unknownOption(argument)
            }
        }

        if !showsHelp, providerID.isEmpty {
            throw CommandError.missingOption("--provider")
        }
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
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: path, relativeTo: workingDirectory)
            .standardizedFileURL
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
        case let .launchFailed(status):
            "Could not deliver context to BrainSurfacer (open exited \(status))."
        }
    }
}
