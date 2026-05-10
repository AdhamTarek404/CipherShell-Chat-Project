#!/bin/bash
# encrypt.sh <recipient_public_key_file> <plaintext_file> <output_file>

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <recipient_public_key> <plaintext_file> <output_file>"
    exit 1
fi

RECIPIENT_PUB=$(realpath "$1")
PLAINTEXT=$(realpath "$2")
OUTPUT=$(realpath "$3")

TEMP_DIR=$(mktemp -d)
if [ ! -d "$TEMP_DIR" ]; then
    echo "Error creating temp directory"
    exit 1
fi

# 1. Generate random AES key
openssl rand -base64 32 > "$TEMP_DIR/aes.key"

# 2. Encrypt plaintext with AES key (use pbkdf2 to avoid warnings on newer openssl)
openssl enc -aes-256-cbc -salt -pbkdf2 -in "$PLAINTEXT" -out "$TEMP_DIR/payload.enc" -pass file:"$TEMP_DIR/aes.key"

# 3. Encrypt AES key with recipient's public key
# Using rsautl as per PRD (pkeyutl is the modern alternative)
openssl rsautl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc" 2>/dev/null || \
openssl pkeyutl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc"

# 4. Package them together
cd "$TEMP_DIR" || exit 1
tar czf package.tar key.enc payload.enc

# 5. Base64 encode the package to output file
cd - > /dev/null
# macOS base64 doesn't support -w 0, so we handle both Linux and macOS robustly
base64 -w 0 "$TEMP_DIR/package.tar" > "$OUTPUT" 2>/dev/null || base64 "$TEMP_DIR/package.tar" | tr -d '\n' > "$OUTPUT"

# Cleanup
rm -rf "$TEMP_DIR"
