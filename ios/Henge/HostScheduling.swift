import Foundation

/// Host identity is independent of the Mac's advertised CPU or a remote viewer.
enum HostScheduling {
    static var isDuo: Bool { hv_host_is_duo() != 0 }
    static var model: String { String(cString: hv_host_model()) }
    static var chip: String { String(cString: hv_host_chip()) }
    static var layoutSource: String { String(cString: hv_host_layout_source()) }
    static var responsiveCPUs: Int { max(1, Int(hv_host_performance_cores())) }
    static var layout: String {
        let p = hv_host_performance_cores(), e = hv_host_efficiency_cores()
        return p > 0 && e > 0 ? "\(p) performance / \(e) efficiency" : "Not available"
    }
}
