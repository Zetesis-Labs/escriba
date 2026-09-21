import SwiftUI

struct ListDetailLayout<ListColumn: View, Detail: View>: View {
    var listWidth: CGFloat = 290
    @ViewBuilder let list: ListColumn
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
