#!/bin/bash
# server.sh - Starts the CipherShell chat server

# Change to the directory where the script is located
cd "$(dirname "$0")" || exit 1

PORT=${1:-9000}

# Create a directory to store public keys if we decide to use the server as a key store
mkdir -p users.db

echo "Starting CipherShell Server on port $PORT..."
echo "Python script will handle socket multiplexing..."

# Run the python helper
python3 socket_mux.py "$PORT"
