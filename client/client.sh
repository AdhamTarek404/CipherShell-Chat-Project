#!/bin/bash
# client.sh login <username> [host] [port]

CMD=$1
USERNAME=$2
HOST=${3:-127.0.0.1}
PORT=${4:-9000}

if [ "$CMD" != "login" ] || [ -z "$USERNAME" ]; then
    echo "Usage: $0 login <username> [host] [port]"
    exit 1
fi

if [ ! -f ~/.ciphershell/$USERNAME/private.pem ]; then
    echo "Error: Keypair not found. Please run register.sh first."
    exit 1
fi

# Set umask to 077 to ensure FIFOs are read/write only by the owner
ORIGINAL_UMASK=$(umask)
umask 077
mkdir -p ~/.ciphershell/$USERNAME/pipes
rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
mkfifo ~/.ciphershell/$USERNAME/pipes/in
mkfifo ~/.ciphershell/$USERNAME/pipes/out
umask $ORIGINAL_UMASK

# Keep the pipe open for writing so nc doesn't exit when send.sh finishes
exec 3> ~/.ciphershell/$USERNAME/pipes/in

nc "$HOST" "$PORT" < ~/.ciphershell/$USERNAME/pipes/in > ~/.ciphershell/$USERNAME/pipes/out &
NC_PID=$!

# Send login command
echo "LOGIN $USERNAME" >&3

# Start listener
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
bash "$SCRIPT_DIR/listener.sh" ~/.ciphershell/$USERNAME/pipes/out "$USERNAME" &
LISTENER_PID=$!

echo "Logged in as $USERNAME. Connection established to $HOST:$PORT."
echo "Use './send.sh <sender_username> <recipient> <message>' to send messages."
echo "Use './send_file.sh <sender_username> <recipient> <file>' to send files."
echo "Press Ctrl+C to disconnect."

# Trap EXIT to guarantee cleanup
cleanup() {
    kill $NC_PID $LISTENER_PID 2>/dev/null
    rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
}
trap cleanup EXIT

wait $NC_PID
echo "Connection closed."
