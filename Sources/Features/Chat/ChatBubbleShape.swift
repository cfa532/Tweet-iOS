import SwiftUI

struct ChatBubbleShape: Shape {
    let isFromCurrentUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let cornerRadius: CGFloat = 12
        let bezierPath = UIBezierPath()
        
        if isFromCurrentUser {
            // Right-aligned bubble (sent by current user) - rounded except bottom-right
            bezierPath.move(to: CGPoint(x: width - cornerRadius, y: height))
            bezierPath.addLine(to: CGPoint(x: cornerRadius, y: height))
            bezierPath.addCurve(to: CGPoint(x: 0, y: height - cornerRadius), 
                               controlPoint1: CGPoint(x: cornerRadius * 0.5, y: height), 
                               controlPoint2: CGPoint(x: 0, y: height - cornerRadius * 0.5))
            bezierPath.addLine(to: CGPoint(x: 0, y: cornerRadius))
            bezierPath.addCurve(to: CGPoint(x: cornerRadius, y: 0), 
                               controlPoint1: CGPoint(x: 0, y: cornerRadius * 0.5), 
                               controlPoint2: CGPoint(x: cornerRadius * 0.5, y: 0))
            bezierPath.addLine(to: CGPoint(x: width - cornerRadius, y: 0))
            bezierPath.addCurve(to: CGPoint(x: width, y: cornerRadius), 
                               controlPoint1: CGPoint(x: width - cornerRadius * 0.5, y: 0), 
                               controlPoint2: CGPoint(x: width, y: cornerRadius * 0.5))
            bezierPath.addLine(to: CGPoint(x: width, y: height))
            bezierPath.close()
        } else {
            // Left-aligned bubble (received from other user) - rounded except bottom-left
            bezierPath.move(to: CGPoint(x: cornerRadius, y: height))
            bezierPath.addLine(to: CGPoint(x: width - cornerRadius, y: height))
            bezierPath.addCurve(to: CGPoint(x: width, y: height - cornerRadius), 
                               controlPoint1: CGPoint(x: width - cornerRadius * 0.5, y: height), 
                               controlPoint2: CGPoint(x: width, y: height - cornerRadius * 0.5))
            bezierPath.addLine(to: CGPoint(x: width, y: cornerRadius))
            bezierPath.addCurve(to: CGPoint(x: width - cornerRadius, y: 0), 
                               controlPoint1: CGPoint(x: width, y: cornerRadius * 0.5), 
                               controlPoint2: CGPoint(x: width - cornerRadius * 0.5, y: 0))
            bezierPath.addLine(to: CGPoint(x: cornerRadius, y: 0))
            bezierPath.addCurve(to: CGPoint(x: 0, y: cornerRadius), 
                               controlPoint1: CGPoint(x: cornerRadius * 0.5, y: 0), 
                               controlPoint2: CGPoint(x: 0, y: cornerRadius * 0.5))
            bezierPath.addLine(to: CGPoint(x: 0, y: height))
            bezierPath.close()
        }
        
        return Path(bezierPath.cgPath)
    }
} 