import SwiftUI
import UIKit

/// The terminal a command-line Mac program runs in, without macOS (experimental; Native/henge-tl-term.c).
final class TerminalSession: ObservableObject {
    static let shared = TerminalSession()
    let screen = TerminalScreen(cols: 60, rows: 30)
    /// Guards `screen`: the program draws from a thread of its own.
    private let lock = NSLock()
    private var redrawAsked = false
    weak var view: TerminalUIView?
    @Published var status = ""
    @Published var asked: URL?
    private(set) var started = false

    func read<T>(_ body: (TerminalScreen) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(screen) }

    fileprivate func output(_ bytes: [UInt8]) {
        var answers = ""
        lock.lock()
        screen.reply = { answers += $0 }
        screen.copied = { t in DispatchQueue.main.async { UIPasteboard.general.string = t; TerminalSession.shared.note("Copied") } }
        screen.feed(bytes)
        let ask = !redrawAsked
        redrawAsked = true
        lock.unlock()
        if !answers.isEmpty { send(answers) }
        if ask {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.lock.lock(); self.redrawAsked = false; self.lock.unlock()
                self.view?.contentChanged()
            }
        }
    }

    private let typing = DispatchQueue(label: "terminal input")
    func send(_ s: String) {
        let bytes = Array(s.utf8)
        typing.async { bytes.withUnsafeBufferPointer { p in p.withMemoryRebound(to: CChar.self) { henge_tl_term_write($0.baseAddress, $0.count) } } }
    }
    /// A short word at the top, gone by itself.
    @Published var said = ""
    private var saidCount = 0
    func note(_ s: String) {
        said = s
        saidCount += 1
        let n = saidCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if n == self.saidCount { self.said = "" } }
    }
    func copy(_ s: String) {
        guard !s.isEmpty else { note("Nothing to copy"); return }
        UIPasteboard.general.string = s
        note("Copied")
    }
    func pasteClipboard() {
        let b = UIPasteboard.general
        guard let s = b.string ?? b.url?.absoluteString, !s.isEmpty else {
            note(b.hasStrings || b.hasURLs ? "iOS refused: use the blue Paste button" : "Nothing to paste")
            return
        }
        paste(s)
    }
    func paste(_ s: String) {
        // What copying picks up at the end is not part of it, and would press return.
        var s = s
        while let l = s.last, l.isNewline { s.removeLast() }
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r").replacingOccurrences(of: "\u{1b}", with: "")
        send(read { $0.bracketedPaste } ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        screen.resize(cols: cols, rows: rows)
        lock.unlock()
        if started { henge_tl_term_resize(Int32(cols), Int32(rows)) }
    }

    /// Files › Henge › Projects: where the programs start.
    static var projects: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects", isDirectory: true)
    }
    /// Their home folder, out of Files' sight: Claude Code keeps its sign-in there.
    static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Terminal Home", isDirectory: true)
    }

    /// One of the kit's tools, run in this process.
    private static func runTool(_ tool: String, _ args: [String], _ env: [String], _ cwd: String?) -> (code: Int32, output: String) {
        var e: [UnsafePointer<CChar>?] = env.map { UnsafePointer(strdup($0)) } + [nil]
        let got = Collected()
        var argv: [UnsafePointer<CChar>?] = ([tool] + args).map { UnsafePointer(strdup($0)) } + [nil]
        let rc = henge_tl_tool_run(tool, Int32(args.count + 1), &argv, &e, cwd, { ctx, p, n in
            guard let ctx, let p else { return }
            Unmanaged<Collected>.fromOpaque(ctx).takeUnretainedValue().add(p, n)
        }, Unmanaged.passUnretained(got).toOpaque())
        for p in argv + e where p != nil { free(UnsafeMutableRawPointer(mutating: p)) }
        return (rc, String(decoding: got.data, as: UTF8.self))
    }
    private final class Collected {
        private let lock = NSLock()
        private(set) var data = Data()
        private let pass: ((Data) -> Void)?
        init(_ pass: ((Data) -> Void)? = nil) { self.pass = pass }
        func add(_ p: UnsafePointer<CChar>, _ n: Int) {
            let d = Data(bytes: p, count: n)
            if let pass { pass(d); return }
            lock.lock(); data.append(d); lock.unlock()
        }
    }
    private static func runProgram(_ path: String, _ argv0: String, _ entry: String, _ env: [String], _ output: @escaping (Data) -> Void) -> Int32 {
        var e: [UnsafePointer<CChar>?] = env.map { UnsafePointer(strdup($0)) } + [nil]
        // Kept: a thread of the program that outlives it may still write.
        let box = Unmanaged.passRetained(Collected(output))
        return henge_tl_program_run(path, strdup(argv0), entry, &e, { ctx, p, n in
            guard let ctx, let p else { return }
            Unmanaged<Collected>.fromOpaque(ctx).takeUnretainedValue().add(p, n)
        }, box.toOpaque())
    }
    private var server: ToolServer?

    func start(_ app: MacApp, arguments: String) {
        guard !started else { return }
        started = true
        status = "Loading \(app.name)…"
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.projects, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.home, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.path
        // What Bun programs (Claude Code) need where no code may be generated: no JIT, and a SharedArrayBuffer.
        let pre = fm.temporaryDirectory.appendingPathComponent("terminal-preload.js")
        try? "globalThis.SharedArrayBuffer ??= ArrayBuffer;\n".write(to: pre, atomically: true, encoding: .utf8)
        var env = ["HOME=\(Self.home.path)", "TMPDIR=\(tmp)", "TERM=xterm-256color", "COLORTERM=truecolor",
                   "LANG=en_US.UTF-8", "SHELL=/bin/sh", "PATH=/henge/bin:/usr/bin:/bin", "USER=mobile"]
        env += ["BUN_JSC_useJIT=0", "BUN_OPTIONS=--preload=\(pre.path)", "CLAUDE_CODE_TMPDIR=\(tmp)", "DISABLE_AUTOUPDATER=1"]
        var args = arguments.split(separator: " ").map(String.init)
        let projects = ProjectTools.projects(in: Self.projects)
        if (app.executable as NSString).lastPathComponent.lowercased().hasPrefix("claude") {
            let s = ToolServer(tools: ProjectTools.make(folder: Self.projects, home: Self.home, token: { GitHubToken.read() }, run: Self.runTool, program: Self.runProgram, stop: { henge_tl_program_stop() }, stopTools: { henge_tl_tool_stop($0) }) {
                HengeLog.log("macapps", "terminal: \($0)")
            })
            if s.start() {
                let config = Self.home.appendingPathComponent("henge-tools.json")
                s.writeConfig(to: config, github: GitHubToken.read())
                args += ["--mcp-config", config.path]
                env += ["MCP_TOOL_TIMEOUT=1800000", "MCP_TIMEOUT=60000"]
                server = s
                HengeLog.log("macapps", "terminal: build tools on port \(s.port), \(projects.count) project(s)")
            }
        }
        env.append("PWD=\((projects.count == 1 ? projects[0] : Self.projects).path)")
        let (cols, rows) = read { ($0.cols, $0.rows) }
        let path = app.executable, dir = (projects.count == 1 ? projects[0] : Self.projects).path, name = app.name
        HengeLog.log("macapps", "terminal: opening \(name) (\(cols) by \(rows))")
        Task.detached(priority: .userInitiated) {
            var err = [CChar](repeating: 0, count: 512)
            var a: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
            var e: [UnsafePointer<CChar>?] = env.map { UnsafePointer(strdup($0)) } + [nil]
            let rc = henge_tl_term_start(path, &a, &e, dir, Int32(cols), Int32(rows), { bytes, n in
                guard let bytes else { return }
                TerminalSession.shared.output(Array(UnsafeRawBufferPointer(start: bytes, count: n)))
            }, { url in
                guard let url, let u = URL(string: String(cString: url)) else { return }
                DispatchQueue.main.async { TerminalSession.shared.asked = u }
            }, { code in
                HengeLog.log("macapps", "terminal: the program ended with \(code)")
                DispatchQueue.main.async { TerminalSession.shared.status = "Ended (\(code)). Quit Henge to run it again." }
            }, &err, err.count)
            let why = String(cString: err)
            if rc == 0 {
                var folders: [UnsafePointer<CChar>?] = [UnsafePointer(strdup(Self.projects.appendingPathComponent("Toolchain/bin").path)), nil]
                henge_tl_tool_setup(&folders, 3)
            }
            if rc != 0 { HengeLog.log("macapps", "terminal: could not start \(name): \(why)") }
            await MainActor.run {
                self.status = rc == 0 ? "" : "Could not start it: \(why)"
                let (c, r) = self.read { ($0.cols, $0.rows) }
                henge_tl_term_resize(Int32(c), Int32(r))
            }
        }
    }
}

/// Draws the screen and takes the keyboard.
final class TerminalUIView: UIView, UIKeyInput, UITextInputTraits, UIEditMenuInteractionDelegate {
    private let session = TerminalSession.shared
    private var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cell = CGSize(width: 7, height: 15)
    private var offset = 0 // rows scrolled back
    private var panStart = 0
    private var ctrl = false { didSet { ctrlButton?.configuration?.baseForegroundColor = ctrl ? .systemOrange : .white } }
    private weak var ctrlButton: UIButton?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
        contentMode = .redraw
        session.view = self
        setFont(size: CGFloat(UserDefaults.standard.object(forKey: "terminal.fontSize") as? Double ?? 11))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
        addInteraction(menu)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setFont(size: CGFloat) {
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: size, weight: .bold)
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        cell = CGSize(width: w, height: ceil(font.lineHeight * 1.05))
        fit()
    }
    private func fit() {
        guard bounds.width > 40, bounds.height > 40 else { return }
        session.resize(cols: Int((bounds.width - 8) / cell.width), rows: Int(bounds.height / cell.height))
        setNeedsDisplay()
    }
    override func layoutSubviews() { super.layoutSubviews(); fit() }

    func contentChanged() { setNeedsDisplay() }

    // MARK: selecting

    private lazy var menu = UIEditMenuInteraction(delegate: self)
    private typealias Place = (row: Int, col: Int)
    private var selection: (from: Place, to: Place)?
    private var anchor: (from: Place, to: Place)?
    private var heldAt: Place = (0, 0)
    private func firstRow(_ s: TerminalScreen) -> Int { s.scrollback.count - min(offset, s.scrollback.count) }
    private func place(_ p: CGPoint) -> Place {
        session.read { s in
            (min(max(0, firstRow(s) + Int(max(0, p.y) / cell.height)), s.count - 1), min(max(0, Int((p.x - 4) / cell.width)), s.cols - 1))
        }
    }
    /// Hold to select a word; drag to select more. Letting go shows what can be done with it.
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        let at = place(g.location(in: self))
        switch g.state {
        case .began:
            let w = session.read { $0.word(row: at.row, col: at.col) }
            heldAt = at
            anchor = ((at.row, w.from), (at.row, w.to))
            selection = anchor
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard let a = anchor else { return }
            // At the edges it scrolls.
            let y = g.location(in: self).y
            if y < cell.height { offset = min(offset + 1, session.read { $0.scrollback.count }) } else if y > bounds.height - cell.height { offset = max(0, offset - 1) }
            let next: Place = (at.row, at.col + 1)
            func before(_ x: Place, _ y: Place) -> Bool { x.row != y.row ? x.row < y.row : x.col < y.col }
            if before(at, a.from) { selection = (from: at, to: a.to) }
            else { selection = (from: a.from, to: before(a.to, next) ? next : a.to) }
        case .ended:
            if !isFirstResponder { becomeFirstResponder() }
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: self)))
        default: break
        }
        setNeedsDisplay()
    }
    private var selectedText: String { guard let x = selection else { return "" }; return session.read { $0.text(from: x.from, to: x.to) } }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items = [UIMenuElement]()
        let text = selectedText
        if !text.isEmpty { items.append(UIAction(title: "Copy") { [weak self] _ in self?.session.copy(text); self?.deselect() }) }
        if let u = session.read({ $0.link(row: heldAt.row, col: heldAt.col) }) {
            items.append(UIAction(title: "Copy Link") { [weak self] _ in self?.session.copy(u.absoluteString); self?.deselect() })
            items.append(UIAction(title: "Open Link") { [weak self] _ in self?.session.asked = u; self?.deselect() })
        }
        // The system's own Paste asks nothing; Henge's reads the clipboard, which iOS may ask about.
        func command(_ e: UIMenuElement) -> UIMenuElement? {
            if let c = e as? UICommand { return c.action == #selector(paste(_:)) ? c : nil }
            return (e as? UIMenu)?.children.lazy.compactMap(command).first
        }
        items.append(suggestedActions.lazy.compactMap(command).first ?? UIAction(title: "Paste") { [weak self] _ in self?.deselect(); self?.paste() })
        items.append(UIAction(title: "Copy Everything") { [weak self] _ in guard let s = self?.session else { return }; s.copy(s.read { $0.allText }); self?.deselect() })
        return UIMenu(children: items)
    }
    // The system's own Copy and Paste: an external keyboard's, and the three-finger gestures.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs }
        if action == #selector(copy(_:)) { return selection != nil }
        return false
    }
    // From the system's paste key.
    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) } }
    override func paste(itemProviders: [NSItemProvider]) {
        guard let p = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = p.loadObject(ofClass: NSString.self) { [weak self] got, _ in
            guard let t = got as? String else { return }
            DispatchQueue.main.async { self?.offset = 0; self?.deselect(); self?.session.paste(t) }
        }
    }
    override func paste(_ sender: Any?) { deselect(); paste() }
    override func copy(_ sender: Any?) { session.copy(selectedText); deselect() }
    private func deselect() { selection = nil; anchor = nil; setNeedsDisplay() }

    @objc private func tapped() {
        if selection != nil { deselect(); return }
        if !isFirstResponder { becomeFirstResponder() }
    }
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        if g.state == .began { panStart = offset }
        let most = session.read { $0.scrollback.count }
        offset = min(max(0, panStart + Int(g.translation(in: self).y / cell.height)), most)
        setNeedsDisplay()
    }
    private var pinchSize: CGFloat = 11
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchSize = font.pointSize }
        let size = min(max((pinchSize * g.scale).rounded(), 6), 24)
        if size != font.pointSize {
            UserDefaults.standard.set(Double(size), forKey: "terminal.fontSize")
            setFont(size: size)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let back = offset
        let (rows, cx, cy, showCursor) = session.read { s -> ([TerminalScreen.Row], Int, Int, Bool) in
            let k = min(back, s.scrollback.count)
            if k == 0 { return (s.lines, s.cx, s.cy, s.cursorVisible) }
            let all = s.scrollback.suffix(k).prefix(s.rows) + s.lines.prefix(max(0, s.rows - k))
            return (Array(all), 0, 0, false)
        }
        let chosen = selection, firstShown = session.read { firstRow($0) }
        let base = UIColor(white: 0.9, alpha: 1), page = backgroundColor ?? .black
        func color(_ c: UInt32) -> UIColor? {
            guard let v = TerminalScreen.rgb(c) else { return nil }
            return UIColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        for (y, row) in rows.enumerated() {
            let top = CGFloat(y) * cell.height
            var x = 0
            while x < row.count {
                var st = row[x].style
                st.inverse = st.inverse != (showCursor && y == cy && x == cx)
                // A run of plain cells of one style is drawn at once; others one by one, so columns stay in line.
                var end = x + 1
                let simple = row[x].ch.isASCII && !row[x].wide
                if simple {
                    while end < row.count, row[end].style == row[x].style, row[end].ch.isASCII, !row[end].wide, !row[end].tail,
                          !(showCursor && y == cy && (end == cx || x == cx)) { end += 1 }
                } else if row[x].wide, end < row.count { end += 1 }
                var fg = color(st.fg) ?? base, bg = color(st.bg)
                if st.inverse { (fg, bg) = (bg ?? page, fg) }
                if st.dim { fg = fg.withAlphaComponent(0.6) }
                let box = CGRect(x: 4 + CGFloat(x) * cell.width, y: top, width: CGFloat(end - x) * cell.width, height: cell.height)
                if let bg { ctx.setFillColor(bg.cgColor); ctx.fill(box) }
                let text = simple ? String(row[x..<end].map(\.ch)) : String(row[x].ch)
                if text.contains(where: { $0 != " " }) {
                    var a: [NSAttributedString.Key: Any] = [.font: st.bold ? boldFont : font, .foregroundColor: fg]
                    if st.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if st.italic { a[.obliqueness] = 0.15 }
                    (text as NSString).draw(at: box.origin, withAttributes: a)
                }
                x = end
            }
            if let c = chosen {
                let i = firstShown + y
                guard i >= c.from.row, i <= c.to.row else { continue }
                let a = i == c.from.row ? c.from.col : 0, b = i == c.to.row ? c.to.col : row.count
                ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.45).cgColor)
                if b > a { ctx.fill(CGRect(x: 4 + CGFloat(a) * cell.width, y: top, width: CGFloat(b - a) * cell.width, height: cell.height)) }
            }
        }
    }

    // MARK: keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) {
        offset = 0
        if ctrl, let u = text.lowercased().unicodeScalars.first, u.value >= 0x61, u.value <= 0x7a {
            ctrl = false
            session.send(String(UnicodeScalar(UInt8(u.value - 0x60))))
            return
        }
        ctrl = false
        session.send(text.replacingOccurrences(of: "\n", with: "\r"))
    }
    func deleteBackward() { offset = 0; session.send("\u{7f}") }

    private func arrow(_ c: String) { offset = 0; session.send(session.read { $0.appCursor } ? "\u{1b}O\(c)" : "\u{1b}[\(c)") }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses {
            guard let k = p.key else { rest.insert(p); continue }
            switch k.keyCode {
            case .keyboardEscape: session.send("\u{1b}")
            case .keyboardTab: session.send(k.modifierFlags.contains(.shift) ? "\u{1b}[Z" : "\t")
            case .keyboardUpArrow: arrow("A")
            case .keyboardDownArrow: arrow("B")
            case .keyboardRightArrow: arrow("C")
            case .keyboardLeftArrow: arrow("D")
            default:
                if k.modifierFlags.contains(.control), let u = k.charactersIgnoringModifiers.lowercased().unicodeScalars.first, u.value >= 0x61, u.value <= 0x7a {
                    session.send(String(UnicodeScalar(UInt8(u.value - 0x60))))
                } else if k.modifierFlags.contains(.command), k.charactersIgnoringModifiers == "v" { paste() }
                else if k.modifierFlags.contains(.command), k.charactersIgnoringModifiers == "c", selection != nil { session.copy(selectedText); deselect() }
                else { rest.insert(p) }
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    private func paste() { offset = 0; session.pasteClipboard() }

    /// The keys above the keyboard, in a row that scrolls.
    private lazy var keys: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        let scroll = UIScrollView(), row = UIStackView()
        scroll.showsHorizontalScrollIndicator = false
        row.spacing = 6
        func key(_ title: String, _ act: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.gray()
            c.title = title
            c.baseForegroundColor = .white
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
            return UIButton(configuration: c, primaryAction: UIAction { _ in act() })
        }
        let c = key("ctrl") { [weak self] in self?.ctrl.toggle() }
        ctrlButton = c
        let look = UIPasteControl.Configuration()
        look.displayMode = .labelOnly
        look.cornerStyle = .medium
        look.baseBackgroundColor = .systemBlue
        look.baseForegroundColor = .white
        let pasteKey = UIPasteControl(configuration: look)
        pasteKey.target = self
        for k in [pasteKey, key("esc") { [weak self] in self?.session.send("\u{1b}") }, key("tab") { [weak self] in self?.session.send("\t") },
                  key("⇧tab") { [weak self] in self?.session.send("\u{1b}[Z") }, c,
                  key("↑") { [weak self] in self?.arrow("A") }, key("↓") { [weak self] in self?.arrow("B") },
                  key("←") { [weak self] in self?.arrow("D") }, key("→") { [weak self] in self?.arrow("C") },
                  key("hide") { [weak self] in _ = self?.resignFirstResponder() }] { row.addArrangedSubview(k) }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        bar.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor)])
        return bar
    }()
    override var inputAccessoryView: UIView? { keys }
}

private struct TerminalRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalUIView { TerminalUIView(frame: .zero) }
    func updateUIView(_ view: TerminalUIView, context: Context) {}
}

/// The full screen a program's terminal takes.
struct MacTerminalView: View {
    let app: MacApp
    let arguments: String
    @ObservedObject private var session = TerminalSession.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Hide") { dismiss() }
                Spacer()
                Text(!session.said.isEmpty ? session.said : session.status.isEmpty ? app.name : session.status).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer()
                // The system's: iOS refuses an app that reads what another copied by itself.
                PasteButton(payloadType: String.self) { got in
                    DispatchQueue.main.async { if let t = got.first { session.paste(t) } else { session.note("Nothing to paste") } }
                }
                .labelStyle(.titleOnly).buttonBorderShape(.capsule).controlSize(.small).tint(.blue)
                Button { session.copy(session.read { $0.allText }) } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy everything")
                Button { _ = session.view?.becomeFirstResponder() } label: { Image(systemName: "keyboard") }.accessibilityLabel("Keyboard")
            }
            .font(.system(size: 15)).padding(.horizontal, 14).padding(.vertical, 8).background(Color.black)
            TerminalRepresentable()
        }
        .background(Color.black).preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            // Once the view knows its size, so the program starts at it.
            try? await Task.sleep(nanoseconds: 400_000_000)
            session.start(app, arguments: arguments)
        }
        .alert("Open this page?", isPresented: Binding(get: { session.asked != nil }, set: { if !$0 { session.asked = nil } }), presenting: session.asked) { url in
            Button("Open in Safari") { openURL(url) }
            Button("Copy Link") { session.copy(url.absoluteString) }
            Button("Cancel", role: .cancel) {}
        } message: { url in Text("\(app.name) wants to open \(url.host ?? "a page").") }
    }
}

/// The user's GitHub token (Mac Apps > GitHub), in the Keychain.
enum GitHubToken {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "henge.github", kSecAttrAccount as String: "token"]
    static func read() -> String? {
        var q = query, out: CFTypeRef?
        q[kSecReturnData as String] = true
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    @discardableResult static func write(_ s: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        var q = query
        q[kSecValueData as String] = Data(t.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
