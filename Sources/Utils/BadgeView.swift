import SwiftUI

struct BadgeView: View {
    let count: Int
    let size: CGFloat
    
    init(count: Int, size: CGFloat = 20) {
        self.count = count
        self.size = size
    }
    
    var body: some View {
        if count > 0 {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: size, height: size)
                
                Text("\(count > 99 ? "99+" : "\(count)")")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
            }
        }
    }
}

struct BadgeView_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            BadgeView(count: 1)
            BadgeView(count: 5)
            BadgeView(count: 99)
            BadgeView(count: 100)
        }
        .padding()
    }
} 