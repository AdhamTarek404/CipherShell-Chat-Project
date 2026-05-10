#!/bin/bash
# ciphershell.sh - Interactive launcher for CipherShell Chat

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

show_menu() {
    clear
    echo "=========================================="
    echo "        CipherShell Chat Launcher         "
    echo "=========================================="
    echo "1) Start Server (Background)"
    echo "2) Register New User"
    echo "3) Login / Start Listener"
    echo "4) Send Message"
    echo "5) Send File"
    echo "6) Run Automated Demo"
    echo "7) Exit"
    echo "=========================================="
    echo -n "Select an option [1-7]: "
}

while true; do
    show_menu
    read -r choice
    case $choice in
        1)
            echo -n "Enter port [default: 9000]: "
            read -r port
            port=${port:-9000}
            bash "$SCRIPT_DIR/server/server.sh" "$port" > server.log 2>&1 &
            SERVER_PID=$!
            echo "Server started in background on port $port. Check server.log."
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        2)
            echo -n "Enter username: "
            read -r username
            if [ -n "$username" ]; then
                bash "$SCRIPT_DIR/client/register.sh" "$username"
            fi
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        3)
            echo -n "Enter username to login: "
            read -r username
            echo -n "Enter server host [default: 127.0.0.1]: "
            read -r host
            host=${host:-127.0.0.1}
            echo -n "Enter server port [default: 9000]: "
            read -r port
            port=${port:-9000}
            
            if [ -n "$username" ]; then
                echo "Logging in... Press Ctrl+C to exit."
                bash "$SCRIPT_DIR/client/client.sh" login "$username" "$host" "$port"
            fi
            ;;
        4)
            echo -n "Enter your username (sender): "
            read -r sender
            echo -n "Enter recipient username: "
            read -r recipient
            echo -n "Enter message: "
            read -r message
            if [ -n "$sender" ] && [ -n "$recipient" ] && [ -n "$message" ]; then
                bash "$SCRIPT_DIR/client/send.sh" "$sender" "$recipient" "$message"
            fi
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        5)
            echo -n "Enter your username (sender): "
            read -r sender
            echo -n "Enter recipient username: "
            read -r recipient
            echo -n "Enter file path: "
            read -r filepath
            if [ -n "$sender" ] && [ -n "$recipient" ] && [ -n "$filepath" ]; then
                bash "$SCRIPT_DIR/client/send_file.sh" "$sender" "$recipient" "$filepath"
            fi
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        6)
            bash "$SCRIPT_DIR/demo.sh"
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
        7)
            echo "Exiting CipherShell."
            if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
                echo -n "Kill background server (PID $SERVER_PID)? [y/N]: "
                read -r kill_srv
                if [[ "$kill_srv" =~ ^[Yy]$ ]]; then
                    kill "$SERVER_PID" 2>/dev/null
                    pkill -P "$SERVER_PID" 2>/dev/null
                    echo "Server stopped."
                fi
            fi
            exit 0
            ;;
        *)
            echo "Invalid option."
            sleep 1
            ;;
    esac
done
