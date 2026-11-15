import Foundation

@main struct Check {
    static func main() {
        precondition(!HostScheduling.model.isEmpty && !HostScheduling.chip.isEmpty)
        precondition(!HostScheduling.layoutSource.isEmpty && HostScheduling.responsiveCPUs >= 1)
        let p = hv_host_performance_cores(), e = hv_host_efficiency_cores()
        if p == 0 || e == 0 { precondition(HostScheduling.layout == "Not available") }
        else { precondition(HostScheduling.layout == "\(p) performance / \(e) efficiency") }
        precondition(HostScheduling.isDuo == (hv_host_is_duo() != 0))
        print("PASS Swift/C host metadata bridge: \(HostScheduling.model), \(HostScheduling.chip), \(HostScheduling.layoutSource)")
    }
}
