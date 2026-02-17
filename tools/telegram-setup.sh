#!/bin/bash
# telegram-setup.sh - HYDRA Telegram Setup Helper
# Helps configure and test Telegram notifications

set -euo pipefail

TELEGRAM_CONFIG="$HOME/.hydra/config/telegram.env"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           HYDRA Telegram Setup Helper                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if config exists
if [[ ! -f "$TELEGRAM_CONFIG" ]]; then
    echo "❌ Config file not found: $TELEGRAM_CONFIG"
    echo ""
    echo "Creating from template..."
    cp "$HOME/.hydra/config/telegram.env.example" "$TELEGRAM_CONFIG"
    chmod 600 "$TELEGRAM_CONFIG"
    echo "✅ Created $TELEGRAM_CONFIG"
    echo ""
fi

# Source config
source "$TELEGRAM_CONFIG"

echo "📋 Current Configuration:"
echo "   Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}... (${#TELEGRAM_BOT_TOKEN} chars)"
echo "   Chat ID:   $TELEGRAM_CHAT_ID"
echo ""

# Check if configured
if [[ "$TELEGRAM_BOT_TOKEN" == "YOUR_BOT_TOKEN_HERE" ]] || [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "⚠️  Bot token not configured!"
    echo ""
    echo "📱 Setup Instructions:"
    echo "   1. Open Telegram and search for @BotFather"
    echo "   2. Send: /newbot"
    echo "   3. Follow the prompts to name your bot"
    echo "   4. Copy the token (looks like: 123456789:ABCdefGHI...)"
    echo ""
    echo "   Then edit: $TELEGRAM_CONFIG"
    echo "   Set: TELEGRAM_BOT_TOKEN=\"your_token_here\""
    echo ""
    exit 1
fi

if [[ "$TELEGRAM_CHAT_ID" == "YOUR_CHAT_ID_HERE" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "⚠️  Chat ID not configured!"
    echo ""
    echo "📱 Get Your Chat ID:"
    echo "   1. Open Telegram and search for @userinfobot"
    echo "   2. Start a chat with it"
    echo "   3. It will reply with your ID (a number like 123456789)"
    echo ""
    echo "   Then edit: $TELEGRAM_CONFIG"
    echo "   Set: TELEGRAM_CHAT_ID=\"your_id_here\""
    echo ""
    exit 1
fi

echo "✅ Configuration looks complete!"
echo ""
echo "🧪 Testing connection to Telegram..."
echo ""

# Test API connection
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
RESPONSE=$(curl -s "${TELEGRAM_API}/getMe" 2>/dev/null)

if echo "$RESPONSE" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['first_name'])" 2>/dev/null || echo "Unknown")
    BOT_USERNAME=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['username'])" 2>/dev/null || echo "Unknown")
    echo "✅ Bot connected successfully!"
    echo "   Name: $BOT_NAME"
    echo "   Username: @$BOT_USERNAME"
    echo ""
else
    echo "❌ Failed to connect to bot!"
    echo "   Response: $RESPONSE"
    echo ""
    echo "   Check that your bot token is correct."
    exit 1
fi

# Ask to send test message
echo "Would you like to send a test message? (y/n)"
read -r SEND_TEST

if [[ "$SEND_TEST" == "y" ]] || [[ "$SEND_TEST" == "Y" ]]; then
    echo ""
    echo "📤 Sending test message..."

    TEST_MSG="🤖 HYDRA Test Message

This is a test from your HYDRA notification system.

If you can read this, Telegram is configured correctly!

Time: $(date '+%Y-%m-%d %H:%M:%S')"

    # Escape for JSON
    JSON_TEXT=$(printf '%s' "$TEST_MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    SEND_RESPONSE=$(curl -s -X POST "${TELEGRAM_API}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
            \"text\": ${JSON_TEXT}
        }" 2>/dev/null)

    if echo "$SEND_RESPONSE" | grep -q '"ok":true'; then
        echo "✅ Test message sent successfully!"
        echo "   Check your Telegram!"
    else
        echo "❌ Failed to send message!"
        echo "   Response: $SEND_RESPONSE"
        echo ""
        echo "   Common issues:"
        echo "   - Chat ID is wrong"
        echo "   - You haven't started a chat with your bot yet"
        echo "   - (Message your bot first, then try again)"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "Setup complete! Test with:"
echo "  ~/.hydra/daemons/notify-eddie.sh urgent \"Test\" \"Hello!\""
echo "════════════════════════════════════════════════════════════"
