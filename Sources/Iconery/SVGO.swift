import Foundation
import JavaScriptCore
import os

/// SVGO 4.1.0 from its browser build in Resources/svgo, run in JavaScriptCore so nothing needs
/// Node installed. One context serves every thread and a call holds the lock: drags write on
/// every core, and an icon takes about half a millisecond (measured), so the wait stays short.
enum SVGO {
    enum Failure: LocalizedError {
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "SVGO could not be loaded."
            case .rejected(let reason): "SVGO could not read it: \(reason)"
            }
        }
    }

    /// The browser build: the app bundle's copy, which build.sh puts there. Tests point it at the
    /// repo's before first use; it is read once.
    nonisolated(unsafe) static var script = Bundle.main.url(
        forResource: "svgo.browser", withExtension: "js"
    )

    private static let optimizer = OSAllocatedUnfairLock<JSValue?>(uncheckedState: load())

    /// `svg` through SVGO's default preset, repeated until it stops getting smaller. Version 4's
    /// preset keeps the viewBox and <title>, which an icon needs to scale and be named.
    static func optimize(_ svg: String) throws -> String {
        try optimizer.withLockUnchecked { optimize in
            guard let optimize, let context = optimize.context else { throw Failure.unavailable }
            let result = optimize.call(withArguments: [svg, ["multipass": true]])
            if let exception = context.exception {
                context.exception = nil
                // The rest of the message is a code frame pointing at the spot.
                let reason = exception.toString().split(separator: "\n").first.map(String.init)
                throw Failure.rejected(reason ?? "unknown error")
            }
            guard let data = result?.forProperty("data"), data.isString else {
                throw Failure.rejected("no output")
            }
            return data.toString()
        }
    }

    private static func load() -> JSValue? {
        guard let script, var source = try? String(contentsOf: script, encoding: .utf8),
              let exports = source.range(of: "export{", options: .backwards),
              let context = JSContext()
        else { return nil }
        // An ES module, which evaluateScript can't run. Its one export statement ends the file,
        // so that is swapped for a global.
        source.replaceSubrange(exports.lowerBound..., with: "globalThis.svgo={optimize};")
        context.evaluateScript(source)
        guard context.exception == nil,
              let optimize = context.objectForKeyedSubscript("svgo")?
                  .objectForKeyedSubscript("optimize"),
              !optimize.isUndefined
        else { return nil }
        return optimize
    }
}
