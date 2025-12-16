#!/usr/bin/env python3
"""
Clean trailing empty lines from .strings files
Called by git pre-commit hook to prevent Xcode from adding multiple trailing newlines
"""
import sys
import os

def clean_file(filepath):
    """Remove trailing empty lines from a file, keeping only one trailing newline"""
    if not os.path.isfile(filepath):
        return False
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        # Remove trailing empty lines
        while lines and lines[-1].strip() == '':
            lines.pop()
        
        # Ensure file ends with single newline
        if lines:
            if not lines[-1].endswith('\n'):
                lines[-1] += '\n'
        else:
            lines = ['\n']
        
        with open(filepath, 'w', encoding='utf-8') as f:
            f.writelines(lines)
        
        return True
    except Exception as e:
        print(f"Error cleaning {filepath}: {e}", file=sys.stderr)
        return False

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(0)
    
    files_cleaned = 0
    for filepath in sys.argv[1:]:
        if clean_file(filepath):
            files_cleaned += 1
    
    sys.exit(0)

