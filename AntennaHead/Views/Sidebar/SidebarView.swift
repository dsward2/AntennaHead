import SwiftUI

struct SidebarView: View {
    @Binding var selectedCategory: Category?
    var refreshID: UUID
    @State private var categories: [Category] = []

    var body: some View {
        List(selection: $selectedCategory) {
            Section("Categories") {
                ForEach(categories) { category in
                    Label(category.categoryName, systemImage: icon(for: category))
                        .tag(category)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .task(id: refreshID) { reload() }
    }

    private func reload() {
        categories = (try? SQLiteController.shared.allCategoryRecords()) ?? []
    }

    private func icon(for category: Category) -> String {
        let name = category.categoryName.lowercased()
        if name.contains("aviation") { return "airplane" }
        if name.contains("fm") { return "radio" }
        if name.contains("weather") || name.contains("noaa") { return "cloud.sun" }
        if name.contains("shortwave") { return "antenna.radiowaves.left.and.right" }
        return "list.bullet"
    }
}
