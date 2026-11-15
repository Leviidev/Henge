import Foundation
import Combine
import UIKit

@MainActor final class DiskExpansion:ObservableObject {
    static let shared=DiskExpansion()
    @Published private(set) var busy=false
    @Published private(set) var activity=""
    struct Outcome {
        let mac:VirtualMac
        let lastPartitionIsAPFS:Bool
    }
    func expand(_ mac:VirtualMac,toGB gb:Int) async throws -> Outcome {
        guard !busy,Machines.shared.importing==nil,Machines.shared.exporting==nil,henge_vm_can_start() != 0 else { throw failure("Finish Mac shutdown and any import/export before expanding storage.") }
        guard !InstantResume.hasSave(for:mac) else { throw failure("Resume and fully shut down this Mac first. A saved session cannot be used after its disk changes.") }
        guard gb>0,gb<=2048,(Int64(gb) << 30) > mac.diskBytes else { throw failure("Choose a larger whole-GB size, up to 2048 GB.") }
        busy=true;activity="Expanding the virtual disk…"
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { busy=false;activity="";UIApplication.shared.isIdleTimerDisabled=idle }
        let result=await Task.detached(priority:.utility) { ()->(Int32,String,UInt32) in
            var error=[CChar](repeating:0,count:512),partition:UInt32=0
            let rc=henge_disk_expand(mac.disk.path,UInt64(gb)<<30,&partition,&error,error.count)
            return (rc,String(cString:error),partition)
        }.value
        guard result.0==0 else { throw failure(result.1) }
        var updated=mac;updated.diskBytes=Int64(gb)<<30
        Machines.shared.update(updated)
        HengeLog.log("storage","Expanded virtual disk to \(gb) GiB; previous image retained; APFS volume expansion occurs inside macOS")
        return Outcome(mac:updated,lastPartitionIsAPFS:result.2 != 0)
    }
    struct Layout {
        let diskBytes:UInt64
        let containerBytes:UInt64
        let freeBytes:UInt64
        let canPrepare:Bool
    }
    func layout(_ mac:VirtualMac,prepare:Bool=false) async throws -> Layout {
        guard !busy,Machines.shared.importing==nil,Machines.shared.exporting==nil,henge_vm_can_start() != 0 else { throw failure("Finish Mac shutdown and any import/export before checking storage.") }
        guard !InstantResume.hasSave(for:mac) else { throw failure("Resume and fully shut down this Mac first; its disk must not change while a saved session exists.") }
        busy=true;activity=prepare ? "Copying and verifying Recovery…" : "Checking the partition map…"
        let idle=UIApplication.shared.isIdleTimerDisabled
        if prepare { UIApplication.shared.isIdleTimerDisabled=true }
        defer { busy=false;activity="";if prepare { UIApplication.shared.isIdleTimerDisabled=idle } }
        let result=await Task.detached(priority:.utility) { ()->(Int32,String,UInt64,UInt64,UInt64,Bool) in
            var error=[CChar](repeating:0,count:512),info=HvDiskExpansionInfo()
            let rc=prepare ? henge_disk_prepare_apfs(mac.disk.path,&info,&error,error.count) : henge_disk_expansion_info(mac.disk.path,&info,&error,error.count)
            return (rc,String(cString:error),info.disk_bytes,info.apfs_bytes,info.contiguous_bytes,info.can_prepare != 0)
        }.value
        guard result.0==0 else { throw failure(result.1) }
        if prepare { HengeLog.log("storage","APFS expansion prepared on a verified clone; Recovery retained; macOS must finish container growth") }
        return Layout(diskBytes:result.2,containerBytes:result.3,freeBytes:result.4,canPrepare:result.5)
    }
    private func failure(_ message:String)->NSError { NSError(domain:"HengeStorage",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
