#!/bin/bash
# demo.sh - Automated Demo Script for CipherShell Chat

echo "======================================"
echo "    CipherShell Automated Demo"
echo "======================================"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR" || exit 1

echo "[*] Cleaning up previous state..."
rm -rf ~/.ciphershell/alice ~/.ciphershell/bob
rm -rf server/users.db
pkill -f "socket_mux.py" || true
pkill -f "nc 127.0.0.1 9000" || true

echo "[*] Starting server in background..."
bash server/server.sh 9000 > server.log 2>&1 &
SERVER_PID=$!
sleep 2

echo "[*] Registering Alice..."
bash client/register.sh alice

echo "[*] Registering Bob..."
bash client/register.sh bob

echo "[*] Alice logs in (background)..."
bash client/client.sh login alice 127.0.0.1 9000 > alice_client.log 2>&1 &
ALICE_CLIENT_PID=$!
sleep 2

echo "[*] Bob logs in (background)..."
bash client/client.sh login bob 127.0.0.1 9000 > bob_client.log 2>&1 &
BOB_CLIENT_PID=$!
sleep 2

echo "[*] Alice sends a message to Bob..."
bash client/send.sh alice bob "Hello Bob, this is a secret message!"
sleep 2

echo "[*] Bob sends a reply to Alice..."
bash client/send.sh bob alice "Hi Alice, message received securely."
sleep 2

echo "[*] Bob sends a file to Alice..."
echo "Confidential server logs" > secret_file.txt
bash client/send_file.sh bob alice secret_file.txt
sleep 2

echo "======================================"
echo "        Demo Complete!"
echo "======================================"
echo "Check alice_client.log and bob_client.log to see the decrypted messages!"
echo ""
echo "Output of bob_client.log:"
cat bob_client.log
echo ""
echo "Output of alice_client.log:"
cat alice_client.log
echo ""

echo "[*] Shutting down..."
kill $ALICE_CLIENT_PID $BOB_CLIENT_PID $SERVER_PID 2>/dev/null
pkill -f "socket_mux.py" || true
rm secret_file.txt
