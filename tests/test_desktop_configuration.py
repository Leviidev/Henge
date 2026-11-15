"""Run the production VirtualMac policy with controlled device capabilities."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'ios/Henge/Machines.swift').read_text()
source=source[source.index('struct VirtualMac:'):source.index('/// How much RAM')]
fixture='''
import Foundation
enum EngineTuning { static let graphicsBackendKey="henge.test.fx.backend" }
enum Machines { static func directory(for id:UUID)->URL { URL(fileURLWithPath:"/test/"+id.uuidString) } }
enum Device {
    static var supportsDesktopMetalFX=true
    static var isPad=true,largeScreen=false
    static let sideStrip:CGFloat=84
    static var displayViewport=CGSize(width:1376,height:1032)
    static let retinaScreen=(width:2752,height:2064)
    static func desktopRetina(in viewport:CGSize)->GuestScreenSize { GuestScreenSize.desktopRetina(in:viewport) }
}
'''+source+'''
@main struct Check {
    static func main() throws {
        let d=UserDefaults.standard;d.removeObject(forKey:EngineTuning.graphicsBackendKey)
        var mac=VirtualMac(name:"Mac",ecid:123,seed:1,ramMB:8192,diskBytes:64<<30)
        mac.desktopLayout=true
        precondition(mac.isRetina && !mac.usesDesktopMetalFX)
        precondition(mac.displaySize(in:Device.displayViewport)==GuestScreenSize(width:2560,height:1920))
        let native=try JSONDecoder().decode(VirtualMac.self,from:JSONEncoder().encode(mac))
        precondition(native.desktopMetalFX==nil && native.isRetina)
        mac.desktopMetalFX=true
        precondition(!mac.isRetina && mac.usesDesktopMetalFX && !mac.fitsDeviceScreen)
        precondition(mac.displaySize(in:Device.displayViewport)==GuestScreenSize(width:1280,height:960))
        let fx=try JSONDecoder().decode(VirtualMac.self,from:JSONEncoder().encode(mac))
        precondition(fx.desktopMetalFX==true && fx.displaySize(in:Device.displayViewport).width==1280)
        Device.supportsDesktopMetalFX=false
        precondition(mac.isRetina && mac.displaySize(in:Device.displayViewport).width==2560)
        Device.supportsDesktopMetalFX=true;d.set("compatibility",forKey:EngineTuning.graphicsBackendKey)
        precondition(mac.isRetina && !mac.usesDesktopMetalFX)
        d.removeObject(forKey:EngineTuning.graphicsBackendKey)
        Device.isPad=false;Device.displayViewport=CGSize(width:951,height:669)
        precondition(mac.displaySize(in:Device.displayViewport)==GuestScreenSize(width:1280,height:900))
        mac.desktopLayout=false;mac.retina=false;mac.fitScreen=true
        precondition(!mac.usesDesktopMetalFX && mac.fitsDeviceScreen)
        precondition(mac.displaySize(in:Device.displayViewport).width==1920)
        print("PASS Desktop MetalFX configuration: actual VirtualMac activation, legacy native default, same workspace, capability/backend fallbacks, Duo and Fit independence")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='henge-desktop-fx-') as directory:
    path=Path(directory);(path/'check.swift').write_text(fixture)
    subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(root/'ios/Henge/GuestScreenSize.swift'),str(path/'check.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
