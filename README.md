<div align="center">

# 🚀 CipherShell Chat

**A Secure, Asynchronous, Terminal-Based Chat Application**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Server-Python%203-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![OpenSSL](https://img.shields.io/badge/Crypto-OpenSSL-721412?logo=openssl&logoColor=white)](https://www.openssl.org/)

CipherShell Chat is a lightweight yet robust command-line chat application built for engineers who demand privacy. It leverages a hybrid encryption model (RSA-4096 + AES-256-CBC) to guarantee end-to-end security for messages and files, routed through a blazing-fast Python AsyncIO socket multiplexer.

</div>

---

## ✨ Features

- **🔐 End-to-End Encryption (E2EE):** Hybrid cryptography using OpenSSL. AES-256-CBC for payloads, secured by RSA-4096 key pairs.
- **⚡ Async Relay Server:** Highly concurrent Python `asyncio` server handling TCP socket multiplexing with ease.
- **📁 Secure File Transfer:** Transfer documents and binaries securely over the chat with automatic payload chunking and extraction safety.
- **🖥️ True Terminal Experience:** Built entirely with Bash, Netcat (`nc`), and Named Pipes (FIFOs) for standard UNIX philosophy integration.
- **🛡️ Hardened IPC:** Strict `umask 077` permissions ensure local inter-process communication remains private.
- **🐧🍏 Cross-Platform:** Engineered to run seamlessly on both Linux and macOS environments.

---

## 🏗 Architecture Overview

The system consists of three decoupled layers:

1. **The Server Layer (`server/`)**: A stateless Python `asyncio` relay. It does not read or decrypt messages; it solely maps `LOGIN <username>` to a socket and routes `SEND <recipient> <payload>` commands.
2. **The Cryptography Layer (`crypto/`)**: A collection of isolated Bash scripts leveraging OpenSSL for RSA key generation, and hybrid encryption/decryption of data packages (tarballed AES keys + ciphertexts).
3. **The Client Layer (`client/`)**: Manages the user state, background listening via `nc`, and interactive shell UI. It uses UNIX FIFOs to communicate with the background connection asynchronously.

---

## ⚙️ Installation

### Prerequisites
- **Bash** (v4.0+)
- **Python** (v3.7+ for the server)
- **OpenSSL** (v1.1.1 or v3.0+)
- **Netcat** (`nc`)

### Setup

Clone the repository and make the scripts executable:

```bash
# Clone the repository
git clone https://github.com/yourusername/ciphershell-chat.git
cd ciphershell-chat

# Make all bash scripts executable
chmod +x ciphershell.sh demo.sh client/*.sh crypto/*.sh server/*.sh
```

---

## ▶️ Usage

CipherShell provides a centralized launcher for an interactive experience.

### Starting the Launcher
```bash
./ciphershell.sh
```

### Typical Workflow

1. **Start Server**: Select `1` in the menu to boot the background relay server (default port `9000`).
2. **Register Users**: Select `2` to register Alice and Bob. This generates their RSA-4096 keys locally and registers their public keys to the server database.
3. **Login**: Select `3` for Alice, and open a new terminal to Select `3` for Bob.
4. **Chat**: Select `4` to send messages, or `5` to send encrypted files!

> **Quick Start:** You can see the system in action instantly by running the automated demo script from the launcher menu (Option `6`) or running `./demo.sh`.

---

## 🔧 Configuration

All configurations are handled dynamically through the interactive launcher. However, under the hood:

- **Key Storage:** `~/.ciphershell/<username>/` (Contains `private.pem` and `public.pem`)
- **Server DB:** `server/users.db/` (Contains public keys of registered users)
- **Port:** The server defaults to TCP `9000`.

---

## 📁 Project Structure

```text
ciphershell-chat/
├── ciphershell.sh         # Interactive UI / Launcher
├── demo.sh                # Automated E2E testing script
├── client/                # Client-side logic
│   ├── client.sh          # Manages the TCP connection & FIFOs
│   ├── listener.sh        # Background job to decrypt & print incoming data
│   ├── register.sh        # Handles key generation & registration
│   ├── send.sh            # Encrypts and sends text messages
│   └── send_file.sh       # Encrypts and sends files
├── crypto/                # Cryptographic core
│   ├── decrypt.sh         # Base64 decode -> AES Decrypt -> RSA Decrypt
│   ├── encrypt.sh         # RSA Encrypt -> AES Encrypt -> Base64 encode
│   └── generate_keys.sh   # Generates RSA-4096 key pairs
└── server/                # Relay server
    ├── server.sh          # Server boot script
    └── socket_mux.py      # Python asyncio TCP multiplexer
```

---

## 📡 Protocol & IPC Documentation

### Server Protocol
The server speaks a highly simplified plain-text protocol. Note that *only the routing commands* are plaintext; the payload is always encrypted base64 data.

- **Authenticate:** `LOGIN <username>\n`
- **Route Message:** `SEND <recipient> <base64_payload>\n`
- **Server Response:** `FROM <sender> <base64_payload>\n` or `ERROR <message>\n`

### Local Inter-Process Communication (IPC)
The client connects to the server using Netcat (`nc`). To allow asynchronous sending and receiving without dropping the connection, `client.sh` creates isolated UNIX named pipes (FIFOs) under `~/.ciphershell/<username>/pipes/in` and `pipes/out` with strict `077` umask permissions.

---

## 🛠 Tech Stack

| Component | Technology | Description |
| :--- | :--- | :--- |
| **Backend Relay** | Python 3 | `asyncio` for non-blocking I/O. |
| **Client / CLI** | Bash | Lightweight, ubiquitous, heavily reliant on standard UNIX tools (`tar`, `nc`, `mkfifo`). |
| **Cryptography** | OpenSSL | Hybrid RSA/AES implementation with PBKDF2 key derivation. |

---

## 🔍 Code Quality & Architecture Decisions

- **Hybrid Encryption Design:** AES-256-CBC is used for the payload to support large file transfers efficiently. The AES key is then encrypted with the recipient's RSA-4096 public key using `openssl pkeyutl/rsautl`.
- **Security Hardening:** 
  - `umask 077` is enforced during key and FIFO generation to prevent local privilege escalation or eavesdropping.
  - `-pbkdf2` is enforced in OpenSSL to guarantee robust key derivation algorithms and suppress warnings on modern systems.
- **Binary Safety:** File extraction parsing `head` and `tail` logic is heavily fortified to handle carriage returns (`\r`) and binary payloads without corruption.

---

## 🧪 Testing

An automated E2E workflow is included in the repository.

To validate the installation, cryptography algorithms, and server socket multiplexing, run:
```bash
./demo.sh
```
This script will spin up a local server, register two mock users (Alice and Bob), simulate an encrypted conversation, transfer a mock file, and tear down the infrastructure automatically.

---

## 🤝 Contributing

We adhere to the UNIX philosophy: write programs that do one thing and do it well.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📌 Roadmap / Future Improvements

- [ ] **Daemonization:** Convert the Python script into a proper systemd service.
- [ ] **Forward Secrecy:** Implement Diffie-Hellman key exchanges for perfect forward secrecy.
- [ ] **Group Chats:** Expand the socket multiplexer to support multi-cast messaging.
- [ ] **Read Receipts:** Add protocol acknowledgments.
