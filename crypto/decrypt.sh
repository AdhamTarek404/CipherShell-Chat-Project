#!/bin/bash
set -e
# decrypt.sh <private_key_file> <input_b64_file> <output_plaintext_file>

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <private_key_file> <input_b64_file> <output_plaintext_file>"
    exit 1
fi

PRIVATE_KEY=$(realpath "$1")
INPUT=$(realpath "$2")
OUTPUT=$(realpath "$3")

TEMP_DIR=$(mktemp -d)
if [ ! -d "$TEMP_DIR" ]; then
    echo "Error creating temp directory"
    exit 1
fi
cd "$TEMP_DIR" || exit 1

# 1. Base64 decode
base64 -d "$INPUT" > package.tar 2>/dev/null || base64 -D "$INPUT" > package.tar 2>/dev/null || base64 --decode "$INPUT" > package.tar

# 2. Extract
tar xzf package.tar

# 3. Decrypt AES key with private key
openssl rsautl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key 2>/dev/null || \
openssl pkeyutl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key

# 4. Decrypt payload
openssl enc -d -aes-256-cbc -pbkdf2 -in payload.enc -out "$OUTPUT" -pass file:aes.key

# Cleanup
cd - > /dev/null
rm -rf "$TEMP_DIR"
