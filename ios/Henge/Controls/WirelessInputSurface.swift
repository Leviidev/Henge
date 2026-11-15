import SwiftUI
import UIKit

// Shipping Link input surface shared with controls-only views and UI fixtures.
class LinkInputView: UIView, UIGestureRecognizerDelegate, UIKeyInput {
    var send: ((LinkControl) -> Void)?
    var rejectedPaste: (() -> Void)?
    var toggleControls: (() -> Void)? { didSet { controlTap?.isEnabled = toggleControls != nil } }
    private var controlTap:UITapGestureRecognizer?
    var acceptsInput=true {
        didSet {
            guard oldValue != acceptsInput else { return }
            isUserInteractionEnabled=acceptsInput
            if !acceptsInput { releaseInput();resignFirstResponder() }
            else if window != nil && capturesKeyboard && acceptsInput { becomeFirstResponder() }
        }
    }
    var capturesKeyboard=true
    var pointerTuning=TouchpadTuning() { didSet { if oldValue != pointerTuning { moveMotion.reset();scrollMotion.reset() } } }
    private var moveMotion=TouchpadMotion(),scrollMotion=TouchpadMotion()

    // The surface is a remote trackpad, not a text editor. Keep iOS's system
    // three-finger editing menu from taking the local controls gesture.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var canBecomeFirstResponder: Bool { capturesKeyboard && acceptsInput }
    private var heldKeys = Set<Int>()
    var keyboardEnabled = false {
        didSet { if oldValue != keyboardEnabled { releaseInput(); reloadInputViews(); if window != nil && capturesKeyboard && acceptsInput { becomeFirstResponder() } } }
    }
    override var inputView: UIView? { keyboardEnabled ? nil : UIView(frame:.zero) }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    func releaseInput() { heldKeys.removeAll();moveMotion.reset();scrollMotion.reset();send?(LinkControl(type:"release")) }
    func deleteBackward() { stroke(42,shift:false) }
    private func stroke(_ key: Int,shift: Bool) {
        let shifted = heldKeys.contains(225)
        if shift && !shifted { send?(LinkControl(type:"key",code:225,down:true)) }
        if heldKeys.contains(key) { send?(LinkControl(type:"key",code:key,down:false)) }
        send?(LinkControl(type:"key",code:key,down:true))
        if !heldKeys.contains(key) { send?(LinkControl(type:"key",code:key,down:false)) }
        if shift && !shifted { send?(LinkControl(type:"key",code:225,down:false)) }
    }
    func insertText(_ text: String) {
        guard acceptsInput else { return }
        // Bound pastes and keep enough queue capacity for releases. The
        // software keyboard is explicit US ASCII; no text enters diagnostics.
        let plain = Array("abcdefghijklmnopqrstuvwxyz1234567890\n\u{1b}\u{8}\t -=[]\\;’`,./")
        let shifted = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()")
        var mapping: [Character:(Int,Bool)] = [:]
        for (i,c) in plain.prefix(36).enumerated() { mapping[c]=(i<26 ? 4+i : 30+i-26,false) }
        for (i,c) in shifted.enumerated() { mapping[c]=(i<26 ? 4+i : 30+i-26,true) }
        mapping["\n"]=(40,false);mapping["\t"]=(43,false);mapping[" "]=(44,false)
        let punctuation: [(Character,Int)] = [("-",45),("=",46),("[",47),("]",48),("\\",49),(";",51),("'",52),("`",53),(",",54),(".",55),("/",56)]
        for (c,k) in punctuation { mapping[c]=(k,false) }
        let upper = Array(#"_+{}|:"~<>?"#)
        for ((_,k),c) in zip(punctuation,upper) { mapping[c]=(k,true) }
        guard text.count <= 16 else { rejectedPaste?(); return }
        for c in text { if let (key,shift)=mapping[c] { stroke(key,shift:shift) } }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "wireless-input-surface"
        isAccessibilityElement = true
        accessibilityLabel = "Wireless keyboard and touchpad"
        let controls = UITapGestureRecognizer(target: self, action: #selector(toggleViewerControls))
        controls.numberOfTouchesRequired = 3; controls.numberOfTapsRequired = 1
        controls.isEnabled=false;controlTap=controls;addGestureRecognizer(controls)
        let pointer = UIPanGestureRecognizer(target: self, action: #selector(pointerPan(_:))); pointer.maximumNumberOfTouches = 1; addGestureRecognizer(pointer)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:))); scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2; addGestureRecognizer(scroll)
        let click = UITapGestureRecognizer(target: self, action: #selector(click)); addGestureRecognizer(click); click.require(toFail: pointer)
        let right = UITapGestureRecognizer(target: self, action: #selector(rightClick)); right.numberOfTouchesRequired = 2; addGestureRecognizer(right); right.require(toFail: scroll)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdButton(_:)))
        hold.minimumPressDuration = 0.35; hold.delegate = self; addGestureRecognizer(hold)
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { if capturesKeyboard && acceptsInput { becomeFirstResponder() } } else { releaseInput() } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer
    }
    @objc private func toggleViewerControls() { toggleControls?() }
    @objc private func holdButton(_ hold: UILongPressGestureRecognizer) {
        if hold.state == .began { send?(LinkControl(type: "button", code: 0, down: true)) }
        if hold.state == .ended || hold.state == .cancelled || hold.state == .failed { send?(LinkControl(type: "button", code: 0, down: false)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func pointerPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { moveMotion.reset() }
        let p=pan.translation(in:self);pan.setTranslation(.zero,in:self)
        let (dx,dy)=moveMotion.consume(dx:Double(p.x),dy:Double(p.y),multiplier:Double(contentScaleFactor)*pointerTuning.normalized.pointerSpeed)
        if dx != 0 || dy != 0 { send?(LinkControl(type:"move",x:dx,y:dy)) }
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed { moveMotion.reset() }
    }
    @objc private func scroll(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { scrollMotion.reset() }
        let p=pan.translation(in:self);pan.setTranslation(.zero,in:self)
        let (x,y)=scrollMotion.consume(dx:Double(p.x),dy:Double(p.y),multiplier:pointerTuning.normalized.scrollSpeed/6)
        if x != 0 || y != 0 { send?(LinkControl(type:"scroll",x:x,y:y)) }
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed { scrollMotion.reset() }
    }
    private func button(_ n: Int) { send?(LinkControl(type: "button", code: n, down: true)); send?(LinkControl(type: "button", code: n, down: false)) }
    @objc private func click() { button(0) }
    @objc private func rightClick() { button(1) }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsInput else { return }
        for press in presses { if let key = press.key, (4...231).contains(key.keyCode.rawValue) { heldKeys.insert(key.keyCode.rawValue); send?(LinkControl(type: "key", code: key.keyCode.rawValue, down: true)) } }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key, (4...231).contains(key.keyCode.rawValue) { heldKeys.remove(key.keyCode.rawValue); send?(LinkControl(type: "key", code: key.keyCode.rawValue, down: false)) } }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }
}

struct WirelessInputSurface: UIViewRepresentable {
    let keyboard: Bool
    let send: (LinkControl) -> Void
    var capturesKeyboard = true
    var acceptsInput = true
    var identifier = "wireless-input-surface"
    @ObservedObject private var preferences=TouchpadPreferences.shared
    var rejectedPaste: () -> Void = {}
    func makeUIView(context: Context) -> LinkInputView {
        let view = LinkInputView();view.capturesKeyboard=capturesKeyboard;view.acceptsInput=acceptsInput && context.environment.isEnabled;view.accessibilityIdentifier=identifier;view.pointerTuning=preferences.value;view.send = send;view.rejectedPaste = rejectedPaste
        view.keyboardEnabled = keyboard;return view
    }
    func updateUIView(_ view: LinkInputView,context: Context) {
        view.send = send;view.rejectedPaste = rejectedPaste;view.capturesKeyboard=capturesKeyboard;view.acceptsInput=acceptsInput && context.environment.isEnabled;view.accessibilityIdentifier=identifier;view.pointerTuning=preferences.value;view.keyboardEnabled = keyboard
    }
    static func dismantleUIView(_ view: LinkInputView,coordinator: ()) {
        view.releaseInput();view.resignFirstResponder();view.send = nil;view.rejectedPaste = nil
    }
}
