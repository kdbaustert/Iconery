import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undoManager
    @State private var showsInspector = true

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            IconGridView()
                .navigationTitle(library.title(for: library.sidebar))
                .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search")
                .toolbar {
                    ToolbarItem { SortMenu() }
                    ToolbarItem {
                        Button { library.chooseAndImport() } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help("Import SVG, PNG, ICNS or ICO files and folders")
                    }
                    ToolbarItem {
                        Button { showsInspector.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                        .help(showsInspector ? "Hide the inspector" : "Show the inspector")
                    }
                }
                .overlay(alignment: .top) { ToastView() }
                .inspector(isPresented: $showsInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 400)
                }
        }
        .background(LibraryWindowMarker())
        .onChange(of: library.sidebar) { library.selection = [] }
        // The window's undo manager, so Edit ▸ Undo reaches the library while text fields
        // keep their own.
        .onAppear { library.undoManager = undoManager }
        .onChange(of: undoManager) { library.undoManager = undoManager }
        .task { await library.runBackupSchedule() }
        .alert(
            library.naming?.title ?? "", isPresented: isPresent(\.naming),
            presenting: library.naming
        ) { naming in
            TextField("Name", text: $library.draftName)
            Button("Cancel", role: .cancel) {}
            Button(naming.confirmTitle) { library.finishNaming(naming) }
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog(
            library.pendingDeletion?.title ?? "", isPresented: isPresent(\.pendingDeletion),
            titleVisibility: .visible, presenting: library.pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { library.perform(deletion) }
        } message: { deletion in
            Text(deletion.message)
        }
        .sheet(isPresented: isPresent(\.check)) { CheckResultsView() }
        .sheet(isPresented: $library.batchRenaming) { BatchRenameSheet() }
        .sheet(isPresented: isPresent(\.copiedCode)) { CopiedCodeSheet() }
        .alert(
            library.notice?.title ?? "", isPresented: isPresent(\.notice),
            presenting: library.notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }

    /// Presents while the optional at `keyPath` holds a value, and clears it on dismissal.
    private func isPresent<Value>(
        _ keyPath: ReferenceWritableKeyPath<Library, Value?>
    ) -> Binding<Bool> {
        Binding(
            get: { library[keyPath: keyPath] != nil },
            set: { if !$0 { library[keyPath: keyPath] = nil } }
        )
    }
}

/// The import, move or delete confirmation at the top of the grid, just under the toolbar where
/// the eye already is: a glass capsule that drops in, with a coloured badge saying which. It fades after three seconds, and clicks pass through it
/// to the icons beneath.
private struct ToastView: View {
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            if let toast = library.toast {
                let (symbol, tint): (String, Color) = switch toast.kind {
                case .done: ("checkmark", .green)
                case .moved: ("folder.fill", .blue)
                case .deleted: ("trash.fill", .red)
                }
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(tint.gradient, in: Circle())
                        .accessibilityHidden(true)
                    Text(toast.text)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 6)
                .padding(.trailing, 16)
                .padding(.vertical, 6)
                .modifier(GlassCapsule())
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                        AccessibilityNotification.Announcement(toast.text).post()
                        // A newer toast cancels this wait and starts its own three seconds.
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled, library.toast == toast else { return }
                        library.toast = nil
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: library.toast)
    }
}

/// Liquid Glass where the system has it, and the frosted material that came before it elsewhere.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator) }
        }
    }
}

/// Renames the whole selection at once. The preview and the Rename button go through the same
/// BatchRename.newName, so what's shown is what happens.
private struct BatchRenameSheet: View {
    @Environment(Library.self) private var library
    @State private var rename = BatchRename()

    var body: some View {
        // batchRenameTargets, not selectedIcons: the rename applies in the grid's order,
        // which Recently Used sorts by last use, and Sequence numbers must match the preview.
        let icons = library.batchRenameTargets
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(plural(icons.count, "Icon"))")
                .font(.title3.bold())
            Picker("Mode", selection: $rename.mode) {
                ForEach(BatchRename.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch rename.mode {
            case .replace:
                TextField("Find", text: $rename.find)
                TextField("Replace with", text: $rename.replacement)
            case .add:
                TextField("Prefix", text: $rename.prefix)
                TextField("Suffix", text: $rename.suffix)
            case .sequence:
                TextField("Base name", text: $rename.base)
                Stepper("Start at \(rename.startsAt)", value: $rename.startsAt, in: 0...9999)
            }
            let pairs = previewPairs(icons)
            VStack(alignment: .leading, spacing: 2) {
                // Keyed by icon id, not by old name: two icons sharing a name are two rows.
                ForEach(pairs.prefix(4), id: \.id) { pair in
                    let (old, new) = (pair.old, pair.new)
                    Text(old == new ? "\(old) — unchanged" : "\(old) → \(new)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if pairs.count > 4 {
                    Text("…and \(pairs.count - 4) more").font(.callout).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { library.batchRenaming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    library.batchRename(Set(icons.map(\.id)), applying: rename)
                    library.batchRenaming = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pairs.allSatisfy { $0.old == $0.new })
            }
        }
        .padding(20)
        .frame(width: 400)
        .textFieldStyle(.roundedBorder)
    }

    /// Old and new name per icon, with "no change" answers folded back to the old name.
    private func previewPairs(_ icons: [Icon]) -> [(id: UUID, old: String, new: String)] {
        icons.enumerated().map { index, icon in
            let raw = rename.newName(for: icon.name, index: index)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.isEmpty else { return (icon.id, icon.name, icon.name) }
            return (icon.id, icon.name, raw)
        }
    }
}

/// The code Copy SVG Code just put on the clipboard, read-only, so what's shown is what pastes.
private struct CopiedCodeSheet: View {
    @Environment(Library.self) private var library

    var body: some View {
        let copied = library.copiedCode
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(copied?.iconName ?? "")” SVG Code")
                .font(.title3.bold())
            Text(copied?.unoptimizedReason.map { "Copied without optimizing. \($0)" }
                 ?? "Copied to the clipboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
            CodeView(text: copied?.code ?? "")
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
            HStack {
                Spacer()
                Button("Copy") { Library.copyText(copied?.code ?? "") }
                Button("Done") { library.copiedCode = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

/// An NSTextView rather than Text: a bitmap's code is one line holding hundreds of kilobytes of
/// base64, and NSTextView lays out only what's on screen.
private struct CodeView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.font = SVGHighlighter.font
            textView.backgroundColor = SVGHighlighter.background
            textView.selectedTextAttributes = [.backgroundColor: SVGHighlighter.selection]
            textView.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text
        else { return }
        textView.textStorage?.setAttributedString(SVGHighlighter.highlight(text))
    }
}

/// Colours SVG the way VS Code's Monokai colours XML, on its editor background in light mode
/// too, since the colours are made for it. Brackets and "=" have no colour of their own there,
/// so they stay plain. Regular expressions, not a parser, so code SVGO couldn't read still gets
/// coloured as far as it can.
@MainActor
enum SVGHighlighter {
    static let font = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular
    )
    static let background = rgb(0x272822)
    static let selection = rgb(0x878B91, alpha: 0x80)
    static let plain = rgb(0xF8F8F2)
    static let comment = rgb(0x88846F)
    static let element = rgb(0xF92672)
    static let attribute = rgb(0xA6E22E)
    static let value = rgb(0xE6DB74)

    // Comments and CDATA come first in the alternation so a "<" inside one isn't read as a tag.
    // A tag skips over quoted values, so a ">" inside one doesn't end it.
    private static let token = regex(
        #"<!--[\s\S]*?(?:-->|$)|<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|<(?:"[^"]*"|'[^']*'|[^'">])*>?"#
    )
    private static let elementName = regex(#"^<[?!/]?([\w:.-]+)"#)
    private static let attributeValue = regex(#"([\w:.-]+)\s*=\s*("[^"]*"?|'[^']*'?)"#)

    static func highlight(_ code: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code, attributes: [.font: font, .foregroundColor: plain]
        )
        let all = NSRange(location: 0, length: result.length)
        for match in token.matches(in: code, range: all) {
            let tag = match.range
            let opening = code.utf16.dropFirst(tag.location)
            if opening.starts(with: "<!--".utf16) {
                result.addAttribute(.foregroundColor, value: comment, range: tag)
                continue
            }
            // CDATA holds text, often a style sheet, whose "a=b" isn't an attribute.
            if opening.starts(with: "<![CDATA[".utf16) { continue }
            if let name = elementName.firstMatch(in: code, options: .anchored, range: tag) {
                result.addAttribute(.foregroundColor, value: element, range: name.range(at: 1))
            }
            for pair in attributeValue.matches(in: code, range: tag) {
                result.addAttribute(.foregroundColor, value: attribute, range: pair.range(at: 1))
                result.addAttribute(.foregroundColor, value: value, range: pair.range(at: 2))
            }
        }
        return result
    }

    private static func rgb(_ hex: Int, alpha: Int = 0xFF) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha) / 255
        )
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals above, so a bad one is a programmer error caught at launch.
        try! NSRegularExpression(pattern: pattern)
    }
}

/// What Check Library found, with one fix per section. Each fix empties its section, so what
/// remains to do stays in front of you.
private struct CheckResultsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let check = library.check ?? .init()
        VStack(alignment: .leading, spacing: 14) {
            Text("Library Check")
                .font(.title3.bold())
            if check.isClean {
                Label("Nothing to fix. Every record has its file, every file its record, and no "
                      + "two icons share one content.", systemImage: "checkmark.seal")
            }
            if !check.duplicateGroups.isEmpty {
                section(
                    "\(plural(check.duplicateGroups.count, "group")) of identical icons",
                    names: check.duplicateGroups.map {
                        "\($0.first?.name ?? "") (\(plural($0.count, "copy", "copies")))"
                    },
                    fix: "Delete Duplicates, Keeping the Oldest",
                    action: library.deleteDuplicates
                )
            }
            if !check.missing.isEmpty {
                section(
                    "\(plural(check.missing.count, "icon")) missing their files",
                    names: check.missing.map(\.name),
                    fix: "Remove Their Records",
                    action: library.removeMissingRecords
                )
            }
            if !check.orphans.isEmpty {
                section(
                    "\(plural(check.orphans.count, "file")) no icon record names",
                    names: check.orphans.map(\.lastPathComponent),
                    fix: "Move Them to the Trash",
                    action: library.trashOrphans
                )
            }
            HStack {
                Spacer()
                Button("Done") { library.check = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func section(
        _ title: String, names: [String], fix: String, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            let shown = names.prefix(6).joined(separator: "\n")
                + (names.count > 6 ? "\n…and \(names.count - 6) more" : "")
            Text(shown)
                .foregroundStyle(.secondary)
                .font(.callout)
            Button(fix, action: action)
        }
    }
}

/// The toolbar's sort menu: the key and, under it, the direction, named for the key ("Z to A"
/// for names, "Newest First" for dates). Settings ▸ General keeps its sort picker; both read the
/// same preference, and picking a key resets the direction in Preferences itself.
private struct SortMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var preferences = library.preferences
        Menu {
            Picker("Sort By", selection: $preferences.sort) {
                ForEach(GridSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Direction", selection: $preferences.sortDescending) {
                Text(preferences.sort.ascendingTitle).tag(false)
                Text(preferences.sort.descendingTitle).tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("How the grid is sorted")
    }
}

/// Tells the app delegate which window is the library's, so ⌘⌫ can tell it from a sheet or
/// from Settings.
private struct LibraryWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            AppDelegate.libraryWindow = window
        }
    }
}
