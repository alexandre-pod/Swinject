//
//  Copyright © 2019 Swinject Contributors. All rights reserved.
//

public typealias LoggingFunctionType = (String) -> Void

public extension Container {
    /// Function to be used for logging debugging data.
    /// Default implementation writes to standard output.
    static var loggingFunction: LoggingFunctionType? {
        get { return _loggingFunction }
        set { _loggingFunction = newValue }
    }

    internal static func log(_ message: String) {
        _loggingFunction?(message)
    }
}

// TODO: Make this property more safe to access. Either with documentation or with a lock.
private nonisolated(unsafe) var _loggingFunction: LoggingFunctionType? = { print($0) }
