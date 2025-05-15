import SwiftUI

struct ProfileView: View {
    var body: some View {
        NavigationView {
            VStack {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 100, height: 100)
                    .padding()
                
                Text("Profile Placeholder")
                    .font(.title)
                
                Spacer()
            }
            .navigationTitle("Profile")
        }
    }
} 