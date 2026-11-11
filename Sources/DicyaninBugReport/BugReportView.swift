import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension View {
    /// Shake-to-report sheet plus the report list. Attach once to the root view.
    func bugReporter() -> some View { modifier(BugReporterModifier()) }
}

struct BugReporterModifier: ViewModifier {
    @State private var reporter = BugReporter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $reporter.draft) { _ in
                BugComposeView(reporter: reporter)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $reporter.showingList) {
                BugListView(reporter: reporter).presentationDragIndicator(.visible)
            }
    }
}

struct StatusDot: View {
    var on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.red).frame(width: 7, height: 7)
            .shadow(color: (on ? Color.green : Color.red).opacity(0.6), radius: 3)
    }
}

func image(_ data: Data?) -> Image? {
    guard let data else { return nil }
    #if canImport(UIKit)
    return UIImage(data: data).map { Image(uiImage: $0) }
    #elseif canImport(AppKit)
    return NSImage(data: data).map { Image(nsImage: $0) }
    #else
    return nil
    #endif
}

struct BugComposeView: View {
    @Bindable var reporter: BugReporter
    @FocusState private var focused: Bool
    @State private var strokes: [MarkupStroke] = []

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { reporter.draft = nil }.foregroundStyle(.secondary)
                Spacer()
                Button { reporter.draft = nil; reporter.showingList = true } label: {
                    HStack(spacing: 6) {
                        StatusDot(on: reporter.cadenceOnline)
                        Text("\(reporter.reports.count)").monospacedDigit()
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityLabel(reporter.cadenceOnline ? "Cadence connected" : "Cadence offline")
            }
            if let png = reporter.draft?.png {
                MarkupEditor(png: png, strokes: $strokes)
            }
            TextField("What went wrong?", text: Binding(
                get: { reporter.draft?.note ?? "" },
                set: { reporter.draft?.note = $0 }), axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .font(.body)
            Button {
                if let png = reporter.draft?.png, let flat = BugMarkup.flatten(png, strokes: strokes) {
                    reporter.draft?.png = flat
                }
                withAnimation(.snappy) { reporter.submit() }
            } label: {
                Text("Report").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}

struct BugListView: View {
    @Bindable var reporter: BugReporter

    var body: some View {
        NavigationStack {
            List {
                ForEach(reporter.reports) { r in
                    HStack(spacing: 12) {
                        if let img = image(reporter.screenshot(r.id)) {
                            img.resizable().scaledToFill().frame(width: 40, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.note.isEmpty ? "Screenshot" : r.note).lineLimit(2)
                            Text(r.created, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.state == .working || r.state == .fixed {
                            Image(systemName: r.state == .fixed ? "checkmark" : "hammer")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        StatusDot(on: r.delivered)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(r.delivered ? "Received by Cadence" : "Saved on device")
                }
                .onDelete { s in s.map { reporter.reports[$0].id }.forEach(reporter.delete) }
            }
            .overlay { if reporter.reports.isEmpty { Text("Shake to report").foregroundStyle(.secondary) } }
            .navigationTitle("Bugs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { reporter.syncNow() } label: {
                        HStack(spacing: 6) { StatusDot(on: reporter.cadenceOnline); Image(systemName: "arrow.triangle.2.circlepath") }
                    }
                    .accessibilityLabel("Sync")
                }
            }
            .refreshable { reporter.syncNow() }
        }
    }
}
