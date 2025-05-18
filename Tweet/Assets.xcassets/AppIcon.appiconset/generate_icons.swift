import AppKit

@main
struct IconGeneratorApp {
    static func main() async {
        // Icon sizes for different devices and scales
        let iconSizes: [(name: String, size: CGFloat)] = [
            ("iPhone-20@2x", 40),
            ("iPhone-20@3x", 60),
            ("iPhone-29@2x", 58),
            ("iPhone-29@3x", 87),
            ("iPhone-40@2x", 80),
            ("iPhone-40@3x", 120),
            ("iPhone-60@2x", 120),
            ("iPhone-60@3x", 180),
            ("iPad-20@1x", 20),
            ("iPad-20@2x", 40),
            ("iPad-29@1x", 29),
            ("iPad-29@2x", 58),
            ("iPad-40@1x", 40),
            ("iPad-40@2x", 80),
            ("iPad-76@1x", 76),
            ("iPad-76@2x", 152),
            ("iPad-83.5@2x", 167)
        ]
        
        // Load the source image
        guard let sourceImage = NSImage(contentsOfFile: "Icon-iOS-Marketing.png") else {
            print("Error: Could not load Icon-iOS-Marketing.png")
            return
        }
        
        // Generate icons for each size
        for (name, size) in iconSizes {
            let newSize = NSSize(width: size, height: size)
            let resizedImage = NSImage(size: newSize)
            
            resizedImage.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            sourceImage.draw(in: NSRect(origin: .zero, size: newSize),
                           from: NSRect(origin: .zero, size: sourceImage.size),
                           operation: .copy,
                           fraction: 1.0)
            resizedImage.unlockFocus()
            
            if let tiffData = resizedImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: URL(fileURLWithPath: "Icon-\(name).png"))
                print("Generated: Icon-\(name).png")
            }
        }
    }
} 