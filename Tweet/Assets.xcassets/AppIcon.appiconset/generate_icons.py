from PIL import Image
import os

# Source image
source_image = "Icon-iOS-Marketing.png"

# Icon sizes
sizes = [
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

# Open the source image
try:
    with Image.open(source_image) as img:
        # Generate each size
        for name, size in sizes:
            # Resize the image
            resized = img.resize((size, size), Image.Resampling.LANCZOS)
            # Save the resized image
            output_file = f"Icon-{name}.png"
            resized.save(output_file, "PNG")
            print(f"Generated: {output_file}")
except Exception as e:
    print(f"Error: {e}") 