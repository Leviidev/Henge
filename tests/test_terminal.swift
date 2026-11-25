// The terminal screen (ios/Henge/TerminalScreen.swift) on the Mac: swiftc it with this file.
// test_terminal: its checks. test_terminal FILE COLS ROWS: what the bytes in FILE leave on the screen.
import Foundation
@main struct Main {
    static func main() throws {
        let a = CommandLine.arguments
        if a.count == 4 {
            let s = TerminalScreen(cols: Int(a[2])!, rows: Int(a[3])!)
            s.feed([UInt8](try Data(contentsOf: URL(fileURLWithPath: a[1]))))
            for l in s.lines { print("|" + TerminalScreen.text(l)) }
            return
        }
        var bad = 0
        func check(_ what: String, _ input: String, _ want: [String], cols: Int = 10, rows: Int = 3) {
            let s = TerminalScreen(cols: cols, rows: rows)
            s.feed([UInt8](input.utf8))
            let got = s.lines.map(TerminalScreen.text)
            if got != want { bad += 1; print("FAIL \(what): \(got) not \(want)") }
        }
        check("text", "ab\r\ncd", ["ab", "cd", ""])
        check("wrap", "abcdefghijkl", ["abcdefghij", "kl", ""])
        check("wrap waits", "abcdefghij\r\nx", ["abcdefghij", "x", ""])
        check("scroll", "1\r\n2\r\n3\r\n4", ["2", "3", "4"])
        check("move and erase", "hello\u{1b}[1;3H\u{1b}[K", ["he", "", ""])
        check("up", "a\r\nb\u{1b}[1A\u{1b}[1GX", ["X", "b", ""])
        check("wide", "\u{4f60}\u{597d}!", ["\u{4f60}\u{597d}!", "", ""])
        check("wide overwritten", "\u{4f60}x\u{1b}[1;2Hy", [" yx", "", ""])
        check("osc", "\u{1b}]0;title\u{07}ok", ["ok", "", ""])
        check("osc link", "\u{1b}]8;;https://x\u{1b}\\ok\u{1b}]8;;\u{1b}\\", ["ok", "", ""])
        check("alt screen", "m\u{1b}[?1049h\u{1b}[Halt\u{1b}[?1049l", ["m", "", ""])
        check("region", "1\r\n2\r\n3\u{1b}[1;2r\u{1b}[2;1H\nx", ["2", "x", "3"])
        check("insert, delete", "abcd\u{1b}[1;2H\u{1b}[1@\u{1b}[1;4H\u{1b}[1P", ["a bd", "", ""])
        check("colours", "\u{1b}[38;2;1;2;3ma\u{1b}[48:5:200mb\u{1b}[0m", ["ab", "", ""])
        check("huge counts", "\u{1b}[99999999C\u{1b}[99999999Ax\u{1b}[99999L\u{1b}[9999S", ["", "", ""])
        check("erase below at the last row", "\u{1b}[3;1Hx\u{1b}[J", ["", "", "x"])
        check("erase above", "a\r\nb\r\nc\u{1b}[2;1H\u{1b}[1J", ["", "", "c"])
        let s = TerminalScreen(cols: 10, rows: 4)
        s.feed([UInt8]("1\r\n2\r\n3\r\n4\r\n5".utf8))
        s.resize(cols: 6, rows: 2); s.resize(cols: 20, rows: 6); s.feed([UInt8]("z".utf8))
        if !s.allText.contains("5z") { bad += 1; print("FAIL resize: \(s.allText)") }
        var r = SystemRandomNumberGenerator()
        let f = TerminalScreen(cols: 17, rows: 5)
        let alphabet = Array("\u{1b}[];?0123456789:;ABCDEFGHJKLMPSTX@drsumhlc\r\n\u{08}\tx\u{4f60}\u{1f600}\u{fe0f}$ >78".utf8)
        for i in 0..<400_000 {
            f.feed([alphabet[Int.random(in: 0..<alphabet.count, using: &r)]])
            if i % 5000 == 0 { f.resize(cols: Int.random(in: 1...40), rows: Int.random(in: 1...20)) }
        }
        print(bad == 0 ? "terminal: all checks passed" : "terminal: \(bad) failed")
        exit(bad == 0 ? 0 : 1)
    }
}
