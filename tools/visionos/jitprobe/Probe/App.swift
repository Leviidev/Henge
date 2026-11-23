import SwiftUI

@main
struct JITProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var text = "Waiting for a debugger…"
    var body: some View {
        ScrollView {
            Text(text).font(.system(.body, design: .monospaced)).padding(40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            let result = await Task.detached { String(cString: probe_run()) }.value
            text = result
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("jitprobe.txt")
            try? result.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
