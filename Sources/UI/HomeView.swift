import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationView {
            List {
                Text("Sample Tweet 1")
                Text("Sample Tweet 2")
                Text("Sample Tweet 3")
            }
            .navigationTitle("Home")
        }
    }
} 