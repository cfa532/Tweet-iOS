import SwiftUI

struct ProfileView: View {
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        if let avatarUrl = URL(string: "https://example.com/avatar.jpg") {
                            AsyncImage(url: avatarUrl) { image in
                                image.resizable()
                            } placeholder: {
                                Color.gray
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                        }
                        
                        VStack(alignment: .leading) {
                            Text("John Doe")
                                .font(.title2)
                                .bold()
                            Text("@johndoe")
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section {
                    HStack {
                        Text("Tweets")
                        Spacer()
                        Text("0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("Following")
                        Spacer()
                        Text("0")
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("Followers")
                        Spacer()
                        Text("0")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
} 