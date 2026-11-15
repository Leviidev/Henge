import SwiftUI
import UIKit

struct DiskExpansionView:View {
    let mac:VirtualMac
    let completed:(VirtualMac)->Void
    @ObservedObject private var expansion=DiskExpansion.shared
    @Environment(\.dismiss) private var dismiss
    @State private var capacity="128"
    @State private var notice=""
    @State private var finished=false
    @State private var layout:DiskExpansion.Layout?
    @State private var confirmPreparation=false
    var body:some View {
        NavigationStack {
            Form {
                Section("Virtual disk capacity") {
                    Text("Current: \(mac.diskBytes>>30) GB")
                    HStack {
                        ForEach([128,256,512],id:\.self) { size in
                            Button("\(size) GB") { capacity=String(size) }.buttonStyle(.bordered).disabled((Int64(size) << 30) <= mac.diskBytes)
                        }
                    }
                    TextField("Custom size in GB",text:$capacity).keyboardType(.numberPad)
                    Text("A larger sparse disk reserves virtual capacity; device storage is consumed as macOS writes data. This does not add physical storage to your iPad or iPhone.").font(.footnote)
                    Text("Fully shut down macOS first. Expansion preserves an original disk backup and repairs both GPT partition maps. Shrinking is not supported.").font(.footnote)
                    if InstantResume.hasSave(for:mac) { Text("Resume and fully shut down the saved Mac before expanding. Paused/saved state cannot be resized.").foregroundStyle(.orange) }
                    Button("Expand disk") { expand() }
                        .disabled(expansion.busy || finished || InstantResume.hasSave(for:mac) || !(Int(capacity).map { $0>0 && $0<=2048 && (Int64($0) << 30) > mac.diskBytes } ?? false))
                    if expansion.busy { ProgressView(expansion.activity) }
                }
                if !notice.isEmpty { Section { Text(notice) } }
                Section("Finish macOS volume expansion") {
                    Text("This step is available whenever you reopen storage settings. Increasing the virtual drive alone does not enlarge Macintosh HD.")
                    if let layout {
                        Text("Drive: \(Self.size(layout.diskBytes)) · APFS partition: \(Self.size(layout.containerBytes))")
                        if layout.canPrepare {
                            Text("A trailing Recovery container blocks the new space. Henge can copy it to the end of the expanded drive without erasing it, verify the copy, and preserve the original image. Keep Henge visible until preparation finishes.")
                            Button("Prepare APFS expansion…") { confirmPreparation=true }.disabled(expansion.busy)
                        } else if layout.freeBytes >= 1024*1024 {
                            Text("\(Self.size(layout.freeBytes)) is available after the APFS partition. Start the Mac and run the command below to expand Macintosh HD.")
                        } else {
                            Text("No contiguous space is available after the APFS partition. If Macintosh HD still shows the old size, inspect diskutil list and diskutil apfs list in macOS; Henge leaves unrecognised partition layouts unchanged.")
                        }
                    }
                    Button("Check disk layout") { inspect() }.disabled(expansion.busy || InstantResume.hasSave(for:mac))
                    Text("After preparation, start the Mac normally. Run this in its Terminal; it finds the boot APFS container and macOS may ask for your administrator password.")
                    Text(Self.volumeCommand).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy volume expansion command") { UIPasteboard.general.string=Self.volumeCommand }
                    Text("Backups stay in this Mac's folder: disk.img.before-expansion (before capacity growth), and disk.img.before-apfs-expansion (before Recovery relocation). Keep them until the enlarged Mac boots and your files are verified. These local clones are not an external backup.").font(.footnote)
                }

            }
            .navigationTitle("Expand storage")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() }.disabled(expansion.busy) } }
            .interactiveDismissDisabled(expansion.busy)
            .onAppear { capacity=String(max(128,Int((mac.diskBytes>>30)+1)));inspect() }
            .confirmationDialog("Prepare the internal Mac disk for APFS expansion?",isPresented:$confirmPreparation,titleVisibility:.visible) {
                Button("Preserve backup and prepare") { inspect(prepare:true) }
                Button("Cancel",role:.cancel) {}
            } message: {
                Text("The Mac must be fully shut down. Recovery will be copied and verified on a clone before the original image is replaced. This may need several GB of device storage. APFS is enlarged inside macOS afterwards.")
            }
        }
    }
    // Plutil extracts the actual running root's container. No guessed disk0s2,
    // no formatting, partition deletion or APFS metadata writes in iOS.
    static let volumeCommand="container=$(diskutil info -plist / | plutil -extract APFSContainerReference raw -o - -) && case \"$container\" in disk[0-9]*) sudo diskutil apfs resizeContainer \"$container\" 0 ;; *) echo 'Could not identify the boot APFS container; use Disk Utility.' ;; esac"
    private static func size(_ bytes:UInt64)->String { String(format:"%.1f GiB",Double(bytes)/1073741824) }
    private func inspect(prepare:Bool=false) {
        Task {
            do {
                layout=try await expansion.layout(mac,prepare:prepare)
                if prepare { notice="Preparation complete. Start macOS and run the volume expansion command below." }
            } catch { notice=error.localizedDescription }
        }
    }
    private func expand() {
        guard let size=Int(capacity) else { return }
        Task {
            do {
                let result=try await expansion.expand(mac,toGB:size)
                finished=true;completed(result.mac)
                layout=try await expansion.layout(result.mac)
                notice="Virtual disk expanded to \(size) GB. The original image is preserved."
            } catch { notice=error.localizedDescription }
        }
    }
}
