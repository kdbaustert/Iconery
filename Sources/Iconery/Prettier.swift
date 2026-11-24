import Foundation
import JavaScriptCore
import os

/// Prettier 3.10.1 with @prettier/plugin-xml 3.4.2, run in JavaScriptCore like SVGO. An icon
/// takes a few milliseconds and a 720 KB embedded bitmap about 14 (measured). The bundle is
/// `esbuild entry.mjs --bundle --minify --format=iife --legal-comments=none`, where entry.mjs
/// imports `format` from "prettier/standalone" and the plugin, and sets
/// `globalThis.prettier = { format, plugins: [xml] }`.
enum Prettier {
    /// The bundle: the app bundle's copy, which build.sh puts there. Tests point it at the repo's
    /// before first use; it is read once.
    nonisolated(unsafe) static var script = Bundle.main.url(
        forResource: "prettier-xml", withExtension: "js"
    )

    private static let context = OSAllocatedUnfairLock<JSContext?>(uncheckedState: load())

    /// `svg` laid out one element per line, with attributes wrapped onto their own lines past
    /// 100 columns, or nil when Prettier isn't bundled or can't read it. Whitespace inside an
    /// element is treated as insignificant, which SVG's default xml:space already does.
    static func format(_ svg: String) -> String? {
        context.withLockUnchecked { context in
            guard let context else { return nil }
            // format returns a promise. JavaScriptCore runs its callbacks before the call
            // returns to Swift, so the result is already in the globals afterwards.
            context.objectForKeyedSubscript("formatSVG").call(withArguments: [svg])
            context.exception = nil
            let formatted = context.objectForKeyedSubscript("formatted")
            return formatted?.isString == true ? formatted?.toString() : nil
        }
    }

    private static func load() -> JSContext? {
        guard let script, let source = try? String(contentsOf: script, encoding: .utf8),
              let context = JSContext()
        else { return nil }
        context.evaluateScript(source)
        context.evaluateScript("""
            function formatSVG(svg) {
                formatted = undefined;
                prettier.format(svg, {
                    parser: "xml", plugins: prettier.plugins, printWidth: 100,
                    xmlWhitespaceSensitivity: "ignore"
                }).then(text => { formatted = text; }, () => {});
            }
            """)
        return context.exception == nil ? context : nil
    }
}
