#!/bin/bash

# Script to verify apple-app-site-association files are accessible

echo "🔍 Verifying Universal Links Configuration..."
echo ""

DOMAINS=("fireshare.us" "tweet.fireshare.us" "d2.fireshare.us")

for domain in "${DOMAINS[@]}"; do
    echo "Checking: https://${domain}/.well-known/apple-app-site-association"
    
    response=$(curl -s -o /dev/null -w "%{http_code}" "https://${domain}/.well-known/apple-app-site-association")
    
    if [ "$response" = "200" ]; then
        echo "✅ File found (HTTP $response)"
        echo "Content:"
        curl -s "https://${domain}/.well-known/apple-app-site-association" | python3 -m json.tool 2>/dev/null || curl -s "https://${domain}/.well-known/apple-app-site-association"
    else
        echo "❌ File not found (HTTP $response)"
    fi
    echo ""
done

echo "📝 Next steps:"
echo "1. If files are missing, upload apple-app-site-association to each domain"
echo "2. Ensure files are served with Content-Type: application/json"
echo "3. Test on a physical device (Universal Links don't work in simulator)"
