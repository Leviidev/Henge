import SwiftUI

/// Shared controller composition; video remains the existing native decoder.
/// Portrait Duo uses the upper panel for video and the lower for controls.
struct WirelessVideoControls<Video:View,Toolbar:View>:View {
    let isDuo:Bool
    let tuning:GamepadTuning
    var acceptsInput=true
    let sendPad:(GamepadState)->Void
    let sendPointer:(LinkControl)->Void
    let video:Video
    let toolbar:Toolbar
    var body:some View {
        GeometryReader { geometry in
            let ds=isDuo && geometry.size.height>geometry.size.width
            let layout=ControllerPostureLayout(size:geometry.size,choice:.tabletop,isDuo:isDuo,division:controllerDivision(geometry,isDuo:isDuo))
            if ds {
                VStack(spacing:0) {
                    video.overlay(alignment:.top) { toolbar.padding(8) }
                        .frame(height:layout.upper.height)
                    Color.clear.frame(height:layout.fold.height).allowsHitTesting(false)
                    GamepadControllerSurface(tuning:tuning,acceptsInput:acceptsInput,send:sendPad,sendPointer:sendPointer)
                        .frame(height:layout.lower.height)
                }.background(.black)
            } else {
                ZStack(alignment:.bottom) {
                    video.ignoresSafeArea()
                    GamepadControllerSurface(tuning:tuning,acceptsInput:acceptsInput,send:sendPad,sendPointer:sendPointer)
                        .frame(height:min(360,geometry.size.height*0.72))
                    VStack { toolbar.padding(8);Spacer() }.allowsHitTesting(true)
                }.background(.black)
            }
        }
    }
}
