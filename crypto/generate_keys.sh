#!/bin/bash
# generate_keys.sh
# Generates RSA-4096 key pair

USERNAME=$1
if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

mkdir -p ~/.ciphershell/$USERNAME
cd ~/.ciphershell/$USERNAME || exit 1

if [ -f private.pem ] && [ -f public.pem ]; then
    echo "Keys already exist for $USERNAME"
    exit 0
fi

echo "Generating RSA-4096 key pair..."
# Set umask to 077 to ensure private.pem is created with 600 permissions directly
umask 077
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:4096
# Reset umask
umask 022
chmod 600 private.pem
openssl rsa -pubout -in private.pem -out public.pem
echo "Key pair generated successfully in ~/.ciphershell/$USERNAME"
