import Foundation
#if canImport(os)
import os
#endif

/// Thin wrapper so the core stays Foundation-only on platforms without `os.Logger`.
enum Log {
    #if canImport(os)
    private static let parserLogger = Logger(subsystem: "local.agenttray", category: "parser")
    #endif

    static func parser(_ message: String) {
        #if canImport(os)
        parserLogger.error("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[parser] \(message)\n".utf8))
        #endif
    }
}
