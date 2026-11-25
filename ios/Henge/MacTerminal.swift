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
    func paste(_ s: String) {
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
        var env = ["HOME=\(Self.home.path)", "PWD=\(Self.projects.path)", "TMPDIR=\(tmp)", "TERM=xterm-256color", "COLORTERM=truecolor",
                   "LANG=en_US.UTF-8", "SHELL=/bin/sh", "PATH=/usr/bin:/bin", "USER=mobile"]
        env += ["BUN_JSC_useJIT=0", "BUN_OPTIONS=--preload=\(pre.path)", "CLAUDE_CODE_TMPDIR=\(tmp)", "DISABLE_AUTOUPDATER=1"]
        let args = arguments.split(separator: " ").map(String.init)
        let (cols, rows) = read { ($0.cols, $0.rows) }
        let path = app.executable, dir = Self.projects.path, name = app.name
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
final class TerminalUIView: UIView, UIKeyInput, UITextInputTraits {
    private let session = TerminalSession.shared
    private var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cell = CGSize(width: 7, height: 15)
    private var offset = 0 // rows scrolled back
    private var panStart = 0
    private var ctrl = false { didSet { ctrlButton?.tintColor = ctrl ? .systemOrange : nil } }
    private weak var ctrlButton: UIBarButtonItem?

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

    @objc private func tapped() { if !isFirstResponder { becomeFirstResponder() } }
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
                else { rest.insert(p) }
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    private func paste() { if let s = UIPasteboard.general.string { session.paste(s) } }

    private lazy var keys: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.barStyle = .black
        func key(_ title: String, _ act: @escaping () -> Void) -> UIBarButtonItem {
            UIBarButtonItem(title: title, primaryAction: UIAction(title: title) { _ in act() })
        }
        let c = key("ctrl") { [weak self] in self?.ctrl.toggle() }
        ctrlButton = c
        let items = [key("esc") { [weak self] in self?.session.send("\u{1b}") }, key("tab") { [weak self] in self?.session.send("\t") },
                     key("⇧tab") { [weak self] in self?.session.send("\u{1b}[Z") }, c,
                     key("←") { [weak self] in self?.arrow("D") }, key("↓") { [weak self] in self?.arrow("B") },
                     key("↑") { [weak self] in self?.arrow("A") }, key("→") { [weak self] in self?.arrow("C") },
                     key("paste") { [weak self] in self?.paste() }, key("⌄") { [weak self] in self?.resignFirstResponder() }]
        bar.items = Array(items.map { [$0] }.joined(separator: [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)]))
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
                Text(session.status.isEmpty ? app.name : session.status).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Spacer()
                Button { UIPasteboard.general.string = session.read { $0.allText } } label: { Image(systemName: "doc.on.doc") }
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
            Button("Copy Link") { UIPasteboard.general.string = url.absoluteString }
            Button("Cancel", role: .cancel) {}
        } message: { url in Text("\(app.name) wants to open \(url.host ?? "a page").") }
    }
}
