import SwiftUI

struct LiveDraftManagementView: View {
    let store: LiveDraftStore
    @State private var selected: LiveDraftInventory.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            Label("Saved live drafts", systemImage: "externaldrive").font(.headline)
            Text("Raw recognizer evidence is kept until you move a draft to Trash. At 1 GiB or 100 drafts, new optional live transcription pauses; audio recording continues. Storage is checked between processed windows, so the last window may exceed the limit slightly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(store.inventory.entries.count) drafts · \(ByteCountFormatter.string(fromByteCount: store.inventory.bytes, countStyle: .file))")
                if store.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }.disabled(store.busy)
            }
            if store.inventory.incomplete {
                Text("Storage could not be fully inspected. New live processing stays paused until it can be checked; retained evidence is untouched.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let message = store.errorMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("Review retained drafts") {
                ForEach(store.inventory.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.modified, format: .dateTime.year().month().day().hour().minute())
                            Text("\(entry.url.lastPathComponent.prefix(8)) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                            if store.isProtected(entry) { Text("Active draft or recording · protected").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Button("Move to Trash…", role: .destructive) { selected = entry }
                            .disabled(store.busy || !store.canManage() || store.isProtected(entry))
                    }.padding(.vertical, StudioSpacing.xs)
                }
            }
        }
        .task { await store.refresh() }
        .confirmationDialog("Move live draft to Trash?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let draft = selected {
                Button("Move draft to Trash", role: .destructive) {
                    selected = nil
                    Task { await store.trash(draft) }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("This moves the draft's raw recognizer results, checkpoints and derived text to Trash. Original recordings stay in their recording folder. Active drafts and folders containing recordings are protected.")
        }
    }
}
