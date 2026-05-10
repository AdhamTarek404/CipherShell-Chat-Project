# CipherShell Chat — Product Requirements Document (PRD)

## Real-Time Chat and File Sharing System with End-to-End Encryption

**Project Category:** Cybersecurity / Secure Communications / Systems Programming  
**Difficulty Level:** Advanced  
**Target Audience:** Cybersecurity Students, Systems Engineers  
**Document Version:** 1.0  
**Last Updated:** April 29, 2026

## 1. Overview

### Problem Statement
Traditional messaging systems often rely on centralized trust and may expose plaintext messages at the server layer. This project builds a lightweight, terminal-first, multi-user secure communication system where:

- Messages are transmitted in real-time.
- Files can be shared securely.
- All content is encrypted end-to-end.
- Decryption occurs **only** at recipient side.
- The system supports multiple concurrent users.
- Implementation is primarily **90% Bash scripting** with **10% Python** only where cryptographic or socket orchestration support is necessary.

---

## 2. Primary Goal

Develop a secure Linux-native messaging system emphasizing:

- Secure communications
- Bash automation
- Socket programming
- Cryptography
- Concurrent client handling
- Minimal Python usage

---

# 3. Tech Stack Constraint (MANDATORY)

## Language Distribution

### Bash (90%)
Used for:

- Client launcher
- Server process orchestration
- User authentication scripts
- Session management
- Socket communication wrappers (netcat / socat)
- Key generation via OpenSSL CLI
- Encryption/decryption pipelines
- File transfer automation
- User management
- Logging and monitoring
- Process control for concurrent clients

### Python (10%)
Used ONLY for:

- Lightweight socket multiplexing helper (optional)
- E2EE cryptographic helper wrappers if Bash/OpenSSL becomes insufficient
- Threaded relay prototype (if needed)

No Flask/Django/web frameworks allowed.

---

# 4. Core Features

## 4.1 Real-Time Messaging

Users can:

- Register
- Connect to server
- Join chat session
- Send encrypted messages instantly
- Receive messages in real time

Supported:

- One-to-one messaging
- Group channels (stretch goal)

---

## 4.2 End-to-End Encryption (Mandatory)

### Encryption Model
Hybrid encryption:

## Key Exchange
Use:

- RSA-4096 or ECC keys
- OpenSSL CLI

Each client has:

```bash
private.pem
public.pem
```

---

## Message Encryption Flow

1. Sender generates temporary AES session key.

```bash
openssl rand -base64 32 > aes.key
```

2. Message encrypted:

```bash
openssl enc -aes-256-cbc -salt -in msg.txt -out msg.enc -pass file:aes.key
```

3. AES key encrypted with recipient public key:

```bash
openssl rsautl -encrypt \
-pubin -inkey recipient.pub \
-in aes.key -out key.enc
```

4. Recipient decrypts:

```bash
openssl rsautl -decrypt \
-inkey private.pem \
-in key.enc > aes.key
```

5. Decrypt message:

```bash
openssl enc -d -aes-256-cbc \
-in msg.enc -out msg.txt \
-pass file:aes.key
```

Server never sees plaintext.

---

## 4.3 Secure File Sharing

Supported:

- Documents
- Images
- Binary files

Encrypted before transmission.

Example:

```bash
tar czf payload.tar file.pdf
openssl enc -aes-256-cbc -in payload.tar -out payload.enc
```

Transfer through:

```bash
nc host 9000 < payload.enc
```

---

## 4.4 Concurrent User Support

Support:

Minimum:

- 20 simultaneous users

Target:

- 50 concurrent clients

Handled via:

```bash
socat
netcat
GNU parallel
background processes
named pipes (FIFO)
```

Optional Python threading helper only if needed.

---

# 5. Functional Requirements

## FR-1 User Registration

User can:

- Create username
- Generate key pair
- Store credentials locally

Command:

```bash
./register.sh username
```

---

## FR-2 Login

```bash
./client.sh login username
```

Validates:

- User exists
- Keypair present
- Session initialized

---

## FR-3 Send Encrypted Message

```bash
./send.sh alice "hello"
```

System must:

- Encrypt
- Package
- Send
- Deliver
- Decrypt only at recipient

---

## FR-4 Receive Messages

Listener process:

```bash
./listener.sh
```

Runs continuously.

---

## FR-5 Send File

```bash
./send_file.sh bob secret.pdf
```

Encrypted before transport.

---

## FR-6 Multi-user Chat Server

Start server:

```bash
./server.sh
```

Should:

- Accept connections
- Route ciphertext only
- Handle multiple clients

---

# 6. Non-Functional Requirements

## Security

Must provide:

- E2EE
- Forward secrecy (bonus)
- Private key protection
- No plaintext storage
- No plaintext logs

---

## Performance

Message latency:

< 300 ms local network

File transfer:

1 MB under 3 sec

---

## Reliability

- Reconnect support
- Interrupted transfer recovery
- Graceful client disconnects

---

## Portability

Must run on:

- Ubuntu
- Kali Linux
- Debian
- WSL optional

---

# 7. Architecture

## High-Level Design

```text
+-------------+
| Client A    |
| Bash + E2EE |
+-------------+
      |
 encrypted payload
      |
+----------------+
| Relay Server    |
| sees ciphertext |
+----------------+
      |
 encrypted payload
      |
+-------------+
| Client B    |
| decrypts    |
+-------------+
```

---

## Components

## Server

Files:

```bash
server.sh
router.sh
session_manager.sh
```

---

## Client

```bash
client.sh
send.sh
listener.sh
send_file.sh
```

---

## Crypto

```bash
generate_keys.sh
encrypt.sh
decrypt.sh
```

---

## Optional Python Helpers (10%)

```python
socket_mux.py
crypto_helper.py
```

---

# 8. Suggested Folder Structure

```text
cipher-shell/
├── server/
│   ├── server.sh
│   ├── router.sh
│   └── users.db
│
├── client/
│   ├── client.sh
│   ├── send.sh
│   ├── listener.sh
│   └── send_file.sh
│
├── crypto/
│   ├── generate_keys.sh
│   ├── encrypt.sh
│   └── decrypt.sh
│
├── python/
│   └── socket_mux.py
│
└── tests/
```

---

# 9. Security Threat Model

## Threats

### MITM
Mitigation:

- Public key fingerprints
- Signed key exchange

---

## Replay Attacks
Mitigation:

- Nonce
- Timestamps
- Message IDs

---

## Key Theft
Mitigation:

```bash
chmod 600 private.pem
```

Optional:

Passphrase-protected keys.

---

## Server Compromise
Mitigation:

Server stores only:

- ciphertext
- routing metadata

Never plaintext.

---

# 10. Bash-Centric Tooling Requirements

Mandatory use of:

## Networking

```bash
nc
socat
mkfifo
```

---

## Crypto

```bash
openssl
gpg (optional)
sha256sum
```

---

## Process Management

```bash
trap
jobs
nohup
screen/tmux
```

---

# 11. User Stories

## Student User

As a user,
I want encrypted chatting,
so nobody except recipient reads my messages.

---

As a user,
I want secure file transfer,
so confidential files stay protected.

---

As admin,
I want concurrent clients supported,
so many users communicate at once.

---

# 12. Milestones

## Phase 1
Basic socket chat

Deliverables:

- server.sh
- client.sh
- multi-client relay

---

## Phase 2
E2EE integration

Deliverables:

- RSA keys
- AES encryption
- encrypted messaging

---

## Phase 3
Encrypted file transfer

Deliverables:

- send_file.sh
- transfer recovery

---

## Phase 4
Hardening

Deliverables:

- replay protection
- logging
- security audit

---

# 13. Acceptance Criteria

Project accepted when:

## Messaging

- Users exchange encrypted messages
- Server cannot read messages

---

## File Sharing

- Files encrypted before sending
- Receiver decrypts successfully

---

## Concurrency

- 20+ users operate simultaneously

---

## Bash Ratio

Codebase composition:

```text
>=90% Bash
<=10% Python
```

Measured by:

```bash
cloc .
```

---

# 14. Example Commands

## Start Server

```bash
./server.sh 9000
```

---

## Register User

```bash
./register.sh alice
```

---

## Start Listener

```bash
./listener.sh
```

---

## Send Message

```bash
./send.sh bob "Top Secret"
```

---

## Send File

```bash
./send_file.sh bob evidence.zip
```

---

# 15. Stretch Goals (Optional)

- Double Ratchet protocol inspired mode
- Perfect Forward Secrecy
- Group encrypted rooms
- Onion-routing relay mode
- TUI interface with Bash + dialog/whiptail

---

# 16. Out of Scope

Not included:

- Mobile app
- Browser UI
- Cloud deployment
- Database-heavy backend
- Full Signal clone implementation

---

# 17. Evaluation Rubric

| Area | Weight |
|------|--------|
Security | 35% |
Bash Engineering | 25% |
Concurrency | 20% |
File Transfer | 10% |
Documentation | 10% |

---

# 18. Risks

| Risk | Mitigation |
|------|------------|
OpenSSL misuse | Validate encryption pipeline |
Socket deadlocks | Timeout controls |
Concurrent race conditions | FIFO/process locks |
Key compromise | Passphrase + permissions |

---

# 19. Deliverables

Must submit:

- Source code
- PRD.md
- Architecture diagram
- Threat model report
- Installation guide
- Demo script

---

# 20. Installation Example

```bash
sudo apt install openssl socat netcat
chmod +x *.sh
./server.sh
```

---

# 21. Success Definition

Project is successful if it demonstrates:

✅ Real-time encrypted messaging  
✅ Secure file sharing  
✅ Multi-client concurrency  
✅ Server blindness to plaintext  
✅ 90/10 Bash-Python ratio maintained

---

## Recommended Team Roles

### Member 1
Bash Socket Infrastructure

### Member 2
Encryption & Key Management

### Member 3
File Transfer Security

### Member 4
Testing / Threat Analysis

---

## Final Stack Summary

```text
BASH (90%)
- netcat
- socat
- openssl
- shell automation
- process orchestration

PYTHON (10%)
- optional socket helper
- optional crypto wrapper
```

---

## Project Type

Cybersecurity / Secure Communications / Systems Programming Project

**Difficulty:** Advanced  
**Recommended For:** Cybersecurity Students

