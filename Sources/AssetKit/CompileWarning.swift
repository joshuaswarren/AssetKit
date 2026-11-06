import Foundation

/// A warning about the catalog that does not stop the compile, in the form
/// actool prints it: `<catalog>:<path>: warning: <message>`.
public struct CompileWarning: Sendable, Equatable {
    /// The asset the warning is about: its path relative to the catalog root
    /// the way actool writes it (`./AppIcon.appiconset`), or its name.
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}
