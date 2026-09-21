import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HistoryList(history: state.history)
    }
}

/// Separate view so SwiftUI observes the history object directly.
private struct HistoryList: View {
    @ObservedObject var history: History

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { history.clear() }
                    .controlSize(.small)
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)

            Divider()

            if history.entries.isEmpty {
                Text("Nothing sent yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.success
                                      ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(entry.success ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(timestamp(entry.date)
                                         + " · " + Format.size(entry.size)
                                         + (entry.reason.isEmpty ? "" : " · " + entry.reason))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 260, idealHeight: 420)
    }

    private func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }
}
