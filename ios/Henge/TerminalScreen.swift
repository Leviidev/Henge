import Foundation

/// What a terminal shows: the text a program draws with the usual (xterm) control sequences, kept as rows of cells.
/// No UIKit here, so it can be tested on a Mac (tests/test_terminal.swift).
final class TerminalScreen {
    struct Style: Equatable {
        var fg: UInt32 = 0, bg: UInt32 = 0 // 0: the default; else 0x1RRGGBB, or 0x2000000 | a palette index
        var bold = false, dim = false, italic = false, underline = false, inverse = false
    }
    struct Cell: Equatable {
        var ch: Character = " "
        var style = Style()
        var wide = false, tail = false // a two-column character, and the column it covers
    }
    typealias Row = [Cell]

    private(set) var cols: Int, rows: Int
    private(set) var lines: [Row]
    private(set) var scrollback: [Row] = []
    private(set) var cx = 0, cy = 0
    private(set) var cursorVisible = true, bracketedPaste = false, appCursor = false
    private var style = Style()
    private var top = 0, bottom: Int
    private var wrapNext = false, autowrap = true
    private var saved = (x: 0, y: 0, style: Style())
    private var mainLines: [Row]?
    private var mainSaved = (x: 0, y: 0, style: Style())
    private var pending: [UInt8] = []  // an unfinished UTF-8 character
    private enum State { case text, esc, csi, osc, oscEsc, skip1, dcs, dcsEsc }
    private var state = State.text
    private var params = "", osc: [UInt8] = []
    /// Answers the program asked for (the cursor's place and so on), for its input.
    var reply: (String) -> Void = { _ in }
    static let scrollbackMax = 3000

    init(cols: Int, rows: Int) {
        self.cols = max(cols, 2); self.rows = max(rows, 2)
        bottom = self.rows - 1
        lines = Array(repeating: Array(repeating: Cell(), count: self.cols), count: self.rows)
    }

    func resize(cols c: Int, rows r: Int) {
        let c = max(c, 2), r = max(r, 2)
        guard c != cols || r != rows else { return }
        func fit(_ l: [Row], keep: Bool) -> [Row] {
            var l = l.map { row -> Row in
                var row = row
                if row.count < c { row += Array(repeating: Cell(), count: c - row.count) }
                if row.count > c {
                    row.removeLast(row.count - c)
                    if row[c - 1].wide { row[c - 1] = Cell() }
                }
                return row
            }
            while l.count > r {
                if keep, cy < l.count - 1 { l.removeLast() } else {
                    let first = l.removeFirst()
                    if keep { push(first); cy = max(0, cy - 1) }
                }
            }
            while l.count < r { l.append(Array(repeating: Cell(), count: c)) }
            return l
        }
        lines = fit(lines, keep: mainLines == nil)
        if let m = mainLines { mainLines = fit(m, keep: false) }
        cols = c; rows = r
        top = 0; bottom = r - 1
        cx = min(cx, c - 1); cy = min(cy, r - 1)
        wrapNext = false
    }

    private func push(_ row: Row) {
        scrollback.append(row)
        if scrollback.count > Self.scrollbackMax + 200 { scrollback.removeFirst(scrollback.count - Self.scrollbackMax) }
    }
    private var blank: Cell { var c = Cell(); c.style.bg = style.bg; return c }
    private var blankRow: Row { Array(repeating: blank, count: cols) }

    // MARK: input

    func feed(_ bytes: [UInt8]) { for b in bytes { feed(b) } }

    private func feed(_ b: UInt8) {
        switch state {
        case .text:
            if b < 0x20 || b == 0x7f {
                flushBroken()
                control(b)
            } else if b < 0x80 {
                flushBroken()
                put(Character(UnicodeScalar(b)))
            } else { utf8(b) }
        case .esc: escape(b)
        case .csi:
            if b >= 0x40, b <= 0x7e { state = .text; csi(b) }
            else if b == 0x1b { state = .esc }
            else if b < 0x20 { control(b) }
            else if params.utf8.count < 256 { params.unicodeScalars.append(UnicodeScalar(b)) }
        case .osc:
            if b == 0x07 { state = .text; finishOSC() }
            else if b == 0x1b { state = .oscEsc }
            else if osc.count < 4096 { osc.append(b) }
        case .oscEsc:
            state = .text
            finishOSC()
            if b != 0x5c { state = .esc; escape(b) }
        case .dcs: if b == 0x1b { state = .dcsEsc } else if b == 0x07 { state = .text }
        case .dcsEsc: state = b == 0x5c ? .text : .dcs
        case .skip1: state = .text
        }
    }

    private func flushBroken() { if !pending.isEmpty { pending = []; put("\u{fffd}") } }

    private func utf8(_ b: UInt8) {
        if b >= 0xc0 { flushBroken() }
        pending.append(b)
        let lead = pending[0]
        let need = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1
        if need == 1 { pending = []; put("\u{fffd}"); return }
        guard pending.count >= need else { return }
        let s = String(decoding: pending, as: UTF8.self)
        pending = []
        for scalar in s.unicodeScalars { putScalar(scalar) }
    }

    private func putScalar(_ u: UnicodeScalar) {
        let v = u.value
        let joins = v == 0x200d || (v >= 0xfe00 && v <= 0xfe0f) || (v >= 0x1f3fb && v <= 0x1f3ff) ||
            u.properties.generalCategory == .nonspacingMark || u.properties.generalCategory == .enclosingMark
        if joins {
            // It belongs to the character before it.
            var x = wrapNext ? cx : cx - 1
            if x >= 0, lines[cy][x].tail { x -= 1 }
            guard x >= 0 else { return }
            var s = String(lines[cy][x].ch)
            s.unicodeScalars.append(u)
            if s.count == 1, let c = s.first { lines[cy][x].ch = c }
            return
        }
        put(Character(u), wide: Self.isWide(v))
    }

    static func isWide(_ v: UInt32) -> Bool {
        (v >= 0x1100 && v <= 0x115f) || (v >= 0x2e80 && v <= 0x303e) || (v >= 0x3041 && v <= 0x33ff) || (v >= 0x3400 && v <= 0x4dbf) ||
            (v >= 0x4e00 && v <= 0x9fff) || (v >= 0xa000 && v <= 0xa4cf) || (v >= 0xac00 && v <= 0xd7a3) || (v >= 0xf900 && v <= 0xfaff) ||
            (v >= 0xfe30 && v <= 0xfe6f) || (v >= 0xff00 && v <= 0xff60) || (v >= 0xffe0 && v <= 0xffe6) ||
            (v >= 0x1f300 && v <= 0x1f64f) || (v >= 0x1f680 && v <= 0x1f6ff) || (v >= 0x1f900 && v <= 0x1f9ff) ||
            (v >= 0x1fa70 && v <= 0x1faff) || (v >= 0x20000 && v <= 0x3fffd)
    }

    private func put(_ ch: Character, wide: Bool = false) {
        if wrapNext || (wide && cx == cols - 1) {
            if autowrap { cx = 0; newline() }
            wrapNext = false
        }
        clearHalf(cx)
        lines[cy][cx] = Cell(ch: ch, style: style, wide: wide)
        if wide, cx + 1 < cols {
            clearHalf(cx + 1)
            lines[cy][cx + 1] = Cell(ch: " ", style: style, wide: false, tail: true)
        }
        let next = cx + (wide ? 2 : 1)
        if next >= cols { cx = cols - 1; wrapNext = true } else { cx = next }
    }
    /// Half of a two-column character is being drawn over: the other half goes.
    private func clearHalf(_ x: Int) {
        if lines[cy][x].tail, x > 0 { lines[cy][x - 1] = Cell() }
        if lines[cy][x].wide, x + 1 < cols { lines[cy][x + 1] = Cell() }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x08: cx = max(0, cx - 1); wrapNext = false
        case 0x09: cx = min(cols - 1, (cx / 8 + 1) * 8); wrapNext = false
        case 0x0a, 0x0b, 0x0c: newline(); wrapNext = false
        case 0x0d: cx = 0; wrapNext = false
        case 0x1b: state = .esc
        default: break
        }
    }

    private func newline() { if cy == bottom { scrollUp(1) } else if cy < rows - 1 { cy += 1 } }
    private func scrollUp(_ n: Int) {
        for _ in 0..<min(max(n, 0), bottom - top + 1) {
            let gone = lines.remove(at: top)
            if top == 0, mainLines == nil { push(gone) }
            lines.insert(blankRow, at: bottom)
        }
    }
    private func scrollDown(_ n: Int) {
        for _ in 0..<min(max(n, 0), bottom - top + 1) {
            lines.remove(at: bottom)
            lines.insert(blankRow, at: top)
        }
    }

    private func escape(_ b: UInt8) {
        state = .text
        switch b {
        case 0x5b: params = ""; state = .csi            // [
        case 0x5d: osc = []; state = .osc               // ]
        case 0x50, 0x58, 0x5e, 0x5f: state = .dcs       // P X ^ _
        case 0x28, 0x29, 0x2a, 0x2b, 0x23, 0x20: state = .skip1
        case 0x37: saved = (cx, cy, style)
        case 0x38: cx = min(saved.x, cols - 1); cy = min(saved.y, rows - 1); style = saved.style; wrapNext = false
        case 0x44: newline()
        case 0x45: cx = 0; newline()
        case 0x4d: if cy == top { scrollDown(1) } else { cy = max(0, cy - 1) }
        case 0x63: reset()
        case 0x1b: state = .esc
        default: break
        }
    }

    private func reset() {
        style = Style(); top = 0; bottom = rows - 1; cx = 0; cy = 0; wrapNext = false; mainLines = nil
        cursorVisible = true; bracketedPaste = false; appCursor = false; autowrap = true
        lines = Array(repeating: blankRow, count: rows)
    }

    private func finishOSC() {
        let s = String(decoding: osc, as: UTF8.self)
        osc = []
        if s == "11;?" { reply("\u{1b}]11;rgb:1010/1010/1212\u{1b}\\") }
        if s == "10;?" { reply("\u{1b}]10;rgb:e6e6/e6e6/e6e6\u{1b}\\") }
    }

    private func csi(_ final: UInt8) {
        var prefix: Character?
        var text = params
        if let f = text.first, "?><=".contains(f) { prefix = f; text.removeFirst() }
        // Intermediate characters ("$", " ", "!", ...) make it a different sequence.
        let inter = text.unicodeScalars.contains { $0.value >= 0x20 && $0.value <= 0x2f }
        let p = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        func n(_ i: Int, _ d: Int = 1) -> Int { i < p.count && p[i] > 0 ? min(p[i], 10000) : d }
        let f = Character(UnicodeScalar(final))
        if inter { return }
        if prefix == "?" {
            switch f {
            case "h": for m in p { mode(m, true) }
            case "l": for m in p { mode(m, false) }
            case "n" where n(0, 0) == 6: reply("\u{1b}[?\(cy + 1);\(cx + 1)R")
            default: break
            }
            return
        }
        if prefix != nil {
            if prefix == ">", f == "c" { reply("\u{1b}[>0;10;1c") }
            return
        }
        if f != "m" { wrapNext = false }
        switch f {
        case "A": cy = max(cy >= top ? top : 0, cy - n(0))
        case "B", "e": cy = min(cy <= bottom ? bottom : rows - 1, cy + n(0))
        case "C", "a": cx = min(cols - 1, cx + n(0))
        case "D": cx = max(0, cx - n(0))
        case "E": cx = 0; cy = min(rows - 1, cy + n(0))
        case "F": cx = 0; cy = max(0, cy - n(0))
        case "G", "`": cx = min(cols, n(0)) - 1
        case "d": cy = min(rows, n(0)) - 1
        case "H", "f": cy = min(rows, n(0)) - 1; cx = min(cols, n(1)) - 1
        case "J":
            switch n(0, 0) {
            case 0: erase(cy, cx, cols); for y in (cy + 1)..<max(rows, cy + 1) { lines[y] = blankRow }
            case 1: for y in 0..<cy { lines[y] = blankRow }; erase(cy, 0, cx + 1)
            case 2: for y in 0..<rows { lines[y] = blankRow }
            case 3: scrollback = []
            default: break
            }
        case "K":
            switch n(0, 0) {
            case 0: erase(cy, cx, cols)
            case 1: erase(cy, 0, cx + 1)
            default: erase(cy, 0, cols)
            }
        case "L": if cy >= top, cy <= bottom { for _ in 0..<min(n(0), bottom - cy + 1) { lines.remove(at: bottom); lines.insert(blankRow, at: cy) } }
        case "M": if cy >= top, cy <= bottom { for _ in 0..<min(n(0), bottom - cy + 1) { lines.remove(at: cy); lines.insert(blankRow, at: bottom) } }
        case "P":
            let k = min(n(0), cols - cx)
            lines[cy].removeSubrange(cx..<cx + k)
            lines[cy] += Array(repeating: blank, count: k)
        case "@":
            let k = min(n(0), cols - cx)
            lines[cy].insert(contentsOf: Array(repeating: blank, count: k), at: cx)
            lines[cy].removeLast(k)
        case "X": erase(cy, cx, min(cols, cx + n(0)))
        case "S": scrollUp(n(0))
        case "T": scrollDown(n(0))
        case "r":
            let a = n(0) - 1, z = min(n(1, rows), rows) - 1
            if a < z { top = a; bottom = z } else { top = 0; bottom = rows - 1 }
            cx = 0; cy = 0
        case "s": saved = (cx, cy, style)
        case "u": cx = min(saved.x, cols - 1); cy = min(saved.y, rows - 1)
        case "m": sgr(text)
        case "n": if n(0, 0) == 6 { reply("\u{1b}[\(cy + 1);\(cx + 1)R") } else if n(0, 0) == 5 { reply("\u{1b}[0n") }
        case "c": reply("\u{1b}[?62;22c")
        default: break
        }
    }

    private func erase(_ y: Int, _ from: Int, _ to: Int) {
        guard from < to else { return }
        let b = blank
        for x in from..<to { lines[y][x] = b }
    }

    private func mode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: appCursor = on
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 2004: bracketedPaste = on
        case 47, 1047, 1049:
            if on, mainLines == nil {
                mainSaved = (cx, cy, style)
                mainLines = lines
                lines = Array(repeating: blankRow, count: rows)
            } else if !on, let m = mainLines {
                lines = m
                mainLines = nil
                cx = min(mainSaved.x, cols - 1); cy = min(mainSaved.y, rows - 1); style = mainSaved.style
            }
            top = 0; bottom = rows - 1
        default: break
        }
    }

    private func sgr(_ text: String) {
        // "38:2::r:g:b" and "38;2;r;g;b" both occur.
        var p: [Int] = []
        for part in text.split(separator: ";", omittingEmptySubsequences: false) {
            let sub = part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? -1 }
            if sub.count > 1, sub[0] == 38 || sub[0] == 48 {
                let v = sub.filter { $0 >= 0 }
                p += v
            } else if sub.count > 1, sub[0] == 4 { p.append(sub[1] == 0 ? 24 : 4) }
            else { p.append(max(sub.first ?? 0, 0)) }
        }
        if p.isEmpty { p = [0] }
        var i = 0
        func color() -> UInt32? {
            guard i + 1 < p.count else { return nil }
            if p[i + 1] == 5, i + 2 < p.count { let c = p[i + 2]; i += 2; return 0x2000000 | UInt32(min(max(c, 0), 255)) }
            if p[i + 1] == 2, i + 4 < p.count {
                let r = UInt32(min(p[i + 2], 255)), g = UInt32(min(p[i + 3], 255)), b = UInt32(min(p[i + 4], 255))
                i += 4
                return 0x1000000 | r << 16 | g << 8 | b
            }
            return nil
        }
        while i < p.count {
            switch p[i] {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.fg = 0x2000000 | UInt32(p[i] - 30)
            case 38: if let c = color() { style.fg = c }
            case 39: style.fg = 0
            case 40...47: style.bg = 0x2000000 | UInt32(p[i] - 40)
            case 48: if let c = color() { style.bg = c }
            case 49: style.bg = 0
            case 90...97: style.fg = 0x2000000 | UInt32(p[i] - 90 + 8)
            case 100...107: style.bg = 0x2000000 | UInt32(p[i] - 100 + 8)
            default: break
            }
            i += 1
        }
    }

    // MARK: reading it

    static func text(_ row: Row) -> String {
        var s = ""
        for c in row where !c.tail { s.append(c.ch) }
        while s.last == " " { s.removeLast() }
        return s
    }
    var allText: String { (scrollback + lines).map(Self.text).joined(separator: "\n").trimmingCharacters(in: .newlines) }

    /// 0xRRGGBB for a colour of a cell, or nil for the default.
    static func rgb(_ c: UInt32) -> UInt32? {
        if c == 0 { return nil }
        if c & 0x1000000 != 0 { return c & 0xffffff }
        let i = Int(c & 0xff)
        let base: [UInt32] = [0x1c1c1e, 0xe0554f, 0x57b25f, 0xd0a343, 0x4f8fe0, 0xb86bd6, 0x45b3bd, 0xc9c9ce,
                              0x7a7a80, 0xff7b72, 0x7ee787, 0xf2cc60, 0x79b8ff, 0xd2a8ff, 0x76e3ea, 0xffffff]
        if i < 16 { return base[i] }
        if i >= 232 { let v = UInt32(8 + (i - 232) * 10); return v << 16 | v << 8 | v }
        let k = i - 16
        func l(_ n: Int) -> UInt32 { n == 0 ? 0 : UInt32(55 + n * 40) }
        return l(k / 36) << 16 | l(k / 6 % 6) << 8 | l(k % 6)
    }
}
