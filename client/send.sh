#!/bin/bash
# send.sh <sender_username> <recipient> <message>
SENDER=$1
RECIPIENT=$2
shift 2
MESSAGE="$*"

if [ -z "$SENDER" ] || [ -z "$RECIPIENT" ] || [ -z "$MESSAGE" ]; then
    echo "Usage: $0 <sender_username> <recipient> <message...>"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

if [ ! -p ~/.ciphershell/$SENDER/pipes/in ]; then
    echo "Error: Not connected. Run ./client.sh login first."
    exit 1
fi

PUB_KEY="$ROOT_DIR/server/users.db/${RECIPIENT}.pub"
if [ ! -f "$PUB_KEY" ]; then
    echo "Error: Public key for $RECIPIENT not found in server/users.db"
    exit 1
fi

TEMP_TXT=$(mktemp)
TEMP_B64=$(mktemp)

echo -n "MSG: $MESSAGE" > "$TEMP_TXT"

bash "$ROOT_DIR/crypto/encrypt.sh" "$PUB_KEY" "$TEMP_TXT" "$TEMP_B64"

{
    echo -n "SEND $RECIPIENT "
    cat "$TEMP_B64"
    echo ""
} > ~/.ciphershell/$SENDER/pipes/in

echo "Message sent to $RECIPIENT."

rm -f "$TEMP_TXT" "$TEMP_B64"
