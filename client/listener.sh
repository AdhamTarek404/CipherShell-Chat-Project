#!/bin/bash
# listener.sh <input_fifo>

INPUT_FIFO=$1
USERNAME=$2
if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <input_fifo> <username>"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

while read -r line; do
    if [[ $line == ERROR* ]]; then
        echo -e "\n[Server Error]: ${line#ERROR }"
        continue
    fi
    
    sender=$(echo "$line" | cut -d' ' -f2)
    payload=$(echo "$line" | cut -d' ' -f3-)
    
    if [ -z "$payload" ]; then continue; fi
    
    TEMP_B64=$(mktemp)
    TEMP_OUT=$(mktemp)
    echo "$payload" > "$TEMP_B64"
    
    bash "$ROOT_DIR/crypto/decrypt.sh" ~/.ciphershell/$USERNAME/private.pem "$TEMP_B64" "$TEMP_OUT" 2>/dev/null
    
    if [ ! -f "$TEMP_OUT" ] || [ ! -s "$TEMP_OUT" ]; then
        echo -e "\n[Error]: Failed to decrypt message from $sender."
        rm -f "$TEMP_B64" "$TEMP_OUT"
        continue
    fi
    
    msg_type=$(head -c 5 "$TEMP_OUT")
    if [ "$msg_type" = "MSG: " ]; then
        content=$(tail -c +6 "$TEMP_OUT")
        echo -e "\n[Message from $sender]: $content"
    elif [ "$msg_type" = "FILE:" ]; then
        raw_filename=$(head -n 1 "$TEMP_OUT" | cut -c 6- | tr -d '\r')
        # Sanitize filename to prevent directory traversal
        filename=$(basename "$raw_filename")
        if [ -z "$filename" ] || [ "$filename" = "." ] || [ "$filename" = ".." ]; then
            filename="received_file_$(date +%s)"
        fi
        
        # Prevent overwriting
        if [ -f "$filename" ]; then
            filename="${filename}_$(date +%s)"
        fi
        
        # We save to current working directory
        tail -n +2 "$TEMP_OUT" > "$filename"
        echo -e "\n[File received from $sender]: Saved as $filename"
    else
        echo -e "\n[Message from $sender]: $(cat "$TEMP_OUT")"
    fi
    
    rm -f "$TEMP_B64" "$TEMP_OUT"
done < "$INPUT_FIFO"
