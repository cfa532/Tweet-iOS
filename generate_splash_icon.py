#!/usr/bin/env python3
"""Generate splash icon with two doves design"""

from PIL import Image, ImageDraw
import sys

def create_two_doves_icon(output_path, size=1024):
    """Create an icon with two white doves outlined in blue on black background"""
    
    # Create image with black background
    img = Image.new('RGB', (size, size), color='black')
    draw = ImageDraw.Draw(img)
    
    # Colors
    white = (255, 255, 255)
    blue = (0, 120, 255)
    
    # Scale factor
    s = size / 1024
    
    # Left dove (facing right)
    left_dove_body = [
        (int(200*s), int(450*s)),
        (int(250*s), int(400*s)),
        (int(300*s), int(380*s)),
        (int(350*s), int(400*s)),
        (int(380*s), int(450*s)),
        (int(360*s), int(520*s)),
        (int(320*s), int(560*s)),
        (int(260*s), int(580*s)),
        (int(220*s), int(560*s)),
        (int(200*s), int(520*s)),
    ]
    
    # Left dove wing
    left_wing = [
        (int(280*s), int(420*s)),
        (int(250*s), int(320*s)),
        (int(220*s), int(280*s)),
        (int(200*s), int(260*s)),
        (int(190*s), int(280*s)),
        (int(210*s), int(330*s)),
        (int(240*s), int(380*s)),
        (int(270*s), int(420*s)),
    ]
    
    # Right dove (facing left) - mirrored
    center_x = size // 2
    right_dove_body = [(2*center_x - x, y) for x, y in left_dove_body]
    right_wing = [(2*center_x - x, y) for x, y in left_wing]
    
    # Draw left dove
    draw.polygon(left_dove_body, fill=white, outline=blue, width=int(3*s))
    draw.polygon(left_wing, fill=white, outline=blue, width=int(3*s))
    
    # Draw right dove
    draw.polygon(right_dove_body, fill=white, outline=blue, width=int(3*s))
    draw.polygon(right_wing, fill=white, outline=blue, width=int(3*s))
    
    # Draw heads for left dove
    draw.ellipse([int(340*s), int(380*s), int(380*s), int(420*s)], fill=white, outline=blue, width=int(3*s))
    # Beak
    draw.polygon([
        (int(380*s), int(395*s)),
        (int(400*s), int(400*s)),
        (int(380*s), int(405*s))
    ], fill=white, outline=blue, width=int(2*s))
    
    # Draw heads for right dove
    draw.ellipse([2*center_x - int(380*s), int(380*s), 2*center_x - int(340*s), int(420*s)], fill=white, outline=blue, width=int(3*s))
    # Beak
    draw.polygon([
        (2*center_x - int(380*s), int(395*s)),
        (2*center_x - int(400*s), int(400*s)),
        (2*center_x - int(380*s), int(405*s))
    ], fill=white, outline=blue, width=int(2*s))
    
    # Save
    img.save(output_path, 'PNG')
    print(f"Splash icon saved to {output_path}")

if __name__ == '__main__':
    output = sys.argv[1] if len(sys.argv) > 1 else 'ic_splash.png'
    create_two_doves_icon(output)

