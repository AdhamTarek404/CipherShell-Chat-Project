#!/bin/bash
# register.sh <username>

if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

USERNAME=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

echo "Registering user: $USERNAME"
bash "$ROOT_DIR/crypto/generate_keys.sh" "$USERNAME"

mkdir -p "$ROOT_DIR/server/users.db"
cp ~/.ciphershell/$USERNAME/public.pem "$ROOT_DIR/server/users.db/${USERNAME}.pub"
echo "User $USERNAME registered. Public key saved to server/users.db/${USERNAME}.pub"
