import Foundation
import Darwin
import Metal

enum HengeLog { static func log(_ tag:String,_ message:String) { print("\(tag): \(message)") } }
@MainActor final class GamepadHub {
    static let shared = GamepadHub()
    var keyboardMapping = false
    var last = GamepadState.off
    func set(_ state:GamepadState,remote:Bool = false) { precondition(remote); last = state }
}
@main @MainActor struct ControlServiceChecks {
    static func wait(_ description:String,_ predicate:() -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime+15
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime<deadline,description)
            try? await Task.sleep(nanoseconds:10_000_000)
        }
    }
    static func main() async {
        setbuf(stdout,nil); alarm(70)
        guard let gpu=MTLCreateSystemDefaultDevice(),let queue=gpu.makeCommandQueue() else { fatalError("Real Metal device/queue required") }
        let library=try! gpu.makeLibrary(URL:URL(fileURLWithPath:"build/link/screen.metallib"))
        let host=LinkHostService(library:library),viewer=LinkViewerService()
        host.listen(wired:false)
        await wait("listener never opened") { host.port != nil }
        var pixels = 0; viewer.onPixel = { _ in pixels += 1 }
        let mode = LinkMode(width:320,height:240,widthMM:70,heightMM:52,hz:60)
        viewer.connect(host:"127.0.0.1",port:host.port!,key:host.key,wired:false,mode:mode,inputOnly:true)
        await wait("production controls-only handshake failed") { viewer.ready && host.controlOnly }
        precondition(host.mode==nil && !host.active && !host.canStart)
        precondition(test_control_video()==0 && test_control_displays()==0 && pixels==0)
        let beforeKeys = test_control_keys()
        viewer.send(LinkControl(type:"key",code:26,down:true))
        viewer.send(LinkControl(type:"gamepad",gamepad:GamepadState(buttons:1,lx:15000)))
        await wait("owned remote key/gamepad not delivered") { test_control_keys()>beforeKeys && GamepadHub.shared.last.buttons==1 }
        precondition(test_control_held()==1 && GamepadHub.shared.last.lx==15000)
        viewer.keyboardMapping = true
        await wait("host mapping preference not applied") { GamepadHub.shared.keyboardMapping }
        test_control_paused(1)
        let gated = test_control_keys(), released = test_control_releases()
        viewer.send(LinkControl(type:"key",code:27,down:true))
        viewer.send(LinkControl(type:"release")) // ordered barrier, not a timing sleep
        await wait("Paused VM release was suppressed") { test_control_releases()>released }
        precondition(test_control_keys()==gated && test_control_held()==0 && !GamepadHub.shared.last.connected)
        test_control_paused(0)
        viewer.send(LinkControl(type:"key",code:26,down:true))
        await wait("foreground input did not return") { test_control_held()==1 }
        let pairingKey=host.key,listenerPort=host.port
        viewer.setForeground(false)
        await wait("background did not release input") { test_control_held()==0 && !host.connected }
        precondition(host.key==pairingKey && host.port==listenerPort)
        viewer.setForeground(true)
        await wait("automatic foreground reconnect failed") { viewer.ready && host.controlOnly }
        precondition(host.key==pairingKey && host.port==listenerPort && viewer.mirrorSupported)
        viewer.setMirror(true,hz:120)
        await wait("primary video mirror handshake failed") { viewer.videoActive && host.mirrorActive }
        precondition(!host.active && host.controlOnly && host.mode==nil && viewer.videoHz==60 && test_control_displays()==0)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:320,height:240,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.renderTarget]
        let texture=gpu.makeTexture(descriptor:descriptor)!
        var bytes=[UInt8](repeating:128,count:320*240*4)
        bytes.withUnsafeMutableBytes { texture.replace(region:MTLRegionMake2D(0,0,320,240),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:320*4) }
        test_control_frame(Unmanaged.passUnretained(texture as AnyObject).toOpaque(),Unmanaged.passUnretained(queue as AnyObject).toOpaque())
        await wait("real mirrored texture did not encode/network/decode") { pixels>0 }
        viewer.setMirror(false)
        await wait("mirror video did not stop") { !host.mirrorActive && !viewer.videoActive }
        precondition(host.controlOnly && test_control_displays()==0)
        viewer.disconnect()
        await wait("disconnect did not release owned input") { !host.connected && test_control_held()==0 && !GamepadHub.shared.last.connected }
        host.stop();precondition(test_control_video()==1 && test_control_displays()==0 && pixels>0)
        // A restored one-port Mac must reject a video peer before allocating an
        // encoder or silently changing the guest topology. Controls-only remains valid.
        host.listen(wired:false)
        await wait("replacement listener never opened") { host.port != nil }
        viewer.connect(host:"127.0.0.1",port:host.port!,key:host.key,wired:false,mode:mode)
        await wait("running one-port Mac accepted a new monitor") { host.status.contains("saved second monitor") }
        precondition(!viewer.ready && !host.active && host.mode==nil)
        precondition(test_control_video()==1 && test_control_displays()==0)
        viewer.disconnect();host.stop()
        alarm(0)
        print("PASS production controls-only host/client over real TLS: negotiation, owned keyboard/gamepad, mapping, CPU gate, releases, disconnect; opt-in real GPU mirror encode/decode without a second monitor; foreground reconnect preserves pairing")
    }
}
