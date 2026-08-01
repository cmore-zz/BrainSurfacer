import Foundation

public enum SourceEnrollmentSettings {
    public static let bookmarkStorageKey = "sourceDirectoryBookmarks"
}

/// Grants temporary access to a source document while an operation is in
/// flight. Core does not prescribe whether access comes from a sandbox
/// bookmark, an editor, or an unrestricted process.
public protocol DocumentAccessProvider: Sendable {
    func performWithAccess(
        to documentURL: URL,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws
}

/// Marker for failures whose user-facing explanation was already presented by
/// the operating system or editor.
public protocol UserPresentedDocumentOpeningError: Error, Sendable {}
