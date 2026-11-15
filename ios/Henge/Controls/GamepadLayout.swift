import Foundation
import CoreGraphics

enum PadControl: Int, CaseIterable {
    case move, look, a, b, x, y, lb, rb, lt, rt, menu, view, leftClick, rightClick, dpad, guide
    var label: String {
        ["Move","Look","A","B","X","Y","LB","RB","LT","RT","Menu","View","L3","R3","","Home"][rawValue]
    }
    var mask: UInt16 {
        switch self {
        case .a: return 1; case .b: return 2; case .x: return 4; case .y: return 8
        case .lb: return 16; case .rb: return 32; case .leftClick: return 64; case .rightClick: return 128
        case .menu: return 256; case .view: return 512; case .guide: return 1024
        default: return 0
        }
    }
}

/// Shared geometry for drawing, hit testing and preview checks.
struct PadLayout {
    let bounds: CGRect
    let scale: CGFloat
    let portrait: Bool
    init(bounds: CGRect, size: Double, portrait: Bool = false) {
        self.bounds = bounds
        self.portrait=portrait
        scale = max(0.01,min(CGFloat(size),min(bounds.width/(portrait ? 390 : 560),bounds.height/(portrait ? 700 : 320))))
    }
    var touchpadRect: CGRect {
        if portrait { return mapped(CGRect(x:24,y:40,width:342,height:224)) }
        let width=min(260*scale,max(1,bounds.width-416*scale))
        return CGRect(x:bounds.midX-width/2,y:bounds.maxY-178*scale,width:width,height:60*scale)
    }
    private func mapped(_ rect: CGRect) -> CGRect {
        CGRect(x:bounds.midX-195*scale+rect.minX*scale,y:bounds.maxY-700*scale+rect.minY*scale,width:rect.width*scale,height:rect.height*scale)
    }
    func rect(_ control: PadControl) -> CGRect {
        if portrait {
            let r:CGRect
            switch control {
            case .move:r=CGRect(x:18,y:392,width:112,height:112)
            case .look:r=CGRect(x:200,y:566,width:112,height:112)
            case .a:r=CGRect(x:282,y:492,width:44,height:44)
            case .b:r=CGRect(x:334,y:440,width:44,height:44)
            case .x:r=CGRect(x:230,y:440,width:44,height:44)
            case .y:r=CGRect(x:282,y:388,width:44,height:44)
            case .lb:r=CGRect(x:18,y:312,width:90,height:40)
            case .rb:r=CGRect(x:282,y:312,width:90,height:40)
            case .lt:r=CGRect(x:116,y:304,width:58,height:70)
            case .rt:r=CGRect(x:216,y:304,width:58,height:70)
            case .view:r=CGRect(x:137,y:392,width:48,height:34)
            case .menu:r=CGRect(x:191,y:392,width:48,height:34)
            case .guide:r=CGRect(x:175,y:450,width:40,height:40)
            case .leftClick:r=CGRect(x:142,y:508,width:34,height:34)
            case .rightClick:r=CGRect(x:326,y:592,width:34,height:34)
            case .dpad:r=CGRect(x:30,y:564,width:88,height:88)
            }
            return mapped(r)
        }
        let w = bounds.width/scale
        let r: CGRect
        switch control {
        case .move: r = CGRect(x:22,y:114,width:112,height:112)
        case .look: r = CGRect(x:w-236,y:204,width:112,height:112)
        case .a: r = CGRect(x:w-116,y:174,width:44,height:44)
        case .b: r = CGRect(x:w-64,y:122,width:44,height:44)
        case .x: r = CGRect(x:w-168,y:122,width:44,height:44)
        case .y: r = CGRect(x:w-116,y:70,width:44,height:44)
        case .lb: r = CGRect(x:24,y:24,width:90,height:40)
        case .rb: r = CGRect(x:w-114,y:24,width:90,height:40)
        case .lt: r = CGRect(x:128,y:10,width:58,height:70)
        case .rt: r = CGRect(x:w-186,y:10,width:58,height:70)
        case .menu: r = CGRect(x:w/2+20,y:94,width:48,height:34)
        case .view: r = CGRect(x:w/2-68,y:94,width:48,height:34)
        case .guide: r = CGRect(x:w/2-20,y:30,width:40,height:40)
        case .leftClick: r = CGRect(x:145,y:151,width:34,height:34)
        case .rightClick: r = CGRect(x:w-279,y:243,width:34,height:34)
        case .dpad: r = CGRect(x:140,y:216,width:88,height:88)
        }
        return CGRect(x:bounds.minX+r.minX*scale,y:bounds.maxY-320*scale+r.minY*scale,
                      width:r.width*scale,height:r.height*scale)
    }
}
