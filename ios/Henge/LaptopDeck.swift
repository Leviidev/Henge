import SwiftUI

/// The half below the fold in the laptop layout (DuoPosture.swift): a bar, then either one big
/// trackpad under a row of the Mac's keys, or a full Mac keyboard over a small trackpad. Keys go to
/// the Mac's USB keyboard by HID usage, as a hardware keyboard's do (HardwareKeys); ⌃ ⌥ ⌘ ⇧ latch
/// until the next key or click (StickyKeys). Keycaps are verbatim, as on a Mac's keyboard.
struct LaptopDeck: View {
    enum Mode: String { case trackpad, keyboard }

    @AppStorage("henge.duo.deck") private var mode = Mode.trackpad
    @AppStorage("henge.duo.fnRow") private var fnRow = true
    let zoomed: Bool
    /// Hidden controls: the whole half is a trackpad, and four fingers bring the rest back.
    let hidden: Bool
    let toggleZoom: () -> Void
    let showDetails: () -> Void
    let hideControls: () -> Void
    let shutDown: () -> Void

    var body: some View {
        if hidden {
            pad(hint: "Tap with four fingers to show the controls")
        } else {
            VStack(spacing: 7) {
                bar
                switch mode {
                case .trackpad:
                    KeyStrip(showKeyboard: { mode = .keyboard })
                    pad(hint: "Drag to point · tap to click · hold, then drag\nTwo fingers scroll · three swipe between Spaces")
                    HStack(spacing: 6) {
                        DeckMouseButton(title: "Click", button: 0)
                        DeckMouseButton(title: "Right-click", button: 1)
                    }
                    .frame(height: 46)
                case .keyboard:
                    FullKeyboard(fnRow: fnRow)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        pad(hint: "Drag · tap · two fingers").frame(maxWidth: 380)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                segment(.trackpad, "rectangle.split.1x2", "Trackpad")
                segment(.keyboard, "keyboard", "Keyboard")
            }
            .padding(3)
            .background(Deck.control, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Spacer(minLength: 0)
            PasteButton(payloadType: String.self) { texts in
                if let text = texts.first { Sharing.paste(text) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: 13))
            .tint(Deck.control)
            barButton(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "Zoom out" : "Zoom in",
                      tint: zoomed ? Deck.accent : Deck.text, action: toggleZoom)
            barButton("info.circle", "Details", action: showDetails)
            barButton("eye.slash", "Hide controls", action: hideControls)
            barButton("power", "Shut down", tint: Desk.bad, action: shutDown)
        }
        .frame(height: 44)
    }

    private func segment(_ which: Mode, _ symbol: String, _ title: LocalizedStringKey) -> some View {
        let on = mode == which
        return Button { mode = which } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Deck.accent : Deck.label)
                .padding(.horizontal, 11)
                .frame(maxHeight: .infinity)
                .background(on ? Deck.controlOpen : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func barButton(_ symbol: String, _ label: LocalizedStringKey, tint: Color = Deck.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 50, height: 44)
                .background(Deck.control, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func pad(hint: String) -> some View {
        ZStack {
            Deck.well
            Text(hint)
                .font(.system(size: 14))
                .foregroundStyle(Deck.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .allowsHitTesting(false)
            Trackpad()
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.04), lineWidth: 1))
    }
}

/// The deck's colours: dark, like the session around it.
enum Deck {
    static let control = Color(red: 0x23 / 255, green: 0x26 / 255, blue: 0x2C / 255)
    static let controlOpen = Color(red: 0x2C / 255, green: 0x35 / 255, blue: 0x50 / 255)
    static let pressed = Color(red: 0x3A / 255, green: 0x3F / 255, blue: 0x4A / 255)
    static let accent = Color(red: 0x9B / 255, green: 0xB7 / 255, blue: 0xFF / 255)
    static let text = Color(red: 0xEE / 255, green: 0xF0 / 255, blue: 0xF3 / 255)
    static let label = Color(red: 0xC4 / 255, green: 0xC9 / 255, blue: 0xD1 / 255)
    static let muted = Color(red: 0xA4 / 255, green: 0xAB / 255, blue: 0xB5 / 255)
    static let well = Color(red: 0x10 / 255, green: 0x12 / 255, blue: 0x15 / 255)
}

// MARK: - Keys

/// One key of the deck, as data: what it shows and what it sends.
struct DeckKey {
    enum Kind: Equatable {
        /// Down while touched, by HID usage. `fn` is what it sends with fn latched, if anything else.
        case key(usage: UInt8, fn: UInt8? = nil)
        /// Latched until the next key or click (StickyKeys, by Linux key code).
        case modifier(linux: UInt16)
        case capsLock
        case fn
        /// ⌘Space, whatever is latched.
        case spotlight
        /// Shows the full keyboard (the trackpad's key strip).
        case showKeyboard
    }

    var label: String
    var shifted: String? = nil
    var symbol: String? = nil
    var kind: Kind
    /// Width in keys.
    var width: CGFloat = 1
    var align: Alignment = .center
    var small = false
}

/// Usages for the keys the deck names (USB HID keyboard page; host/xhci.c takes them as they are).
enum HID {
    static let escape: UInt8 = 0x29, tab: UInt8 = 0x2B, backspace: UInt8 = 0x2A, returnKey: UInt8 = 0x28
    static let space: UInt8 = 0x2C, capsLock: UInt8 = 0x39, forwardDelete: UInt8 = 0x4C
    static let right: UInt8 = 0x4F, left: UInt8 = 0x50, down: UInt8 = 0x51, up: UInt8 = 0x52
    static let home: UInt8 = 0x4A, pageUp: UInt8 = 0x4B, end: UInt8 = 0x4D, pageDown: UInt8 = 0x4E
    static let command: UInt8 = 0xE3
    static func f(_ n: Int) -> UInt8 { UInt8(0x3A + n - 1) }
    static func letter(_ c: Character) -> UInt8 { UInt8(0x04 + Int(c.asciiValue! - 0x61)) }
}

/// What the deck's keys share: fn and caps lock (the Mac keeps its own caps lock; this only lights the key).
final class DeckKeys: ObservableObject {
    static let shared = DeckKeys()
    @Published var fn = false
    @Published var capsLock = false
    private let buzz = UIImpactFeedbackGenerator(style: .light)

    func down(_ key: DeckKey) -> UInt8? {
        buzz.impactOccurred()
        switch key.kind {
        case .key(let usage, let alternate):
            let sent = fn ? (alternate ?? usage) : usage
            henge_vm_key_hid(sent, 1)
            return sent
        case .modifier(let code):
            StickyKeys.shared.toggle(code)
        case .capsLock:
            henge_vm_key_hid(HID.capsLock, 1)
            henge_vm_key_hid(HID.capsLock, 0)
            capsLock.toggle()
        case .fn:
            fn.toggle()
        case .spotlight:
            henge_vm_key_hid(HID.command, 1)
            henge_vm_key_hid(HID.space, 1)
            henge_vm_key_hid(HID.space, 0)
            henge_vm_key_hid(HID.command, 0)
            spend()
        case .showKeyboard:
            break
        }
        return nil
    }

    /// The key a touch put down comes up, and what was latched for it is spent.
    func up(_ sent: UInt8) {
        henge_vm_key_hid(sent, 0)
        spend()
    }

    func spend() {
        StickyKeys.shared.releaseAll()
        fn = false
    }
}

/// A keycap: goes down when touched and up when let go, so the Mac repeats a held key itself.
private struct Keycap: View {
    let key: DeckKey
    var radius: CGFloat = 10
    var action: (() -> Void)? = nil
    @ObservedObject private var sticky = StickyKeys.shared
    @ObservedObject private var keys = DeckKeys.shared
    @State private var sent: UInt8?
    @State private var touching = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: key.align)
            .padding(.horizontal, key.align == .center ? 0 : 9)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !touching else { return }
                        touching = true
                        if let action { action(); return }
                        sent = keys.down(key)
                    }
                    .onEnded { _ in
                        touching = false
                        if let sent { keys.up(sent) }
                        sent = nil
                    }
            )
            .onDisappear { // gone with a finger still on it: no release comes
                if let sent { keys.up(sent) }
                sent = nil
                touching = false
            }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: key.label))
            .accessibilityAddTraits(.isButton)
    }

    private var lit: Bool {
        switch key.kind {
        case .modifier(let code): return sticky.down.contains(code)
        case .fn: return keys.fn
        default: return false
        }
    }

    private var fill: Color { touching ? Deck.pressed : lit ? Deck.controlOpen : Deck.control }
    private var ink: Color { lit ? Deck.accent : Deck.text }

    @ViewBuilder private var content: some View {
        if let symbol = key.symbol {
            Image(systemName: symbol).font(.system(size: key.small ? 12 : 15, weight: .medium)).foregroundStyle(ink)
        } else if case .capsLock = key.kind {
            HStack(spacing: 6) {
                Circle().fill(keys.capsLock ? Desk.good : Color.white.opacity(0.2)).frame(width: 5, height: 5)
                Text(verbatim: key.label).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        } else if let shifted = key.shifted {
            VStack(spacing: 1) {
                Text(verbatim: shifted).font(.system(size: 10)).foregroundStyle(Deck.muted)
                Text(verbatim: key.label).font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
            }
        } else {
            Text(verbatim: key.label)
                .font(.system(size: key.small ? 11 : 15, weight: key.small ? .medium : .regular))
                .foregroundStyle(key.small ? (lit ? Deck.accent : Deck.label) : ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Keys in a row, each as wide as its share of the row (a 1.5 key half again a 1), as on a keyboard.
private struct KeyRowLayout: Layout {
    let widths: [CGFloat]
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let total = widths.reduce(0, +)
        let unit = (bounds.width - gap * CGFloat(max(subviews.count - 1, 0))) / max(total, 1)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            let w = unit * width
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + gap
        }
    }
}

/// The key row over the big trackpad: escape, tab, the four modifiers, the arrows, the keyboard
/// and Spotlight.
private struct KeyStrip: View {
    let showKeyboard: () -> Void

    var body: some View {
        let keys: [DeckKey] = [
            DeckKey(label: "esc", kind: .key(usage: HID.escape), small: true),
            DeckKey(label: "tab", kind: .key(usage: HID.tab), small: true),
            DeckKey(label: "ctrl", kind: .modifier(linux: Keys.control), small: true),
            DeckKey(label: "opt", kind: .modifier(linux: Keys.option), small: true),
            DeckKey(label: "cmd", kind: .modifier(linux: Keys.command), small: true),
            DeckKey(label: "shift", kind: .modifier(linux: Keys.shift), small: true),
            DeckKey(label: "←", symbol: "chevron.left", kind: .key(usage: HID.left)),
            DeckKey(label: "↓", symbol: "chevron.down", kind: .key(usage: HID.down)),
            DeckKey(label: "↑", symbol: "chevron.up", kind: .key(usage: HID.up)),
            DeckKey(label: "→", symbol: "chevron.right", kind: .key(usage: HID.right)),
            DeckKey(label: "keyboard", symbol: "keyboard", kind: .showKeyboard),
            DeckKey(label: "Spotlight", symbol: "magnifyingglass", kind: .spotlight),
        ]
        KeyRowLayout(widths: keys.map(\.width), gap: 6) {
            ForEach(keys.indices, id: \.self) { i in
                Keycap(key: keys[i], radius: 11, action: keys[i].kind == .showKeyboard ? showKeyboard : nil)
            }
        }
        .frame(height: 44)
    }
}

/// A Mac's ANSI keyboard: the optional escape and function row, five rows, and the arrows in an
/// inverted T. Holding fn makes the digits F1–F12, the arrows Home, End, Page Up and Page Down, and
/// delete forward delete (the Mac's USB keyboard has no fn key of its own).
private struct FullKeyboard: View {
    let fnRow: Bool

    private static func letters(_ s: String) -> [DeckKey] {
        s.map { DeckKey(label: String($0).uppercased(), kind: .key(usage: HID.letter($0))) }
    }

    private static func symbol(_ plain: String, _ shifted: String, _ usage: UInt8, fn: UInt8? = nil) -> DeckKey {
        DeckKey(label: plain, shifted: shifted, kind: .key(usage: usage, fn: fn))
    }

    private static let functionRow: [DeckKey] =
        [DeckKey(label: "esc", kind: .key(usage: HID.escape), width: 1.5, align: .leading, small: true)]
        + (1...12).map { DeckKey(label: "F\($0)", kind: .key(usage: HID.f($0)), small: true) }
        + [DeckKey(label: "Spotlight", symbol: "magnifyingglass", kind: .spotlight, small: true)]

    private static let rows: [[DeckKey]] = [
        [symbol("`", "~", 0x35)]
            + zip("1234567890", "!@#$%^&*()").enumerated().map { i, pair in
                symbol(String(pair.0), String(pair.1), i == 9 ? 0x27 : UInt8(0x1E + i), fn: HID.f(i + 1))
            }
            + [symbol("-", "_", 0x2D, fn: HID.f(11)), symbol("=", "+", 0x2E, fn: HID.f(12)),
               DeckKey(label: "delete", kind: .key(usage: HID.backspace, fn: HID.forwardDelete), width: 1.5, align: .trailing, small: true)],
        [DeckKey(label: "tab", kind: .key(usage: HID.tab), width: 1.5, align: .leading, small: true)]
            + letters("qwertyuiop")
            + [symbol("[", "{", 0x2F), symbol("]", "}", 0x30), symbol("\\", "|", 0x31)],
        [DeckKey(label: "caps lock", kind: .capsLock, width: 1.75, align: .leading, small: true)]
            + letters("asdfghjkl")
            + [symbol(";", ":", 0x33), symbol("'", "\"", 0x34),
               DeckKey(label: "return", kind: .key(usage: HID.returnKey), width: 1.75, align: .trailing, small: true)],
        [DeckKey(label: "shift", kind: .modifier(linux: Keys.shift), width: 2.25, align: .leading, small: true)]
            + letters("zxcvbnm")
            + [symbol(",", "<", 0x36), symbol(".", ">", 0x37), symbol("/", "?", 0x38),
               DeckKey(label: "shift", kind: .modifier(linux: Keys.shift), width: 2.25, align: .trailing, small: true)],
    ]

    private static let bottomRow: [DeckKey] = [
        DeckKey(label: "fn", kind: .fn, align: .leading, small: true),
        DeckKey(label: "⌃ control", symbol: "control", kind: .modifier(linux: Keys.control), small: true),
        DeckKey(label: "⌥ option", symbol: "option", kind: .modifier(linux: Keys.option), small: true),
        DeckKey(label: "⌘ command", symbol: "command", kind: .modifier(linux: Keys.command), width: 1.25, small: true),
        DeckKey(label: "space", kind: .key(usage: HID.space), width: 5),
        DeckKey(label: "⌘ command", symbol: "command", kind: .modifier(linux: Keys.command), width: 1.25, small: true),
        DeckKey(label: "⌥ option", symbol: "option", kind: .modifier(linux: Keys.option), small: true),
    ]

    var body: some View {
        VStack(spacing: 7) {
            if fnRow { row(Self.functionRow).frame(height: 27) }
            ForEach(Self.rows.indices, id: \.self) { i in row(Self.rows[i]).frame(height: 37) }
            KeyRowLayout(widths: Self.bottomRow.map(\.width) + [3], gap: 6) {
                ForEach(Self.bottomRow.indices, id: \.self) { i in Keycap(key: Self.bottomRow[i]) }
                arrows
            }
            .frame(height: 37)
        }
    }

    private func row(_ keys: [DeckKey]) -> some View {
        KeyRowLayout(widths: keys.map(\.width), gap: 6) {
            ForEach(keys.indices, id: \.self) { i in Keycap(key: keys[i]) }
        }
    }

    /// ← and →, with ↑ over ↓ between them, half height.
    private var arrows: some View {
        HStack(spacing: 6) {
            Keycap(key: DeckKey(label: "←", symbol: "arrowtriangle.left.fill", kind: .key(usage: HID.left, fn: HID.home), small: true), radius: 7)
            VStack(spacing: 3) {
                Keycap(key: DeckKey(label: "↑", symbol: "arrowtriangle.up.fill", kind: .key(usage: HID.up, fn: HID.pageUp), small: true), radius: 7)
                Keycap(key: DeckKey(label: "↓", symbol: "arrowtriangle.down.fill", kind: .key(usage: HID.down, fn: HID.pageDown), small: true), radius: 7)
            }
            Keycap(key: DeckKey(label: "→", symbol: "arrowtriangle.right.fill", kind: .key(usage: HID.right, fn: HID.end), small: true), radius: 7)
        }
    }
}

/// A mouse button as a cap: down when touched, up when let go.
private struct DeckMouseButton: View {
    let title: LocalizedStringKey
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Deck.label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Deck.pressed : Deck.control, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        DeckKeys.shared.spend()
                    }
            )
            .accessibilityAddTraits(.isButton)
    }
}
