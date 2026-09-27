import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isCompact {
                CompactStripView(model: model)
            } else {
                HistoryView(model: model)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
