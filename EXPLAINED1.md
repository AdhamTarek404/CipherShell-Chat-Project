# CipherShell Chat — Complete Deep Dive

> Every concept, every file, every line, every flag, every symbol — explained.
> Cross-file connections are marked like: `→ FILE line N`.

---

## Table of Contents

1. [The Big Idea](#1-the-big-idea)
2. [Background Concepts You Need First](#2-background-concepts-you-need-first)
   - [What is TCP?](#what-is-tcp)
   - [What is netcat (nc)?](#what-is-netcat-nc)
   - [What is a FIFO / Named Pipe?](#what-is-a-fifo--named-pipe)
   - [What is RSA?](#what-is-rsa)
   - [What is AES?](#what-is-aes)
   - [What is Hybrid Encryption?](#what-is-hybrid-encryption)
   - [What is Base64?](#what-is-base64)
   - [What is asyncio?](#what-is-asyncio)
   - [What are File Descriptors?](#what-are-file-descriptors)
3. [System Architecture](#3-system-architecture)
4. [How a Message Travels — Full End-to-End Flow](#4-how-a-message-travels--full-end-to-end-flow)
5. [Hybrid Encryption — Visual Breakdown](#5-hybrid-encryption--visual-breakdown)
6. [The FIFO Trick — How Multiple Scripts Share One Connection](#6-the-fifo-trick--how-multiple-scripts-share-one-connection)
7. [File-by-File: Every Line Explained](#7-file-by-file-every-line-explained)
   - [ciphershell.sh — The Launcher](#ciphershellsh--the-launcher)
   - [demo.sh — The Automated Test](#demosh--the-automated-test)
   - [server/server.sh — The Server Launcher](#serverserversh--the-server-launcher)
   - [server/socket_mux.py — The Relay Server](#serversocket_muxpy--the-relay-server)
   - [client/register.sh — User Registration](#clientregistersh--user-registration)
   - [client/client.sh — Login & Connection Manager](#clientclientsh--login--connection-manager)
   - [client/listener.sh — The Inbox](#clientlistenersh--the-inbox)
   - [client/send.sh — Send a Message](#clientsendsh--send-a-message)
   - [client/send_file.sh — Send a File](#clientsend_filesh--send-a-file)
   - [crypto/generate_keys.sh — Key Generation](#cryptogenerate_keyssh--key-generation)
   - [crypto/encrypt.sh — Encryption Pipeline](#cryptoencryptsh--encryption-pipeline)
   - [crypto/decrypt.sh — Decryption Pipeline](#cryptodecryptsh--decryption-pipeline)
8. [Cross-File Connection Map](#8-cross-file-connection-map)
9. [The Post Office Analogy](#9-the-post-office-analogy)
10. [Creative Extension: Network Key Exchange](#10-creative-extension-network-key-exchange)

---

## 1. The Big Idea

CipherShell Chat is a **terminal-based encrypted chat system** written almost entirely in Bash (~90%) with a small Python server (~10%).

**Core principle:** Two users can send messages and files over a TCP network, and the server in the middle **never sees the actual content**. It only ever receives and forwards scrambled, unreadable encrypted blobs. This property — where even the infrastructure operator cannot read your messages — is called **End-to-End Encryption (E2EE)**.

**What tools does it use?**
- `openssl` — for generating RSA keys and doing AES/RSA encryption/decryption
- `netcat (nc)` — for opening TCP connections
- `bash` named pipes (FIFOs) — for letting multiple scripts share one TCP connection
- `tar` + `base64` — for bundling and encoding the encrypted payload
- `python3` with `asyncio` — for the multi-client TCP relay server

**What makes this interesting as a project:**
- No web frameworks, no external libraries beyond what ships with Linux/macOS
- All cryptography is done with command-line `openssl` calls orchestrated by Bash
- The challenge of "how do multiple scripts share one TCP connection" is solved with a clever FIFO trick

---

## 2. Background Concepts You Need First

Before reading the code, these are the underlying technologies and ideas the project is built on.

---

### What is TCP?

**TCP (Transmission Control Protocol)** is one of the fundamental protocols of the internet. When two programs connect over TCP:
- A **server** listens on a port number (like `9000`) waiting for connections
- A **client** connects to the server's IP address and port
- Both sides get a **bidirectional stream**: each can send bytes and receive bytes simultaneously
- TCP guarantees that bytes arrive **in order** and **without corruption**

In this project, the Python server listens on port `9000`. Each chat client connects to it using `netcat`.

---

### What is netcat (nc)?

`netcat` (command: `nc`) is a utility that opens a raw TCP connection. It's often called "the Swiss army knife of networking."

When you run:
```bash
nc 127.0.0.1 9000
```
It connects to port 9000 on localhost. After that:
- Anything you type goes to the server
- Anything the server sends appears in your terminal

In this project, `nc` is used with input/output redirected to named pipes (FIFOs) so Bash scripts can control what gets sent and received.

---

### What is a FIFO / Named Pipe?

A **FIFO (First In, First Out)** is a special file on the filesystem that acts as a pipe between processes:
- One process **writes** to it
- Another process **reads** from it
- Reading blocks until data is written; writing blocks until someone is reading
- Data flows in one direction only (hence you need two FIFOs: one for each direction)

Unlike regular pipes (`|`), a FIFO has a **name in the filesystem** (e.g., `~/.ciphershell/alice/pipes/in`), which means two completely separate, unrelated processes can use it — they just both open the same filename.

Created with: `mkfifo /path/to/file`

In this project, FIFOs let `send.sh` (a separate script) inject data into `netcat`'s stdin, which is already running inside `client.sh`.

---

### What is RSA?

**RSA** is a **public-key (asymmetric) encryption algorithm** invented in 1977, still widely used today.

Key idea: there are **two mathematically linked keys**:
- **Public key** — you share this with everyone. Anyone can use it to **encrypt** a message to you.
- **Private key** — you keep this secret. Only it can **decrypt** messages encrypted with the paired public key.

The math is based on the fact that multiplying two large prime numbers is easy, but factoring the result back into those primes is computationally infeasible (for large enough numbers).

**Limitation:** RSA can only encrypt data smaller than the key size. A 4096-bit key can encrypt at most ~500 bytes. This makes it unsuitable for encrypting arbitrary files or messages directly.

This project uses **RSA-4096**, meaning 4096-bit keys — considered very strong.

---

### What is AES?

**AES (Advanced Encryption Standard)** is a **symmetric** encryption algorithm — meaning the same key is used for both encrypting and decrypting.

Key properties:
- Can encrypt data of **any size**
- Extremely fast (often hardware-accelerated)
- Used in **AES-256-CBC** mode here:
  - **256** = 256-bit key (very strong)
  - **CBC** = Cipher Block Chaining — each block of data is XORed with the previous encrypted block before being encrypted, which means identical plaintext blocks produce different ciphertext

**Limitation:** Both the sender and receiver need to have the same secret key. Getting that key to the recipient securely is the "key exchange problem."

---

### What is Hybrid Encryption?

Hybrid encryption solves the limitations of both RSA and AES:

```
Problem with RSA alone:   Can't encrypt large data
Problem with AES alone:   How do you securely share the key with the recipient?

Solution — Hybrid:
  1. Generate a random AES key (just for this one message)
  2. Encrypt the actual message with AES (fast, any size)
  3. Encrypt the AES key with the recipient's RSA public key (small, RSA can handle it)
  4. Send both: the AES-encrypted message + the RSA-encrypted AES key
  5. Recipient uses their RSA private key to decrypt the AES key
  6. Then uses the AES key to decrypt the message
```

This is exactly what HTTPS/TLS (the protocol behind every `https://` website) does. This project implements it from scratch in Bash.

---

### What is Base64?

**Base64** is an encoding (not encryption!) that converts arbitrary binary data into plain printable ASCII text.

**Why is it needed here?**
- The encrypted output of `openssl enc` is raw binary bytes — it can contain any byte value including `0x00`, `0x0A` (newline), etc.
- The chat protocol uses **newlines to separate messages** (`readline()` on the server)
- If the encrypted payload contains a newline byte, the server would think the message ended there — breaking everything

Base64 converts all bytes to characters from the set `A-Z`, `a-z`, `0-9`, `+`, `/`, and `=`. No newlines. Safe to transmit as a single line.

The tradeoff: base64 output is ~33% larger than the input.

---

### What is asyncio?

Python's `asyncio` is a framework for writing **concurrent** programs using a single thread and an **event loop**.

Traditional threading: one thread per connection (each thread blocks waiting for data from its client).

asyncio: one event loop handles all connections. When a coroutine is waiting for data (`await reader.readline()`), the event loop switches to handling other connections. When data arrives, it switches back.

`async def` defines a coroutine (a function that can pause and resume).
`await` pauses the coroutine and gives control back to the event loop.

This is why the server can handle many clients simultaneously without using threads — it never blocks, it just `await`s.

---

### What are File Descriptors?

Every process in Linux/Unix has a table of **file descriptors (FDs)** — numbered references to open files, sockets, pipes, or terminals.

Three are open by default in every process:
- **FD 0** = stdin (keyboard input)
- **FD 1** = stdout (terminal output)
- **FD 2** = stderr (error output)

You can open additional ones (FD 3, 4, 5, ...) with `exec`.

In this project:
```bash
exec 3> ~/.ciphershell/$USERNAME/pipes/in
```
Opens the `pipes/in` FIFO for writing on **FD 3**. Any script can then write to it with `>&3` or `echo ... >&3`. The FIFO stays open as long as this FD stays open — which is what keeps `netcat` running between messages.

Redirection operators:
- `>` = redirect stdout to a file (overwrite)
- `>>` = redirect stdout to a file (append)
- `2>` = redirect stderr
- `2>&1` = redirect stderr to wherever stdout currently goes
- `>&3` = redirect stdout to FD 3
- `< file` = use file as stdin
- `&> file` = redirect both stdout and stderr to file

---

## 3. System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          ALICE'S MACHINE                             │
│                                                                      │
│  ~/.ciphershell/alice/                                               │
│    ├── private.pem   (RSA-4096 private key — NEVER leaves machine)   │
│    ├── public.pem    (copied to server/users.db/alice.pub)           │
│    └── pipes/                                                        │
│         ├── in  (FIFO) ← send.sh writes "SEND bob <blob>" here      │
│         └── out (FIFO) ← listener.sh reads "FROM bob <blob>" here   │
│                                                                      │
│  server/users.db/                                                    │
│    ├── alice.pub  ← Alice's public key (for others to encrypt to her)│
│    └── bob.pub    ← Bob's public key (Alice reads this to send to Bob│
│                                                                      │
│  [client.sh]                                                         │
│    opens FD 3 → pipes/in                                             │
│    starts: nc 127.0.0.1 9000 < pipes/in > pipes/out                 │
│    starts: listener.sh pipes/out alice (background)                  │
│                                                                      │
│  [send.sh] ──writes "SEND bob <base64blob>"──► pipes/in (FIFO)      │
│                   ▼ netcat reads from pipes/in                       │
│                   ▼ sends bytes over TCP                             │
└──────────────────────────────────────────────────────────────────────┘
                              │ TCP port 9000
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  SERVER — socket_mux.py (Python asyncio)             │
│                                                                      │
│   clients = {                                                        │
│     "alice": <StreamWriter for Alice's TCP connection>,              │
│     "bob":   <StreamWriter for Bob's TCP connection>                 │
│   }                                                                  │
│                                                                      │
│   Protocol:                                                          │
│     Client → Server:  "LOGIN alice\n"                                │
│     Client → Server:  "SEND bob <base64blob>\n"                      │
│     Server → Client:  "FROM alice <base64blob>\n"                    │
│     Server → Client:  "ERROR bob is not online\n"                   │
│                                                                      │
│   The server NEVER decrypts anything.                                │
│   It only reads the label ("bob") and forwards the sealed envelope.  │
└──────────────────────────────────────────────────────────────────────┘
                              │ TCP port 9000
                              ▼
                        BOB'S MACHINE
                 (exact mirror of Alice's setup)
              pipes/out → listener.sh → decrypt.sh → display
```

---

## 4. How a Message Travels — Full End-to-End Flow

This is the complete step-by-step journey of Alice sending "Hello Bob!" to Bob:

```
── SENDING SIDE (Alice) ──────────────────────────────────────────────

Step 1: Alice runs send.sh
  Input arguments: sender=alice, recipient=bob, message="Hello Bob!"
  Creates temp file with content: "MSG: Hello Bob!"
  (the "MSG: " prefix is how listener.sh knows this is a text message)

Step 2: send.sh calls encrypt.sh with bob's public key
  encrypt.sh generates a random AES-256 key
  encrypt.sh AES-encrypts "MSG: Hello Bob!" → payload.enc
  encrypt.sh RSA-encrypts the AES key with bob.pub → key.enc
  encrypt.sh: tar czf package.tar key.enc payload.enc
  encrypt.sh: base64 encodes package.tar → one long string (no newlines)
  Result stored in TEMP_B64 file

Step 3: send.sh writes to Alice's FIFO (pipes/in)
  Writes: "SEND bob H4sI...base64...blob==\n"

── TRANSPORT ─────────────────────────────────────────────────────────

Step 4: netcat (already running, started by client.sh) reads from pipes/in
  Reads the line "SEND bob H4sI...blob==\n"
  Sends those bytes over the TCP connection to the server

Step 5: Server (socket_mux.py) receives the line
  Parses it: command=SEND, recipient=bob, payload=H4sI...blob==
  Looks up "bob" in the clients{} dictionary
  Finds Bob's StreamWriter (his TCP connection)
  Formats new message: "FROM alice H4sI...blob==\n"
  Writes that to Bob's TCP connection

Step 6: Bob's netcat receives the bytes from the server
  Reads "FROM alice H4sI...blob==\n" from the TCP socket
  Writes it to Bob's pipes/out FIFO

── RECEIVING SIDE (Bob) ──────────────────────────────────────────────

Step 7: Bob's listener.sh (running in background since login) reads from pipes/out
  Gets line: "FROM alice H4sI...blob=="
  Parses it: sender=alice, payload=H4sI...blob==
  Writes payload to a temporary file (TEMP_B64)

Step 8: listener.sh calls decrypt.sh with Bob's private key
  decrypt.sh: base64 -d TEMP_B64 → package.tar
  decrypt.sh: tar xzf package.tar → key.enc + payload.enc
  decrypt.sh: openssl rsautl -decrypt with bob's private.pem → aes.key
  decrypt.sh: openssl enc -d -aes-256-cbc -pbkdf2 → decrypted plaintext

Step 9: listener.sh reads the decrypted output
  Reads first 5 bytes: "MSG: "
  Recognizes it as a text message
  Reads remaining bytes: "Hello Bob!"
  Prints: "[Message from alice]: Hello Bob!"
```

---

## 5. Hybrid Encryption — Visual Breakdown

```
                        ┌─────────────────────────────────────────────┐
                        │         encrypt.sh is called with:          │
                        │   arg1: bob.pub (recipient's public key)     │
                        │   arg2: plaintext file (e.g. "MSG: Hi Bob") │
                        │   arg3: output file (will hold base64 blob) │
                        └───────────────┬─────────────────────────────┘
                                        │
                                        ▼
                         ┌─────────────────────────────┐
                         │  openssl rand -base64 32     │
                         │  Generate a RANDOM AES key   │
                         │  e.g. "K7mNpQ3r9sLwXv2A..."  │
                         │  Stored in: TEMP_DIR/aes.key │
                         └──────────────┬──────────────┘
                                        │
                          ┌─────────────┴──────────────┐
                          │                            │
                          ▼                            ▼
         ┌─────────────────────────┐   ┌───────────────────────────────┐
         │  openssl enc            │   │  openssl rsautl -encrypt      │
         │  -aes-256-cbc           │   │  -pubin -inkey bob.pub        │
         │  -in plaintext          │   │  -in aes.key                  │
         │  -out payload.enc       │   │  -out key.enc                 │
         │  -pass file:aes.key     │   │                               │
         │                         │   │  RSA-locks the AES key with   │
         │  AES-encrypts the       │   │  Bob's public key. Only Bob's │
         │  actual content.        │   │  private.pem can unlock it.   │
         │  Any size works.        │   │  Max ~500 bytes — fine since  │
         └───────────┬─────────────┘   │  aes.key is small.            │
                     │                 └───────────────┬───────────────┘
                     │                                 │
                     └──────────────┬──────────────────┘
                                    │
                                    ▼
                      ┌─────────────────────────────┐
                      │  tar czf package.tar         │
                      │    key.enc payload.enc        │
                      │                              │
                      │  Bundles both files into     │
                      │  one compressed archive.     │
                      └─────────────┬───────────────┘
                                    │
                                    ▼
                      ┌─────────────────────────────┐
                      │  base64 -w 0 package.tar     │
                      │                              │
                      │  Converts binary archive to  │
                      │  printable text. No newlines │
                      │  so it fits in one protocol  │
                      │  line.                       │
                      └─────────────┬───────────────┘
                                    │
                                    ▼
              "H4sIAAAAAAAAA+2OMQrCQBCGd/c..." (one very long line)
              This is what travels over the network.
              The server sees ONLY this — completely opaque to it.
```

**On the receiving end (`decrypt.sh`) — exact reverse:**
```
  base64 -d blob → package.tar
  tar xzf → key.enc + payload.enc
  rsautl -decrypt with private.pem → aes.key
  openssl enc -d → original plaintext
```

---

## 6. The FIFO Trick — How Multiple Scripts Share One Connection

This is the cleverest architectural decision in the project. Here is the problem and the solution in detail.

**The Problem:**
```
client.sh opens a TCP connection with netcat and must keep it open
  (netcat is running continuously, waiting for data)

send.sh needs to inject data into that same connection
  (but send.sh is a completely separate process, started later)

How can send.sh write into netcat's stdin?
```

**Why a normal pipe doesn't work:**
A shell pipe (`cmd1 | cmd2`) only works between commands run at the same time in the same shell statement. You can't pipe into a command that's already running.

**Why a regular file doesn't work:**
If netcat read from a regular file, it would reach the end of the file and exit. You'd need to restart it for every message.

**The FIFO solution:**
```
mkfifo ~/.ciphershell/alice/pipes/in
mkfifo ~/.ciphershell/alice/pipes/out

# In client.sh:
exec 3> ~/.ciphershell/alice/pipes/in        ← Opens the FIFO on FD 3, keeps it open
nc host port < pipes/in > pipes/out &        ← nc reads from FIFO, writes to FIFO
echo "LOGIN alice" >&3                       ← Writes through FD 3 into the FIFO

# Later, in send.sh (a completely separate process):
echo "SEND bob <blob>" > ~/.ciphershell/alice/pipes/in
  ↑ This works because the FIFO exists as a filesystem path,
    so ANY process that knows the path can write to it
```

**Why `exec 3> pipes/in` is critical:**
```
Without it:
  send.sh opens pipes/in, writes "SEND ...", then closes
  → FIFO closes (no more writers)
  → netcat sees EOF on its stdin
  → netcat exits
  → TCP connection closes!

With it:
  client.sh holds the FIFO open permanently on FD 3
  Even when send.sh finishes and closes its write handle,
  FD 3 is still open → FIFO stays open → netcat keeps running
```

**Full data flow diagram:**
```
send.sh process:
  writes "SEND bob <blob>\n" to pipes/in (FIFO file)
         │
         ▼ (FIFO buffers the bytes)
         │
client.sh's netcat process:
  reads from pipes/in (FIFO)
  sends bytes over TCP socket to server
         │
         ▼ (bytes travel over the network)
         │
server (socket_mux.py):
  receives "SEND bob <blob>\n"
  looks up bob in clients{}
  writes "FROM alice <blob>\n" to bob's TCP socket
         │
         ▼ (bytes travel back over the network to Bob's machine)
         │
Bob's client.sh's netcat process:
  receives "FROM alice <blob>\n" from TCP socket
  writes it to pipes/out (FIFO)
         │
         ▼ (FIFO buffers the bytes)
         │
Bob's listener.sh process:
  reads "FROM alice <blob>\n" from pipes/out
  calls decrypt.sh
  prints "[Message from alice]: ..."
```

---

## 7. File-by-File: Every Line Explained

---

### `ciphershell.sh` — The Launcher

**Role:** The front door. An interactive menu that wraps all other scripts. The user never needs to remember any command syntax — they just run this one file.

---

```bash
#!/bin/bash
```
**Line 1 — The shebang line.**

When you run `./ciphershell.sh`, the OS reads the first two bytes. If they are `#!`, it treats the rest of the line as the path to the interpreter. So the OS runs `/bin/bash` and passes this file to it as a script.

Without this line, the OS would try to run the file with whatever the default shell is (often `sh`, not `bash`). `sh` doesn't support all Bash features (`[[`, `$BASHPID`, arrays, etc.), which could cause failures.

---

```bash
# ciphershell.sh - Interactive launcher for CipherShell Chat
```
**Line 2 — A comment.**

In Bash, `#` starts a comment. Everything after it on the same line is ignored by the interpreter. This is purely for humans reading the code.

---

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
```
**Line 4 — Find and store this script's absolute directory.**

This is one of the most important lines in any Bash script. Let's break it down piece by piece:

- **`${BASH_SOURCE[0]}`** — A Bash array containing the path to the current script. `[0]` is the first (and usually only) element: the path used to invoke this script. This is different from `$0` in some edge cases (e.g., when a script is sourced with `.`). For a script run as `./ciphershell.sh`, this holds `./ciphershell.sh`.

- **`dirname "${BASH_SOURCE[0]}"`** — The `dirname` command strips the filename, returning only the directory part. For `./ciphershell.sh` it returns `.`. For `/home/user/CipherShell Chat/ciphershell.sh` it returns `/home/user/CipherShell Chat`.

- **`$(...)` — Command substitution.** Runs a command and replaces itself with that command's output. So `$(dirname ...)` returns the directory string.

- **`"$(...)"` — The double quotes around the inner `$(...)`.** Critical for paths with spaces! Without quotes, a path like `/CipherShell Chat/` would be split into two words: `/CipherShell` and `Chat/` — causing an error.

- **`cd "$(dirname ...)"` — Change directory** to where the script lives.

- **`&> /dev/null`** — Redirects ALL output (both stdout and stderr) to `/dev/null`, which is the "black hole" device — data written to it is discarded. We don't want `cd` printing the new directory name or error messages.

- **`&& pwd`** — The `&&` operator means "only run the next command if the previous one succeeded." `pwd` (Print Working Directory) prints the current directory as an absolute path. So if `cd` succeeded, `pwd` gives us the full absolute path.

- **`SCRIPT_DIR=$(...)` — Stores the result** in a variable called `SCRIPT_DIR`.

**Why this matters:** If you run `cd /tmp && ./path/to/ciphershell.sh`, this script finds its own folder regardless of where you ran it from. Every subsequent call to sub-scripts uses `"$SCRIPT_DIR/..."` as a prefix, which always works.

**→ Used at:** Lines 30, 39, 55, 66, 78, 83 — all the places that call other scripts.

---

```bash
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
```
**Lines 6–20 — Define the `show_menu` function.**

- **`show_menu() { ... }`** — Defines a function named `show_menu`. Functions in Bash are defined like this and called like commands: `show_menu`. They run in the same shell process (unlike `bash script.sh` which creates a child).

- **`clear`** — Sends the terminal escape sequence to wipe all visible text. Makes the menu always appear at the top of a clean screen.

- **`echo "..."`** — Prints a string followed by a newline. The quotes are necessary here because the strings contain spaces.

- **`echo -n "Select an option [1-7]: "`** — The `-n` flag suppresses the trailing newline. This way the cursor stays on the same line as the prompt, and the user's input appears right after the colon. Compare: `echo "Enter: "` would put the cursor on the next line; `echo -n "Enter: "` keeps it inline.

**→ Called at:** Line 23 — inside the main loop.

---

```bash
while true; do
    show_menu
    read -r choice
    case $choice in
```
**Lines 22–25 — The main loop.**

- **`while true; do ... done`** — An infinite loop. `true` is a command that always exits with status 0 (success), so the `while` condition is always met. The loop only ends when `exit` is called (line 97) or the script is killed.

- **`show_menu`** — Calls the function defined above. This redraws the menu at the start of every iteration.

- **`read -r choice`** — Reads one line of input from stdin (the keyboard) and stores it in the variable `choice`.
  - **`-r`** — "raw" mode: disables backslash interpretation. Without `-r`, if the user types `1\n`, the `\n` would be interpreted as a newline character. With `-r`, it's stored literally as the characters `\` and `n`. Always use `-r` with `read` unless you specifically need backslash processing.

- **`case $choice in`** — Bash's version of a switch statement. Matches the value of `$choice` against patterns.

---

```bash
        1)
            echo -n "Enter port [default: 9000]: "
            read -r port
            port=${port:-9000}
            bash "$SCRIPT_DIR/server/server.sh" "$port" > server.log 2>&1 &
            SERVER_PID=$!
            echo "Server started in background on port $port. Check server.log."
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
```
**Lines 26–34 — Option 1: Start the server.**

- **`echo -n "Enter port [default: 9000]: "`** — Prompt the user. `-n` keeps cursor on the same line.

- **`read -r port`** — Read the user's input into `$port`. If user just hits Enter, `$port` is empty.

- **`port=${port:-9000}`** — **Default value substitution.**
  - Syntax: `${variable:-default}` means "use variable's value, but if it's unset or empty, use default instead."
  - So if user pressed Enter without typing anything, `$port` becomes `9000`.

- **`bash "$SCRIPT_DIR/server/server.sh" "$port"`** — Runs `server.sh` with `$port` as its first argument (`$1`).
  - **`bash "..."`** — Explicitly runs with bash. Could also use `./server.sh` but that requires the execute bit to be set on the file. `bash` always works.

- **`> server.log`** — Redirects stdout (the server's printed output) to a file called `server.log` in the current directory.

- **`2>&1`** — Redirects stderr (file descriptor 2) to wherever stdout is currently going (file descriptor 1). Since stdout is going to `server.log`, this means stderr also goes to `server.log`. Together, `> server.log 2>&1` captures ALL output.

- **`&`** — Runs the command in the background. The shell doesn't wait for it to finish; it immediately continues to the next line.

- **`SERVER_PID=$!`** — `$!` is a special Bash variable that holds the **Process ID (PID) of the most recently backgrounded command**. Storing it lets us kill the server later (in option 7).

- **`read -n 1 -s -r -p "Press any key to continue..."`**
  - **`-n 1`** — Read exactly 1 character (don't wait for Enter).
  - **`-s`** — Silent mode: don't echo the character back to the terminal.
  - **`-r`** — Raw mode (no backslash interpretation).
  - **`-p "..."`** — Print a prompt before reading.
  - Together: displays "Press any key to continue..." and waits for a single keypress without requiring Enter.

- **`;;`** — Ends a `case` branch. Required in Bash's `case` syntax.

**→ server.sh receives** `$port` as its `$1` (see `server/server.sh` line 7).
**→ `SERVER_PID` is used** at line 88 to check if the server is still running before killing it.

---

```bash
        2)
            echo -n "Enter username: "
            read -r username
            if [ -n "$username" ]; then
                bash "$SCRIPT_DIR/client/register.sh" "$username"
            fi
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
```
**Lines 35–42 — Option 2: Register a new user.**

- **`if [ -n "$username" ]; then`** — Tests if `$username` is non-empty.
  - `[ ... ]` is the `test` command in Bash (also available as `[[ ... ]]` in Bash-only mode).
  - **`-n`** means "non-zero length" — true if the string has at least one character.
  - The opposite is **`-z`** which is "zero length" — true if empty.
  - Without this guard, if the user pressed Enter without typing a name, `register.sh ""` would be called with an empty string.

- **`bash "$SCRIPT_DIR/client/register.sh" "$username"`** — Passes the username as the first argument.

**→ register.sh receives** `$username` as its `$1` (see `client/register.sh` line 9).

---

```bash
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
```
**Lines 43–57 — Option 3: Login.**

- **`host=${host:-127.0.0.1}`** — Default host is `127.0.0.1`, which is **localhost** (your own machine). Used when both server and client are on the same computer.

- **`bash "$SCRIPT_DIR/client/client.sh" login "$username" "$host" "$port"`** — Passes 4 arguments: the literal word `"login"`, username, host, and port.
  - Argument 1 (`$1` in client.sh) = `"login"` — a command identifier
  - Argument 2 (`$2` in client.sh) = username
  - Argument 3 (`$3` in client.sh) = host
  - Argument 4 (`$4` in client.sh) = port

- **Notice: no `read -n 1 -s -r -p "Press any key..."` at the end.** This is intentional. `client.sh` is a blocking script — it runs until you press Ctrl+C or the server disconnects. When it finally exits, the `while true` loop naturally redraws the menu.

**→ client.sh receives** all 4 arguments (see `client/client.sh` lines 4–7).

---

```bash
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
```
**Lines 58–69 — Option 4: Send a message.**

- **`[ -n "$sender" ] && [ -n "$recipient" ] && [ -n "$message" ]`** — Three conditions combined with `&&`:
  - All three variables must be non-empty for the `if` to be true.
  - `&&` short-circuits: if the first condition is false, it doesn't bother checking the rest.

- **`bash "$SCRIPT_DIR/client/send.sh" "$sender" "$recipient" "$message"`** — Passes 3 arguments. Note that `$message` is quoted, so spaces in the message are preserved as a single argument.

**→ send.sh receives** sender as `$1`, recipient as `$2`, message as `$3` (and potentially more args — see `client/send.sh` lines 3–6).

---

```bash
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
```
**Lines 70–81 — Option 5: Send a file.**

Same structure as option 4. The third input here is a **file path** instead of a message string.

**→ send_file.sh receives** sender, recipient, filepath as `$1`, `$2`, `$3` (see `client/send_file.sh` lines 3–5).

---

```bash
        6)
            bash "$SCRIPT_DIR/demo.sh"
            read -n 1 -s -r -p "Press any key to continue..."
            ;;
```
**Lines 82–85 — Option 6: Run the demo.**

Simply delegates to `demo.sh`. The `read` after it waits so the user can read the demo output before the screen clears.

**→ demo.sh** runs the entire pipeline from scratch (register, login, send, receive, teardown).

---

```bash
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
```
**Lines 86–98 — Option 7: Exit.**

- **`[ -n "$SERVER_PID" ]`** — Checks that `SERVER_PID` was set at all (i.e., option 1 was used in this session). If the user never started the server from this menu, `$SERVER_PID` is empty and we skip the kill prompt.

- **`kill -0 "$SERVER_PID"`** — `kill` with signal `0` is special. It doesn't actually send any signal to the process. It **only checks if the process exists and if you have permission to signal it**. Returns 0 (success) if the process is alive, non-zero if it's dead or doesn't exist. This is the standard Bash idiom for "is this PID still running?"

- **`2>/dev/null`** — Silences the error if the PID doesn't exist (which would print "No such process").

- **`[[ "$kill_srv" =~ ^[Yy]$ ]]`** — Bash regex match:
  - `[[ ... ]]` — Extended test (bash-only, more powerful than `[ ]`)
  - `=~` — regex match operator
  - `^[Yy]$` — regex meaning: start of string (`^`), one character that is either `Y` or `y` (`[Yy]`), end of string (`$`). This matches exactly `y` or `Y` and nothing else.

- **`kill "$SERVER_PID"`** — Sends **SIGTERM** (signal 15) to the process. SIGTERM is the polite shutdown signal — the process can catch it and clean up before exiting.

- **`pkill -P "$SERVER_PID"`** — Kills all **child processes** of `$SERVER_PID`. Because `server.sh` starts `python3 socket_mux.py` as a child, killing `server.sh` alone might leave the Python process orphaned and still occupying the port.
  - **`-P`** flag means "match processes whose parent PID is this value."

- **`exit 0`** — Exits the script with status code 0. In Unix/Linux, 0 = success. Non-zero = some kind of failure.

- **`2>/dev/null`** on kill — Silences errors if the process is already dead.

---

```bash
        *)
            echo "Invalid option."
            sleep 1
            ;;
```
**Lines 99–102 — Default case.**

- **`*)`** — In Bash's `case` syntax, `*` is a wildcard that matches anything. This is the "else" branch — runs for any input that didn't match 1–7.

- **`sleep 1`** — Pauses for 1 second so the user can read the "Invalid option." message before the screen clears and the menu redraws.

---

```bash
    esac
done
```
**Lines 103–104 — End of the case and loop.**

- **`esac`** — Ends the `case` block. (`esac` = `case` spelled backwards — same convention as `if`/`fi`.)
- **`done`** — Ends the `while` loop. Execution returns to `while true; do` and the loop repeats.

---

### `demo.sh` — The Automated Test

**Role:** Proves the entire system works end-to-end by scripting all the manual steps: register two users, log them both in, send messages and a file between them, print the results, then tear down everything.

---

```bash
#!/bin/bash
# demo.sh - Automated Demo Script for CipherShell Chat
```
**Lines 1–2** — Shebang and comment (same as explained in `ciphershell.sh`).

---

```bash
echo "======================================"
echo "    CipherShell Automated Demo"
echo "======================================"
```
**Lines 4–6** — Prints a banner. Pure cosmetic output for the user.

---

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR" || exit 1
```
**Lines 8–9 — Set working directory to the project root.**

- Same `SCRIPT_DIR` trick as `ciphershell.sh` line 4. Both scripts use the same pattern.
- **`cd "$SCRIPT_DIR" || exit 1`** — Change directory to the project root (where `demo.sh` lives). The `|| exit 1` means: if `cd` fails for any reason (the directory was deleted, permission denied, etc.), abort the script immediately with exit code 1 (error). Without this, subsequent relative paths like `server/server.sh` would fail silently.

---

```bash
echo "[*] Cleaning up previous state..."
rm -rf ~/.ciphershell/alice ~/.ciphershell/bob
rm -rf server/users.db
pkill -f "socket_mux.py" || true
pkill -f "nc 127.0.0.1 9000" || true
```
**Lines 11–15 — Clean up any leftover state from previous runs.**

- **`rm -rf ~/.ciphershell/alice ~/.ciphershell/bob`** — Deletes the key directories for both demo users.
  - **`-r`** = recursive (deletes directories and their contents)
  - **`-f`** = force (no error if the files don't exist; don't prompt for confirmation)
  - Deleting these means `generate_keys.sh` will generate fresh keys for this demo run.

- **`rm -rf server/users.db`** — Deletes the public key database. This forces fresh registration.

- **`pkill -f "socket_mux.py"`** — Kills any existing Python server process.
  - **`pkill`** sends a signal to processes matching a name.
  - **`-f`** means match against the **full command line**, not just the process name. Without `-f`, `pkill python3` would kill all Python scripts; with `-f "socket_mux.py"` it only kills processes that have `socket_mux.py` in their command line.

- **`|| true`** — The `||` runs the right side if the left side fails. Since `pkill` exits with status 1 when no processes match (nothing to kill), and Bash scripts can be set to exit on error, we use `|| true` to ensure this line always "succeeds" even when there's nothing to kill. `true` is a command that always exits with status 0.

**→ Connects to:** `crypto/generate_keys.sh` line 11 — that's where `~/.ciphershell/$USERNAME` gets created.

---

```bash
echo "[*] Starting server in background..."
bash server/server.sh 9000 > server.log 2>&1 &
SERVER_PID=$!
sleep 2
```
**Lines 17–20 — Start the server.**

- **`bash server/server.sh 9000`** — Calls `server.sh` with port `9000` hardcoded for the demo.
- **`> server.log 2>&1 &`** — Redirect output to log, run in background. Same pattern as `ciphershell.sh` line 30.
- **`SERVER_PID=$!`** — Save the PID for cleanup at the end.
- **`sleep 2`** — Wait 2 seconds before registering users. This gives the Python server time to start up and bind to port 9000. Without this sleep, `register.sh` might run and try to connect before the server is ready (though registration doesn't actually connect — but the next sleep allows the socket to be fully ready for client connections).

**→ server.sh** receives `9000` as `$1` (see `server/server.sh` line 7).
**→ SERVER_PID** is used at line 64 to kill the server at the end.

---

```bash
echo "[*] Registering Alice..."
bash client/register.sh alice

echo "[*] Registering Bob..."
bash client/register.sh bob
```
**Lines 22–26 — Register both demo users.**

- Each call to `register.sh` generates RSA-4096 key pair and copies the public key to `server/users.db/`.
- These run **synchronously** (no `&`) — we must wait for registration to complete before logging in.

**→ register.sh** generates keys in `~/.ciphershell/alice/` and `~/.ciphershell/bob/`.
**→ register.sh** copies public keys to `server/users.db/alice.pub` and `server/users.db/bob.pub`.
**→ send.sh** will later read those `.pub` files to encrypt.

---

```bash
echo "[*] Alice logs in (background)..."
bash client/client.sh login alice 127.0.0.1 9000 > alice_client.log 2>&1 &
ALICE_CLIENT_PID=$!
sleep 2
```
**Lines 28–31 — Log Alice in as a background process.**

- **`> alice_client.log 2>&1 &`** — All output from `client.sh` (including everything from the background `listener.sh` it starts) goes to `alice_client.log`. This is how we capture decrypted messages in the demo.
- **`sleep 2`** — Wait for Alice's connection to establish before Bob logs in or any messages are sent.

**→ client.sh** receives `login alice 127.0.0.1 9000` as arguments.
**→ client.sh** creates `~/.ciphershell/alice/pipes/in` and `pipes/out`.
**→ client.sh** connects to the server and sends `LOGIN alice`.
**→ alice_client.log** is printed at line 60.

---

```bash
echo "[*] Bob logs in (background)..."
bash client/client.sh login bob 127.0.0.1 9000 > bob_client.log 2>&1 &
BOB_CLIENT_PID=$!
sleep 2
```
**Lines 33–36 — Log Bob in.** Mirror of Alice's login. Two separate background `client.sh` processes, each maintaining their own TCP connection and FIFOs.

---

```bash
echo "[*] Alice sends a message to Bob..."
bash client/send.sh alice bob "Hello Bob, this is a secret message!"
sleep 2
```
**Lines 38–40 — Alice sends a message.**

- **`bash client/send.sh alice bob "Hello Bob, this is a secret message!"`** — Three arguments.
  - The entire message string `"Hello Bob, this is a secret message!"` is passed as a **single** argument because it's in double quotes. Inside `send.sh`, `shift 2` then `"$*"` captures it.
- **`sleep 2`** — Gives time for the message to: encrypt → write to FIFO → netcat → server → Bob's netcat → Bob's listener → decrypt → print. The whole pipeline is fast but involves process spawning, and the `sleep 2` ensures we don't check logs before messages arrive.

**→ send.sh** encrypts with `server/users.db/bob.pub`.
**→ send.sh** writes to `~/.ciphershell/alice/pipes/in`.
**→ Bob's listener.sh** receives, decrypts, and prints to `bob_client.log`.

---

```bash
echo "[*] Bob sends a reply to Alice..."
bash client/send.sh bob alice "Hi Alice, message received securely."
sleep 2
```
**Lines 42–44 — Bob replies.** Same mechanism, reversed direction. Encrypted with `alice.pub`, decrypted with `alice/private.pem`.

---

```bash
echo "[*] Bob sends a file to Alice..."
echo "Confidential server logs" > secret_file.txt
bash client/send_file.sh bob alice secret_file.txt
sleep 2
```
**Lines 46–49 — Bob sends a file.**

- **`echo "Confidential server logs" > secret_file.txt`** — Creates a small test file in the current directory (the project root, since `cd "$SCRIPT_DIR"` was run at line 9).
- **`bash client/send_file.sh bob alice secret_file.txt`** — Sends the file. `send_file.sh` reads the file, prepends `FILE:secret_file.txt` as a header, encrypts everything, and sends it.

**→ send_file.sh** reads `secret_file.txt` and packages it.
**→ Alice's listener.sh** detects `FILE:` prefix, strips the header, saves the file content to disk.

---

```bash
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
```
**Lines 51–61 — Print results.**

- **`cat bob_client.log`** — `cat` (concatenate) reads and prints the content of a file. This shows all the output from Bob's `client.sh` session, which includes the decrypted "[Message from alice]: Hello Bob..." line that `listener.sh` printed.

---

```bash
echo "[*] Shutting down..."
kill $ALICE_CLIENT_PID $BOB_CLIENT_PID $SERVER_PID 2>/dev/null
pkill -f "socket_mux.py" || true
rm secret_file.txt
```
**Lines 63–66 — Teardown.**

- **`kill $ALICE_CLIENT_PID $BOB_CLIENT_PID $SERVER_PID`** — Sends SIGTERM to all three PIDs at once. `kill` can accept multiple PIDs.
- The `trap cleanup EXIT` in `client.sh` fires when these processes are killed, cleaning up their FIFOs automatically.
- **`pkill -f "socket_mux.py"`** — Belt-and-suspenders: kill the Python process directly in case it wasn't properly cleaned up when `server.sh` was killed.
- **`rm secret_file.txt`** — Remove the test file created at line 47.

---

### `server/server.sh` — The Server Launcher

**Role:** A thin wrapper that sets up the working directory and invokes the Python server. Only 16 lines but essential.

---

```bash
#!/bin/bash
# server.sh - Starts the CipherShell chat server
```
**Lines 1–2** — Shebang and comment.

---

```bash
# Change to the directory where the script is located
cd "$(dirname "$0")" || exit 1
```
**Line 5 — Change to the script's directory.**

- **`$0`** — The name/path of the current script (simpler than `${BASH_SOURCE[0]}` — works here because this script is never sourced with `.`).
- **`dirname "$0"`** — Get the folder containing `server.sh`, which is `server/`.
- **`cd "..." || exit 1`** — Change directory, exit if it fails.

**Why this is critical:** Line 16 runs `python3 socket_mux.py "$PORT"`. Python looks for `socket_mux.py` in the **current directory**. If the current directory isn't `server/`, Python won't find the file and will fail with `No such file or directory`.

**→ Enables:** Line 16 — `python3 socket_mux.py` works because we're now in the `server/` folder.

---

```bash
PORT=${1:-9000}
```
**Line 7 — Set port with default.**

- **`$1`** — The first argument passed to this script. When called from `demo.sh` as `bash server/server.sh 9000`, this is `"9000"`. When called from `ciphershell.sh` as `bash server.sh "$port"`, it's whatever the user typed.
- **`:-9000`** — Default to 9000 if no argument was given.

**→ Receives from:** `ciphershell.sh` line 30 (passes `$port`) and `demo.sh` line 18 (passes `9000`).
**→ Passes to:** Line 16 (passed to Python as `sys.argv[1]`).

---

```bash
# Create a directory to store public keys if we decide to use the server as a key store
mkdir -p users.db
```
**Line 10 — Create the public key database directory.**

- **`mkdir -p users.db`** — Creates `server/users.db/` (since we `cd`'d into `server/` at line 5).
  - **`-p`** — "parents": create intermediate directories as needed, and don't error if the directory already exists.

This directory stores the `.pub` files for each registered user. When Alice wants to send a message to Bob, `send.sh` reads `server/users.db/bob.pub`.

**→ register.sh line 17** also creates this directory, but separately — whichever runs first creates it.
**→ register.sh line 17** copies public keys here.
**→ send.sh line 21** reads public keys from here.

---

```bash
echo "Starting CipherShell Server on port $PORT..."
echo "Python script will handle socket multiplexing..."
```
**Lines 12–13** — Informational output that goes to `server.log`.

---

```bash
# Run the python helper
python3 socket_mux.py "$PORT"
```
**Line 16 — Start the Python server.**

- **`python3`** — Runs the Python 3 interpreter (as opposed to `python` which might be Python 2 on some systems).
- **`socket_mux.py`** — The filename. Works because we're in the `server/` directory.
- **`"$PORT"`** — Passed as `sys.argv[1]` inside the Python script.
- This is a **blocking call** — `server.sh` stays running as long as `socket_mux.py` is running. When Python exits (e.g., Ctrl+C), this line returns and `server.sh` ends.

**→ Sends port to:** `socket_mux.py` line 78 (`sys.argv[1]`).

---

### `server/socket_mux.py` — The Relay Server

**Role:** The entire server is this one Python file. An async TCP relay: multiple clients connect, it maps usernames to connections, and routes encrypted messages between them. It never touches the encryption.

---

```python
import asyncio
import sys
```
**Lines 1–2 — Import standard library modules.**

- **`import asyncio`** — Python's built-in library for asynchronous I/O. Provides the event loop, coroutines (`async def`), and networking primitives (`asyncio.start_server`, `StreamReader`, `StreamWriter`).
- **`import sys`** — System-specific functions. Used for `sys.argv` (command-line arguments).

No third-party packages. Everything here ships with Python 3.4+.

---

```python
clients = {}
```
**Line 4 — The central registry: a dictionary mapping usernames to TCP writers.**

- **`{}`** — An empty Python dictionary (hash map).
- When Alice logs in, this becomes: `{"alice": <StreamWriter for alice's socket>}`
- When Bob also logs in: `{"alice": <alice's writer>, "bob": <bob's writer>}`
- A `StreamWriter` is an asyncio object that represents the "send" side of a TCP connection.

This single variable is what makes routing possible. When the server receives `SEND bob ...`, it looks up `"bob"` in this dict to find Bob's writer, then calls `writer.write(...)` to send data over Bob's TCP connection.

**→ Written at:** Lines 23 (login), 20 (re-login cleanup).
**→ Read at:** Lines 18 (duplicate login check), 39 (recipient lookup).
**→ Deleted from at:** Line 64 (disconnect cleanup).

---

```python
async def handle_client(reader, writer):
    username = None
    try:
```
**Lines 6–8 — Define the client handler coroutine.**

- **`async def`** — Defines a coroutine function. When called, it returns a coroutine object. When `await`ed, it runs until it hits an `await` or returns.
- **`handle_client(reader, writer)`** — Called by asyncio for every new TCP connection. `reader` is a `StreamReader` (for receiving data from this client), `writer` is a `StreamWriter` (for sending data to this client).
- **`username = None`** — Initialize `username` before the `try` block so the `finally` block can reference it safely (even if the connection closed before login was parsed).
- **`try:`** — Start of a try/except/finally block. Any exception inside this block is caught below.

**→ Called by:** Lines 68–69 — `asyncio.start_server` registers this as the callback for new connections.

---

```python
        line = await reader.readline()
        if not line:
            return
```
**Lines 10–12 — Wait for the first line from the client.**

- **`await reader.readline()`** — Reads bytes from the TCP socket until a newline (`\n`) is found. The `await` keyword pauses this coroutine and returns control to the asyncio event loop, which can handle other clients. When data arrives, asyncio resumes this coroutine with the received line.
- **`if not line:`** — If `readline()` returns an empty bytes object (`b""`), it means the client disconnected before sending anything (TCP connection closed = EOF). We return immediately, triggering the `finally` block.
- **`return`** — Exits the function, immediately triggering the `finally` block at line 61.

---

```python
        parts = line.decode(errors='ignore').strip().split(' ', 1)
        if len(parts) != 2 or parts[0] != 'LOGIN':
            writer.close()
            return
        username = parts[1]
```
**Lines 13–17 — Parse and validate the LOGIN command.**

- **`.decode(errors='ignore')`** — Converts the received bytes to a Python string. `errors='ignore'` means: if any bytes can't be decoded as UTF-8, silently drop them rather than raising an exception. This makes the server robust against malformed or binary input.

- **`.strip()`** — Removes leading and trailing whitespace, including the trailing `\n` that `readline()` includes.

- **`.split(' ', 1)`** — Split the string on spaces, but only split at most once (the `1` argument). This gives a list of at most 2 parts.
  - `"LOGIN alice\n".strip().split(' ', 1)` → `["LOGIN", "alice"]`
  - Why `1`? Because if a username had a space (bad idea, but still), we don't want to split it further.

- **`if len(parts) != 2 or parts[0] != 'LOGIN':`** — The first message MUST be exactly `LOGIN <username>`. Any other format → reject.
  - `len(parts) != 2` catches: empty message, message without a space (just one word), etc.
  - `parts[0] != 'LOGIN'` catches: using a different command before logging in.

- **`writer.close()`** — Closes the TCP connection to this client.
- **`return`** — Exits the function.

- **`username = parts[1]`** — Extracts the username. For `"LOGIN alice"`, this is `"alice"`.

**→ The client sends** `"LOGIN alice\n"` from `client/client.sh` line 35.

---

```python
        if username in clients:
            try:
                clients[username].close()
            except Exception:
                pass
        clients[username] = writer
        print(f"User {username} connected.", flush=True)
```
**Lines 18–24 — Register the client, handling duplicate logins.**

- **`if username in clients:`** — Checks if this username is already in the `clients` dict. This happens when a user reconnects without properly disconnecting first (e.g., their network dropped).

- **`clients[username].close()`** — Close the old (likely dead) TCP connection for this username.

- **`except Exception: pass`** — Ignore any error when closing the old connection. The socket might already be closed/broken; we don't care — we're replacing it anyway.

- **`clients[username] = writer`** — Register the new connection. This replaces any old entry for the same username.

- **`print(f"...", flush=True)`** — Print a status message to the server's stdout (which goes to `server.log`).
  - **`f"..."`** — An f-string (formatted string literal). `{username}` is replaced with the actual value of the variable.
  - **`flush=True`** — Forces Python to immediately write the output rather than buffering it. Important for log files — without this, the message might not appear in `server.log` for a while.

---

```python
        while True:
            line = await reader.readline()
            if not line:
                break
            msg = line.decode(errors='ignore').strip()
            if not msg:
                continue
```
**Lines 26–32 — The main message loop for this client.**

- **`while True:`** — Infinite loop. Keeps reading messages from this client until it disconnects.

- **`await reader.readline()`** — Waits for the next line from the client. While waiting, the event loop handles other clients.

- **`if not line: break`** — Empty bytes = client disconnected (TCP EOF). Exit the loop and fall through to cleanup.

- **`msg = line.decode(errors='ignore').strip()`** — Decode and clean up the line.

- **`if not msg: continue`** — If the decoded message is empty (e.g., a lone newline), skip it and wait for the next line.

---

```python
            parts = msg.split(' ', 2)
            if len(parts) == 3 and parts[0] == 'SEND':
                recipient = parts[1]
                payload = parts[2]
```
**Lines 34–37 — Parse a SEND command.**

- **`.split(' ', 2)`** — Split on spaces, at most 2 splits. This gives at most 3 parts:
  - `parts[0]` = command (`"SEND"`)
  - `parts[1]` = recipient (`"bob"`)
  - `parts[2]` = payload (everything else — the entire base64 blob)

  The `2` limit is critical. The base64 payload can be thousands of characters long. Without the limit, it would be split on every space (base64 doesn't contain spaces, so this wouldn't split the payload itself, but it's still the right approach).

- **`if len(parts) == 3 and parts[0] == 'SEND':`** — Validate the format. Must have exactly 3 parts and start with `SEND`.

**→ The format** `"SEND bob <base64>\n"` is built by `client/send.sh` lines 34–38.

---

```python
                if recipient in clients:
                    out_msg = f"FROM {username} {payload}\n"
                    try:
                        clients[recipient].write(out_msg.encode())
                        await asyncio.wait_for(clients[recipient].drain(), timeout=5.0)
                        print(f"Routed message from {username} to {recipient}", flush=True)
                    except asyncio.TimeoutError:
                        print(f"Timeout routing to {recipient}. Dropping message.", flush=True)
                    except Exception as e:
                        print(f"Error routing to {recipient}: {e}", flush=True)
```
**Lines 39–48 — Route the message to the recipient.**

- **`if recipient in clients:`** — Is the recipient online? Check the `clients` dict.

- **`f"FROM {username} {payload}\n"`** — Build the forwarded message. The format changes from `SEND bob <payload>` to `FROM alice <payload>` — the server swaps the command and replaces the recipient's name with the sender's name. The payload is forwarded **completely unchanged** — the server doesn't touch the encrypted blob.

- **`.encode()`** — Converts the Python string back to bytes (UTF-8 by default). TCP sends bytes, not strings.

- **`clients[recipient].write(out_msg.encode())`** — Writes the bytes into the TCP output buffer for the recipient's connection. This doesn't immediately send the bytes over the wire — it queues them in a buffer.

- **`await asyncio.wait_for(clients[recipient].drain(), timeout=5.0)`**:
  - **`.drain()`** — Flushes the write buffer, actually sending the queued bytes over the network. Returns a coroutine.
  - **`asyncio.wait_for(..., timeout=5.0)`** — Waits for `drain()` to complete, but gives up after 5 seconds. If the recipient's connection is very slow or unresponsive, we don't want to block indefinitely.
  - If `drain()` takes longer than 5 seconds, `asyncio.TimeoutError` is raised and caught below.

- **`except asyncio.TimeoutError:`** — Handles timeout: log and drop the message. The message is lost, but the sender's connection continues.

- **`except Exception as e:`** — Catches any other error (broken pipe, connection reset, etc.) when writing to the recipient.

**→ The forwarded message** `"FROM alice <blob>\n"` is what `client/listener.sh` lines 20–21 parse.

---

```python
                else:
                    # Send error back to sender
                    err_msg = f"ERROR {recipient} is not online\n"
                    writer.write(err_msg.encode())
                    await writer.drain()
```
**Lines 49–53 — Recipient not found: send error back to sender.**

- **`writer`** here is the **sender's** writer (Alice's TCP connection), not the recipient's. So Alice gets an error message telling her Bob isn't online.
- **`f"ERROR {recipient} is not online\n"`** — The format that `listener.sh` checks for with `if [[ $line == ERROR* ]]`.

**→ listener.sh line 15** catches lines starting with `ERROR`.

---

```python
            elif len(parts) >= 2 and parts[0] == 'PUBLISH_KEY':
                # Optional: handling key publication
                pass
```
**Lines 54–56 — Stub for key publication (not yet implemented).**

- **`pass`** — Python's "do nothing" statement. This branch does nothing currently. It's a placeholder for a future feature where clients could upload their public keys to the server, enabling true network-wide key distribution without needing a shared filesystem.

**→ Creative extension section** at the end of this document shows how to complete this feature.

---

```python
    except asyncio.LimitOverrunError:
        print(f"Payload too large from {username}", flush=True)
    except Exception as e:
        print(f"Error handling {username}: {e}", flush=True)
```
**Lines 57–60 — Top-level exception handlers.**

- **`asyncio.LimitOverrunError`** — Raised when `reader.readline()` encounters a line longer than the `limit` set in `asyncio.start_server` (50MB here). This would happen if someone sent a file so large the base64 encoding exceeds 50MB.
- **`Exception as e`** — Catches everything else: unexpected errors, connection issues, etc. Logs them to `server.log`.

---

```python
    finally:
        writer.close()
        if username and username in clients and clients[username] == writer:
            del clients[username]
            print(f"User {username} disconnected.", flush=True)
```
**Lines 61–65 — Cleanup: runs no matter how the function exits.**

- **`finally:`** — This block ALWAYS executes: whether the `try` block completed normally, an exception was raised, or a `return` was hit. It's the cleanup guarantee.

- **`writer.close()`** — Close this client's TCP connection. Important if an exception caused us to exit before the normal disconnect.

- **`if username and username in clients and clients[username] == writer:`** — Three conditions:
  1. **`username`** — Was a username set? (If login failed before `username = parts[1]`, it's still `None`.)
  2. **`username in clients`** — Is this username still in the dict?
  3. **`clients[username] == writer`** — Is the entry for this username this exact writer object? This check prevents a race condition: if Alice logged in twice in rapid succession, the second login replaced the first in `clients`. When the first connection's `finally` runs, we must NOT delete the second connection's entry.

- **`del clients[username]`** — Remove the username from the registry. Now the server treats Alice as offline.

---

```python
async def main(port):
    server = await asyncio.start_server(
        handle_client, '0.0.0.0', port,
        limit=1024 * 1024 * 50
    )
    addr = server.sockets[0].getsockname()
    print(f'Serving CipherShell Relay on {addr}', flush=True)
    async with server:
        await server.serve_forever()
```
**Lines 67–75 — Create and run the TCP server.**

- **`asyncio.start_server(handle_client, '0.0.0.0', port, limit=...)`**:
  - **`handle_client`** — The coroutine function to call for each new connection. asyncio calls `handle_client(reader, writer)` whenever a client connects.
  - **`'0.0.0.0'`** — Listen on all network interfaces. `'127.0.0.1'` would be localhost only (can't be reached from other machines). `'0.0.0.0'` means anyone on the network can connect.
  - **`port`** — The port number (9000).
  - **`limit=1024 * 1024 * 50`** — Maximum line length in bytes: 50MB. This is the buffer limit for `readline()`. Needed because file payloads (after base64 encoding) can be very large.

- **`server.sockets[0].getsockname()`** — Gets the actual address the server is listening on, for logging.

- **`async with server:`** — Context manager that ensures the server is properly closed if something goes wrong.

- **`await server.serve_forever()`** — Blocks (asynchronously) forever, accepting new connections and running their `handle_client` coroutines.

---

```python
if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    try:
        asyncio.run(main(port))
    except KeyboardInterrupt:
        print("\nServer shutting down.")
```
**Lines 77–82 — Entry point.**

- **`if __name__ == '__main__':`** — This block only runs when the file is executed directly (`python3 socket_mux.py`). If the file were imported as a module (`import socket_mux`), this block would NOT run. Standard Python idiom.

- **`sys.argv[1] if len(sys.argv) > 1 else 9000`** — `sys.argv` is the list of command-line arguments. `sys.argv[0]` is the script name. `sys.argv[1]` is the first argument. If no argument was given (`len(sys.argv) <= 1`), default to 9000.

- **`int(...)`** — Convert the string argument to an integer. Port numbers must be integers.

- **`asyncio.run(main(port))`** — Create an asyncio event loop and run the `main` coroutine until it completes (which is never, since `serve_forever()` runs indefinitely).

- **`except KeyboardInterrupt:`** — When the user presses Ctrl+C, Python raises `KeyboardInterrupt`. This catches it and prints a clean shutdown message instead of a traceback.

**→ `sys.argv[1]`** receives the port from `server/server.sh` line 16 (`python3 socket_mux.py "$PORT"`).

---

### `client/register.sh` — User Registration

**Role:** Creates a user's cryptographic identity (key pair) and registers their public key with the server's key database. Must be run once per user before they can log in or receive messages.

---

```bash
#!/bin/bash
# register.sh <username>

if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi
```
**Lines 1–7 — Guard clause: require a username argument.**

- **`[ -z "$1" ]`** — Tests if `$1` (the first argument) is zero-length (empty or not provided). The `-z` flag stands for "zero length."
  - **`"$1"` in quotes** — Critical! If `$1` is not given, it's empty. Without quotes, `[ -z ]` would be interpreted as `[ ]` with no argument, which is a different (and usually passing) test.
- **`echo "Usage: $0 <username>"`** — `$0` is the name of this script as it was called. If called as `bash client/register.sh`, `$0` is `client/register.sh`. Shown in the usage message for clarity.
- **`exit 1`** — Exit with status code 1 (conventional error indicator).

---

```bash
USERNAME=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
```
**Lines 9–11 — Set up variables.**

- **`USERNAME=$1`** — Store the username argument in a named variable for readability.
- **`SCRIPT_DIR`** — Absolute path to the `client/` folder (where `register.sh` lives).
- **`ROOT_DIR=$(dirname "$SCRIPT_DIR")`** — `dirname` on the `client/` path gives the parent directory, which is the project root. This is used to find `crypto/` and `server/`.

Example: If `SCRIPT_DIR` is `/home/user/CipherShell Chat/client`, then `ROOT_DIR` is `/home/user/CipherShell Chat`.

---

```bash
echo "Registering user: $USERNAME"
bash "$ROOT_DIR/crypto/generate_keys.sh" "$USERNAME"
```
**Lines 13–14 — Generate the RSA key pair.**

- Calls `generate_keys.sh`, passing the username as its first argument.
- `generate_keys.sh` creates `~/.ciphershell/$USERNAME/private.pem` and `~/.ciphershell/$USERNAME/public.pem`.
- This is a **blocking** call — we wait for it to finish (RSA-4096 generation takes a few seconds) before continuing.

**→ generate_keys.sh** runs the full key generation pipeline.
**→ The `public.pem` created there** is used in the next line.

---

```bash
mkdir -p "$ROOT_DIR/server/users.db"
cp ~/.ciphershell/$USERNAME/public.pem "$ROOT_DIR/server/users.db/${USERNAME}.pub"
echo "User $USERNAME registered. Public key saved to server/users.db/${USERNAME}.pub"
```
**Lines 16–18 — Publish the public key to the server's database.**

- **`mkdir -p "$ROOT_DIR/server/users.db"`** — Create the key database directory if it doesn't exist. The `-p` flag prevents errors if it already exists.

- **`cp ~/.ciphershell/$USERNAME/public.pem "$ROOT_DIR/server/users.db/${USERNAME}.pub"`** — Copy the public key file.
  - Source: `~/.ciphershell/alice/public.pem` (created by `generate_keys.sh`)
  - Destination: `[project root]/server/users.db/alice.pub`
  - The filename `${USERNAME}.pub` is a convention this project uses — `send.sh` constructs the same filename when looking up a recipient's key.

**→ send.sh line 21** reads `server/users.db/${RECIPIENT}.pub` — exactly the file created here.
**→ server.sh line 10** also creates `users.db/` — but register.sh does it too for the case where the server hasn't started yet.

---

### `client/client.sh` — Login & Connection Manager

**Role:** The most architecturally complex script. It opens the TCP connection, creates the named pipes (FIFOs), keeps the connection alive, starts the listener, and cleans up on exit. Everything else depends on it being running.

---

```bash
#!/bin/bash
# client.sh login <username> [host] [port]

CMD=$1
USERNAME=$2
HOST=${3:-127.0.0.1}
PORT=${4:-9000}
```
**Lines 1–7 — Parse arguments with defaults.**

- **`CMD=$1`** — Expected to be the literal string `"login"`. The design uses a command word as the first argument (a common pattern for extensible CLI tools — future commands like `logout` or `status` could be added).
- **`USERNAME=$2`** — The username.
- **`HOST=${3:-127.0.0.1}`** — Third argument, defaulting to `127.0.0.1` (localhost). This is the server's IP address.
- **`PORT=${4:-9000}`** — Fourth argument, defaulting to `9000`.

**→ Receives from:** `ciphershell.sh` line 55: `bash client.sh login "$username" "$host" "$port"`
**→ Receives from:** `demo.sh` line 29: `bash client/client.sh login alice 127.0.0.1 9000`

---

```bash
if [ "$CMD" != "login" ] || [ -z "$USERNAME" ]; then
    echo "Usage: $0 login <username> [host] [port]"
    exit 1
fi
```
**Lines 9–12 — Validate arguments.**

- **`[ "$CMD" != "login" ]`** — Checks that the command is `"login"`. `!=` means "not equal." This must be quoted: `"$CMD"` — if `CMD` is empty, an unquoted `$CMD` would make the test `[ != "login" ]` which is a syntax error.
- **`||`** — Logical OR: if the first condition is true (bad command) OR the second is true (no username), show usage.
- **`[ -z "$USERNAME" ]`** — Check that a username was provided.

---

```bash
if [ ! -f ~/.ciphershell/$USERNAME/private.pem ]; then
    echo "Error: Keypair not found. Please run register.sh first."
    exit 1
fi
```
**Lines 14–17 — Verify the user is registered.**

- **`[ ! -f ... ]`** — The `!` negates the test. `-f` tests that a file exists and is a regular file (not a directory, symlink, etc.). So `[ ! -f file ]` is true when the file does NOT exist.
- **`~/.ciphershell/$USERNAME/private.pem`** — The private key file that `generate_keys.sh` creates.

If the file doesn't exist, either `register.sh` was never run for this user, or the key directory was deleted. Either way, login can't proceed (no private key = can't decrypt incoming messages).

**→ private.pem is created by:** `crypto/generate_keys.sh` line 22.

---

```bash
# Set umask to 077 to ensure FIFOs are read/write only by the owner
ORIGINAL_UMASK=$(umask)
umask 077
mkdir -p ~/.ciphershell/$USERNAME/pipes
rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
mkfifo ~/.ciphershell/$USERNAME/pipes/in
mkfifo ~/.ciphershell/$USERNAME/pipes/out
umask $ORIGINAL_UMASK
```
**Lines 19–26 — Create the named pipes securely.**

- **`ORIGINAL_UMASK=$(umask)`** — Save the current umask before changing it, so we can restore it later.

- **`umask`** — Controls the default permissions of newly created files. The umask value is **subtracted** (bitwise) from the maximum permissions (`666` for files, `777` for directories).
  - Default umask `022`: files get `644` (rw-r--r--), dirs get `755` (rwxr-xr-x)
  - `umask 077`: files get `600` (rw-------), dirs get `700` (rwx------) — only the owner can access

- **`mkdir -p ~/.ciphershell/$USERNAME/pipes`** — Create the pipes directory inside the user's folder.

- **`rm -f ~/.ciphershell/$USERNAME/pipes/in ... /out`** — Delete any leftover FIFOs from a previous session. If an old FIFO exists as a **blocking** file and we try to `mkfifo` again, it would fail. The `-f` flag prevents errors if they don't exist.

- **`mkfifo ~/.ciphershell/$USERNAME/pipes/in`** — Creates a named pipe (FIFO) at this path. This file appears in the filesystem but has special behavior: writes to it block until someone reads, and reads from it block until someone writes.

- **`mkfifo ~/.ciphershell/$USERNAME/pipes/out`** — The other direction: data flows from the server → netcat → this FIFO → listener.sh.

- **`umask $ORIGINAL_UMASK`** — Restore the original umask so subsequent file operations aren't affected.

**→ `pipes/in` is read by:** `nc` at line 31, and written to by `send.sh` lines 34–38 and `send_file.sh` lines 40–44.
**→ `pipes/out` is written by:** `nc` at line 31, and read by `listener.sh` at line 62.

---

```bash
# Keep the pipe open for writing so nc doesn't exit when send.sh finishes
exec 3> ~/.ciphershell/$USERNAME/pipes/in
```
**Line 29 — The most important line in the whole client system.**

- **`exec`** — When used with a redirection and no command, `exec` applies the redirection to the current shell process itself (rather than a child process).
- **`3>`** — Open for writing on file descriptor 3. File descriptors 0, 1, 2 are stdin, stdout, stderr. FD 3 is the first "custom" one.
- **`~/.ciphershell/$USERNAME/pipes/in`** — The FIFO we created at line 24.

**What this does:** FD 3 in this shell process now points to `pipes/in` for writing, and stays open for the entire lifetime of this script.

**Why this matters:** `netcat` at line 31 reads from `pipes/in`. In Linux, a FIFO is considered "open" as long as at least one process has it open for writing. The moment every writer closes it, any process reading from it gets EOF and stops.

Without `exec 3>`:
- `send.sh` opens `pipes/in`, writes `"SEND bob ..."`, then exits
- When `send.sh` exits, it closes `pipes/in`
- No more writers → netcat gets EOF → netcat exits → TCP disconnected!

With `exec 3>`:
- This shell process holds `pipes/in` open permanently
- When `send.sh` finishes and closes its handle, `exec 3>` still has the FIFO open
- netcat never sees EOF → connection stays alive

**→ Used at:** Line 35 to write the LOGIN command.
**→ Used by:** `send.sh` lines 34–38 (indirect — send.sh opens the FIFO file directly).

---

```bash
nc "$HOST" "$PORT" < ~/.ciphershell/$USERNAME/pipes/in > ~/.ciphershell/$USERNAME/pipes/out &
NC_PID=$!
```
**Lines 31–32 — Start netcat (the TCP connection).**

- **`nc "$HOST" "$PORT"`** — Connect to the server at the given address and port.
- **`< ~/.ciphershell/$USERNAME/pipes/in`** — Redirect stdin for `nc` from the input FIFO. Netcat reads from this FIFO and sends whatever it reads over the TCP connection.
- **`> ~/.ciphershell/$USERNAME/pipes/out`** — Redirect stdout for `nc` to the output FIFO. Everything netcat receives from the server (over TCP) gets written to this FIFO.
- **`&`** — Run netcat in the background. The shell continues immediately.
- **`NC_PID=$!`** — Save netcat's PID. Used in the `cleanup` function (line 49) to kill it on exit.

**Key insight:** netcat is now the bridge:
```
pipes/in ──FIFO──► nc stdin ──TCP──► server
                   nc stdout ──TCP──◄ server
pipes/out ◄──FIFO── nc stdout
```

**→ netcat stdin reads from:** `pipes/in`, which `send.sh` writes to.
**→ netcat stdout writes to:** `pipes/out`, which `listener.sh` reads from.
**→ netcat connects to:** `socket_mux.py`, which accepts the connection at its `handle_client` coroutine.

---

```bash
# Send login command
echo "LOGIN $USERNAME" >&3
```
**Line 35 — Send the LOGIN command to the server.**

- **`echo "LOGIN $USERNAME"`** — Produces the string `"LOGIN alice\n"` (echo adds a newline by default).
- **`>&3`** — Redirect this echo's output to file descriptor 3, which is `pipes/in` (opened at line 29).
- Data flow: `echo` → FD 3 → `pipes/in` (FIFO) → netcat reads it → sends over TCP → server receives it.

**→ Server receives:** `"LOGIN alice\n"` and processes it at `socket_mux.py` lines 10–17.

---

```bash
# Start listener
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
bash "$SCRIPT_DIR/listener.sh" ~/.ciphershell/$USERNAME/pipes/out "$USERNAME" &
LISTENER_PID=$!
```
**Lines 37–40 — Start the listener in the background.**

- **`SCRIPT_DIR`** — Find this script's directory (the `client/` folder) so we can locate `listener.sh` next to it.
- **`bash "$SCRIPT_DIR/listener.sh" ... &`** — Start `listener.sh` as a background process.
  - Argument 1 to listener.sh: `~/.ciphershell/$USERNAME/pipes/out` — the path to the output FIFO
  - Argument 2 to listener.sh: `$USERNAME` — needed to find the private key for decryption
- **`LISTENER_PID=$!`** — Save the PID for cleanup.

**→ listener.sh** receives these as `INPUT_FIFO` and `USERNAME` (lines 4–5).

---

```bash
echo "Logged in as $USERNAME. Connection established to $HOST:$PORT."
echo "Use './send.sh <sender_username> <recipient> <message>' to send messages."
echo "Use './send_file.sh <sender_username> <recipient> <file>' to send files."
echo "Press Ctrl+C to disconnect."
```
**Lines 42–45 — User-facing status messages.** Informational only.

---

```bash
# Trap EXIT to guarantee cleanup
cleanup() {
    kill $NC_PID $LISTENER_PID 2>/dev/null
    rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
}
trap cleanup EXIT
```
**Lines 47–52 — Register a cleanup function.**

- **`cleanup() { ... }`** — Define a function that kills background processes and removes the FIFOs.

- **`kill $NC_PID $LISTENER_PID`** — Send SIGTERM to both background processes. They exit gracefully.
  - **`2>/dev/null`** — Suppress errors if either process has already died.

- **`rm -f ~/.ciphershell/$USERNAME/pipes/in ... /out`** — Delete the FIFOs. If we don't remove them, the next login attempt's `mkfifo` would fail (can't create a FIFO if one already exists at that path).

- **`trap cleanup EXIT`** — Register `cleanup` as a handler for the `EXIT` signal. This fires whenever this shell process exits, for ANY reason: Ctrl+C (which generates SIGINT, which exits the shell), normal termination, `exit` command, or even `kill` (which generates SIGTERM).
  This is the guarantee that even if something crashes, we don't leave zombie processes or stale FIFOs.

---

```bash
wait $NC_PID
echo "Connection closed."
```
**Lines 54–55 — Wait for netcat to exit.**

- **`wait $NC_PID`** — Suspends this shell process until the netcat process with that PID exits. This is what keeps `client.sh` running. The user sees `"Press Ctrl+C to disconnect."` and the terminal appears to hang here — that's correct behavior.
- When the user presses Ctrl+C: the shell receives SIGINT → the `trap cleanup EXIT` fires → cleanup kills nc and listener → `wait` returns → `"Connection closed."` is printed → script exits.
- When the server dies: nc loses its TCP connection → nc exits → `wait` returns → `trap cleanup EXIT` fires → cleanup kills listener → script exits.

---

### `client/listener.sh` — The Inbox

**Role:** Runs in the background continuously. Reads every line that comes from the server (via the output FIFO), calls `decrypt.sh` on the payload, and displays the message or saves the file.

---

```bash
#!/bin/bash
# listener.sh <input_fifo>

INPUT_FIFO=$1
USERNAME=$2
if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <input_fifo> <username>"
    exit 1
fi
```
**Lines 1–9 — Setup and validation.**

- **`INPUT_FIFO=$1`** — Path to the output FIFO (`~/.ciphershell/<user>/pipes/out`). This is where netcat writes data received from the server.
- **`USERNAME=$2`** — The logged-in user's name. Needed to find their private key for decryption.
- The guard clause requires both arguments.

**→ Receives from:** `client/client.sh` line 39 which passes these two values.

---

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
```
**Lines 11–12 — Path setup.**

`SCRIPT_DIR` = the `client/` folder. `ROOT_DIR` = project root. Used to call `crypto/decrypt.sh`.

---

```bash
while read -r line; do
```
**Line 14 — The main read loop.**

- **`while read -r line; do`** — Reads one line at a time from stdin into `$line`. The `-r` flag prevents backslash interpretation.
- **`done < "$INPUT_FIFO"`** (line 62) — The `done` at the end redirects the loop's stdin from the FIFO. This connects the entire loop to the FIFO file, so `read` reads from `pipes/out`.
- The loop blocks at each `read` call until netcat writes a line to `pipes/out`.

**→ The FIFO** is written to by `nc` in `client/client.sh` line 31 (from the TCP socket).

---

```bash
    if [[ $line == ERROR* ]]; then
        echo -e "\n[Server Error]: ${line#ERROR }"
        continue
    fi
```
**Lines 15–18 — Handle error messages from the server.**

- **`[[ $line == ERROR* ]]`** — Bash's extended test with glob pattern matching. `ERROR*` matches any string that starts with `"ERROR"`. This is more readable and safer than `[[ $line == "ERROR"* ]]` (though equivalent here).
  - Note: `[[ ]]` doesn't need quotes around `$line` since it doesn't do word splitting.

- **`echo -e "\n[Server Error]: ${line#ERROR }"`**:
  - **`-e`** — Enable interpretation of escape sequences. `\n` becomes a real newline. This prints a blank line before the error message for visual separation.
  - **`${line#ERROR }`** — Parameter substitution: strips the shortest match of `ERROR ` from the **beginning** of `$line`. For `"ERROR bob is not online"`, this gives `"bob is not online"`.

- **`continue`** — Skip the rest of the loop body and go back to `while read -r line`.

**→ Server sends:** `"ERROR bob is not online\n"` from `socket_mux.py` line 51.

---

```bash
    sender=$(echo "$line" | cut -d' ' -f2)
    payload=$(echo "$line" | cut -d' ' -f3-)
```
**Lines 20–21 — Parse the `FROM sender payload` format.**

- **`echo "$line" | cut -d' ' -f2`**:
  - `echo "$line"` — Prints the line
  - `|` — Pipe: sends that output as stdin to the next command
  - `cut -d' '` — Cuts (splits) the input using space as the delimiter (`-d' '`)
  - `-f2` — Take field number 2 (1-indexed)
  - For `"FROM alice H4sI..."`, field 1 is `FROM`, field 2 is `alice`, field 3+ is the payload.

- **`cut -d' ' -f3-`** — The `-` after `3` means "field 3 through the end." Captures the entire payload as a single value, even if it somehow contained spaces.

**→ Format comes from:** `socket_mux.py` line 40: `f"FROM {username} {payload}\n"`.

---

```bash
    if [ -z "$payload" ]; then continue; fi
```
**Line 23 — Skip empty payloads.**

If for some reason the line is malformed and has no payload (e.g., just `"FROM alice\n"` with nothing after the sender name), skip it. Defensive programming.

---

```bash
    TEMP_B64=$(mktemp)
    TEMP_OUT=$(mktemp)
    echo "$payload" > "$TEMP_B64"
```
**Lines 25–27 — Prepare temp files.**

- **`mktemp`** — Creates a uniquely named temporary file in `/tmp` (e.g., `/tmp/tmp.Xk3m9P`) and prints its path. Unique names prevent conflicts if multiple messages arrive quickly.
- **`TEMP_B64`** — Will hold the base64 payload. Written with `echo "$payload"`.
- **`TEMP_OUT`** — Will hold the decrypted plaintext after `decrypt.sh` runs.
- **`echo "$payload" > "$TEMP_B64"`** — Writes the base64 string to the temp file. `echo` adds a newline at the end, which is fine — `decrypt.sh` handles this.

---

```bash
    bash "$ROOT_DIR/crypto/decrypt.sh" ~/.ciphershell/$USERNAME/private.pem "$TEMP_B64" "$TEMP_OUT" 2>/dev/null
```
**Line 29 — Decrypt the payload.**

Calls `decrypt.sh` with 3 arguments:
1. `~/.ciphershell/$USERNAME/private.pem` — The user's private key
2. `$TEMP_B64` — The file containing the base64 blob
3. `$TEMP_OUT` — Where to write the decrypted result

- **`2>/dev/null`** — Redirects stderr to /dev/null. `decrypt.sh` uses `set -e` (exits on any error) and various OpenSSL commands that print to stderr. In normal operation we suppress these. If decryption fails, we detect it at line 31.

**→ decrypt.sh receives** these 3 arguments as `$PRIVATE_KEY`, `$INPUT`, `$OUTPUT` (lines 10–12).
**→ private.pem was created** by `crypto/generate_keys.sh` line 22.

---

```bash
    if [ ! -f "$TEMP_OUT" ] || [ ! -s "$TEMP_OUT" ]; then
        echo -e "\n[Error]: Failed to decrypt message from $sender."
        rm -f "$TEMP_B64" "$TEMP_OUT"
        continue
    fi
```
**Lines 31–35 — Check if decryption succeeded.**

- **`[ ! -f "$TEMP_OUT" ]`** — True if the output file doesn't exist. Could happen if `decrypt.sh` crashed before creating the file.
- **`[ ! -s "$TEMP_OUT" ]`** — `-s` means "file exists AND has a size greater than zero." `! -s` means the file is empty or doesn't exist. An empty output file means decryption produced no output — a failure.
- **`||`** — If EITHER condition is true (file missing OR empty), print an error and skip.
- **`rm -f "$TEMP_B64" "$TEMP_OUT"`** — Clean up temp files even on failure.
- **`continue`** — Go back to the top of the `while` loop to wait for the next message.

**→ This check is necessary because:** `decrypt.sh` uses `set -e` (line 2 of decrypt.sh) — if any command fails, the script exits immediately without creating/populating `$OUTPUT`.

---

```bash
    msg_type=$(head -c 5 "$TEMP_OUT")
    if [ "$msg_type" = "MSG: " ]; then
        content=$(tail -c +6 "$TEMP_OUT")
        echo -e "\n[Message from $sender]: $content"
```
**Lines 37–40 — Detect and display text messages.**

- **`head -c 5 "$TEMP_OUT"`** — Read exactly 5 **bytes** (not lines) from the start of the file.
  - `-c` = bytes, `-n` would be lines
  - For a text message, the decrypted content is `"MSG: Hello Bob"`, so the first 5 bytes are `"MSG: "` (M, S, G, colon, space).

- **`if [ "$msg_type" = "MSG: " ]`** — Exact match for the 5-character prefix. Note the space after the colon — it's part of the prefix.

- **`tail -c +6 "$TEMP_OUT"`** — Read from byte 6 to the end of the file. This skips the 5-byte prefix and gives the actual message content.

- **`echo -e "\n[Message from $sender]: $content"`** — Print the message. The `\n` at the start creates visual separation from any previous output in the terminal.

**→ The `"MSG: "` prefix was written** by `client/send.sh` line 30: `echo -n "MSG: $MESSAGE"`.

---

```bash
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
```
**Lines 41–56 — Detect and save received files.**

- **`[ "$msg_type" = "FILE:" ]`** — The first 5 bytes are `"FILE:"` for file transfers.

- **`head -n 1 "$TEMP_OUT"`** — Read the first **line** (everything up to the first newline). For files, this is the header line `"FILE:secret.txt"`.

- **`cut -c 6-`** — Strip the first 5 characters (`FILE:`), leaving just the filename `"secret.txt"`. `-c 6-` means "characters 6 through end."

- **`tr -d '\r'`** — Delete all carriage return (`\r`) characters. Windows line endings are `\r\n`; if the sending side runs on Windows (or if there's any Windows path in the data), `\r` can sneak in and corrupt the filename.

- **`filename=$(basename "$raw_filename")`** — The **most important security line in the whole codebase.** `basename` strips any directory path from the filename.
  - Why: A malicious sender could craft a file named `../../etc/passwd`. If written directly, this would overwrite `/etc/passwd` (the system user database) — a critical security vulnerability called **directory traversal** (or **path traversal**).
  - `basename "../../etc/passwd"` returns just `"passwd"` — the file is safely saved in the current directory.

- **`if [ -z "$filename" ] || [ "$filename" = "." ] || [ "$filename" = ".." ]`** — Edge cases where `basename` returns something unusable:
  - Empty (source was just slashes)
  - `.` (current directory)
  - `..` (parent directory)
  - All these get replaced with a safe timestamped name.

- **`date +%s`** — Outputs the current Unix timestamp (seconds since January 1, 1970). Used to create unique filenames.

- **`if [ -f "$filename" ]`** — If a file with this name already exists in the current directory, append a timestamp to avoid overwriting it.

- **`tail -n +2 "$TEMP_OUT" > "$filename"`** — Write everything from line 2 onward (skip the filename header line) to the new file. This is the actual file content.

**→ The `"FILE:name\n<content>"` format was created** by `client/send_file.sh` lines 33–36.

---

```bash
    else
        echo -e "\n[Message from $sender]: $(cat "$TEMP_OUT")"
    fi
```
**Lines 57–59 — Fallback for unknown message types.**

If the first 5 bytes don't match `"MSG: "` or `"FILE:"`, just dump the raw decrypted content. This handles any custom formats or future additions.

---

```bash
    rm -f "$TEMP_B64" "$TEMP_OUT"
done < "$INPUT_FIFO"
```
**Lines 61–62 — Cleanup and loop end.**

- **`rm -f "$TEMP_B64" "$TEMP_OUT"`** — Delete both temp files after each message. Critical to avoid filling `/tmp` with thousands of files over a long chat session.
- **`done < "$INPUT_FIFO"`** — This redirects the entire `while read` loop's stdin from `$INPUT_FIFO`. The loop reads lines from the FIFO until the FIFO closes (which happens when `client.sh`'s cleanup function removes the FIFO file and kills netcat).

---

### `client/send.sh` — Send a Message

**Role:** Encrypts a text message and injects it into the open TCP connection via the FIFO.

---

```bash
#!/bin/bash
# send.sh <sender_username> <recipient> <message>
SENDER=$1
RECIPIENT=$2
shift 2
MESSAGE="$*"
```
**Lines 1–6 — Parse arguments.**

- **`SENDER=$1`** — The sender's username (needed to find their FIFO).
- **`RECIPIENT=$2`** — Who to send the message to (needed to find their public key and to address the SEND command).
- **`shift 2`** — "Shifts" the argument list left by 2 positions. After this: the old `$3` becomes `$1`, `$4` becomes `$2`, etc. `$1` and `$2` (SENDER and RECIPIENT) are gone from the list.
- **`MESSAGE="$*"`** — `$*` joins all remaining positional parameters with spaces. After `shift 2`, these are the message words. The quotes are essential: without them, multiple spaces would collapse to one. Example: `send.sh alice bob Hello World` → after shift → `$*` = `"Hello World"`.

**Why `shift` + `$*` instead of just `$3`?** Because messages can have spaces. `$3` would only get the first word after the recipient. `$*` gets ALL remaining words joined with spaces.

---

```bash
if [ -z "$SENDER" ] || [ -z "$RECIPIENT" ] || [ -z "$MESSAGE" ]; then
    echo "Usage: $0 <sender_username> <recipient> <message...>"
    exit 1
fi
```
**Lines 8–11** — Require all three inputs to be non-empty.

---

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
```
**Lines 13–14** — Path setup (same pattern throughout the project).

---

```bash
if [ ! -p ~/.ciphershell/$SENDER/pipes/in ]; then
    echo "Error: Not connected. Run ./client.sh login first."
    exit 1
fi
```
**Lines 16–19 — Check that the sender is logged in.**

- **`[ ! -p ... ]`** — The `-p` flag tests for a **named pipe** specifically (not a regular file, not a directory, specifically a FIFO). `!` negates it: true if NOT a pipe.
- If `client.sh` hasn't been run for this sender, the FIFO won't exist at this path. Without this check, writing to a non-existent path would either fail or create a regular file (not a FIFO), breaking the system.

**→ The FIFO** was created by `client/client.sh` line 24 (`mkfifo pipes/in`).

---

```bash
PUB_KEY="$ROOT_DIR/server/users.db/${RECIPIENT}.pub"
if [ ! -f "$PUB_KEY" ]; then
    echo "Error: Public key for $RECIPIENT not found in server/users.db"
    exit 1
fi
```
**Lines 21–25 — Find the recipient's public key.**

- **`"$ROOT_DIR/server/users.db/${RECIPIENT}.pub"`** — Constructs the path to the recipient's public key file.
  - `${RECIPIENT}` — The username used as the filename base.
  - `.pub` — Extension established by `register.sh` line 17.
- The guard checks that the key file actually exists. If the recipient hasn't registered, their `.pub` file won't be there.

**→ This file was created** by `client/register.sh` line 17.
**→ This path is passed** to `crypto/encrypt.sh` as its first argument.

---

```bash
TEMP_TXT=$(mktemp)
TEMP_B64=$(mktemp)

echo -n "MSG: $MESSAGE" > "$TEMP_TXT"
```
**Lines 27–30 — Create and write the plaintext package.**

- **`TEMP_TXT`** — Temporary file for the plaintext content.
- **`TEMP_B64`** — Temporary file where the base64-encoded encrypted output will be stored.
- **`echo -n "MSG: $MESSAGE" > "$TEMP_TXT"`**:
  - `MSG: ` — The type prefix (5 characters). `listener.sh` reads exactly 5 bytes to determine the type.
  - `-n` — No trailing newline. The message is exactly `"MSG: Hello World"` with no newline at the end.
  - `>` — Overwrites the temp file with this content.

**→ The `"MSG: "` prefix is detected** by `client/listener.sh` line 38 (`head -c 5`).

---

```bash
bash "$ROOT_DIR/crypto/encrypt.sh" "$PUB_KEY" "$TEMP_TXT" "$TEMP_B64"
```
**Line 32 — Encrypt the plaintext.**

Passes 3 arguments to `encrypt.sh`:
1. `$PUB_KEY` — Recipient's public key (to RSA-encrypt the AES key)
2. `$TEMP_TXT` — The plaintext file (to AES-encrypt)
3. `$TEMP_B64` — Where to write the base64 output

After this call, `$TEMP_B64` contains a long base64 string like `H4sIAAAAAAAAA+2OMQr...`.

**→ encrypt.sh** runs the full 5-step encryption pipeline.

---

```bash
{
    echo -n "SEND $RECIPIENT "
    cat "$TEMP_B64"
    echo ""
} > ~/.ciphershell/$SENDER/pipes/in
```
**Lines 34–38 — Write the SEND command to the FIFO.**

- **`{ ... }`** — A command group. All three commands inside run in the current shell, and their stdout is collectively redirected by the `>` at the end.
  - Without `{ }`, you'd need to be careful about which redirect applies to which command.

- **`echo -n "SEND $RECIPIENT "`** — Outputs `"SEND bob "` (with trailing space, no newline). `-n` prevents the newline so the next command continues on the same line.

- **`cat "$TEMP_B64"`** — Outputs the entire base64 string. Since `encrypt.sh` produces a single line with no newlines (due to `base64 -w 0`), this appends directly after `"SEND bob "`.

- **`echo ""`** — Outputs an empty string followed by a newline. This is the final newline that the server's `reader.readline()` needs to know the line is complete.

- Together, the FIFO receives exactly: `"SEND bob H4sIAAAAA...base64...==\n"`

- **`> ~/.ciphershell/$SENDER/pipes/in`** — Writes to the FIFO. Netcat is reading from this FIFO and will pick up this line and send it over TCP.

**→ The server** receives this line and parses it at `socket_mux.py` line 34.
**→ Netcat** reads from `pipes/in` and sends over TCP (see `client/client.sh` line 31).

---

```bash
echo "Message sent to $RECIPIENT."
rm -f "$TEMP_TXT" "$TEMP_B64"
```
**Lines 40–42 — Confirm and clean up.**

- Print confirmation to the user.
- Delete both temp files.

---

### `client/send_file.sh` — Send a File

**Role:** Same as `send.sh` but for binary files. The file is packaged with a header, encrypted, and sent as a single blob.

---

```bash
SENDER=$1
RECIPIENT=$2
FILE=$3
```
**Lines 3–5** — Unlike `send.sh`, the third argument is a file **path** (not a message). No `shift` needed because file paths don't have spaces... usually. (If they do, the caller must quote the path.)

---

```bash
if [ ! -f "$FILE" ]; then
    echo "Error: File $FILE not found."
    exit 1
fi
```
**Lines 12–15 — Validate the file exists.**

- **`[ ! -f "$FILE" ]`** — Tests that a regular file exists at this path. `-f` returns true only for regular files — not for directories, FIFOs, or device files.

---

```bash
if [ ! -p ~/.ciphershell/$SENDER/pipes/in ]; then
    echo "Error: Not connected. Run ./client.sh login first."
    exit 1
fi
```
**Lines 20–23 — Same login check as `send.sh`.**

---

```bash
PUB_KEY="$ROOT_DIR/server/users.db/${RECIPIENT}.pub"
if [ ! -f "$PUB_KEY" ]; then
    echo "Error: Public key for $RECIPIENT not found in server/users.db"
    exit 1
fi
```
**Lines 25–29 — Same public key check as `send.sh`.**

---

```bash
TEMP_TXT=$(mktemp)
TEMP_B64=$(mktemp)
FILENAME=$(basename "$FILE")

echo "FILE:$FILENAME" > "$TEMP_TXT"
cat "$FILE" >> "$TEMP_TXT"
```
**Lines 31–36 — Build the file package.**

- **`FILENAME=$(basename "$FILE")`** — Strip any directory path from the filename. If `$FILE` is `"/home/alice/docs/report.pdf"`, then `$FILENAME` = `"report.pdf"`. This is what the recipient will see as the saved filename.

- **`echo "FILE:$FILENAME" > "$TEMP_TXT"`** — Write the first line: `"FILE:report.pdf\n"`. This is the header.
  - Note: this `echo` does NOT have `-n`, so it DOES add a newline. This is intentional — the header is on its own line, and the file content follows on line 2+.

- **`cat "$FILE" >> "$TEMP_TXT"`** — Append the raw file bytes to the temp file.
  - **`>>`** — Append mode: adds to the existing content rather than overwriting.
  - The result: line 1 = header, lines 2+ = raw file bytes.

**→ listener.sh decodes this by:**
- `head -n 1 | cut -c 6-` to get the filename (lines 42)
- `tail -n +2` to get the file content (line 55)

---

```bash
bash "$ROOT_DIR/crypto/encrypt.sh" "$PUB_KEY" "$TEMP_TXT" "$TEMP_B64"
```
**Line 38** — Encrypt the entire package (header + file content) as one blob. `encrypt.sh` doesn't care about the content structure — it just encrypts whatever bytes are in `TEMP_TXT`.

---

```bash
{
    echo -n "SEND $RECIPIENT "
    cat "$TEMP_B64"
    echo ""
} > ~/.ciphershell/$SENDER/pipes/in
```
**Lines 40–44** — Identical to `send.sh` lines 34–38. Writes `"SEND bob <base64>\n"` to the FIFO.

---

```bash
echo "File $FILENAME sent to $RECIPIENT."
rm -f "$TEMP_TXT" "$TEMP_B64"
```
**Lines 46–48** — Confirm and clean up.

---

### `crypto/generate_keys.sh` — Key Generation

**Role:** Creates an RSA-4096 key pair for a user. Run once per user during registration. Idempotent — does nothing if keys already exist.

---

```bash
#!/bin/bash
# generate_keys.sh
# Generates RSA-4096 key pair

USERNAME=$1
if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi
```
**Lines 1–9** — Shebang, comments, argument validation (same patterns throughout).

---

```bash
mkdir -p ~/.ciphershell/$USERNAME
cd ~/.ciphershell/$USERNAME || exit 1
```
**Lines 11–12 — Create and enter the user's key directory.**

- **`~/.ciphershell/$USERNAME`** — The user's personal directory inside the home folder. For user `alice`, this is `~/.ciphershell/alice/` (e.g., `/home/alice/.ciphershell/alice/`).
- **`mkdir -p`** — Create this directory, including all intermediate directories (`.ciphershell/` if it doesn't exist), without error if it already exists.
- **`cd ... || exit 1`** — Change into this directory. Everything `openssl` creates goes here. `|| exit 1` aborts if the cd fails.

**→ The `private.pem` created here** is read by `client/client.sh` line 14 (login check) and `client/listener.sh` line 29 (decryption).
**→ The `public.pem` created here** is copied by `client/register.sh` line 17 to `server/users.db/`.

---

```bash
if [ -f private.pem ] && [ -f public.pem ]; then
    echo "Keys already exist for $USERNAME"
    exit 0
fi
```
**Lines 14–17 — Idempotency guard.**

- **`[ -f private.pem ] && [ -f public.pem ]`** — Both files must exist for the guard to trigger.
- **`exit 0`** — Exit with success. Not an error — just "nothing to do."

**Why this matters:** If we regenerated keys every time `register.sh` is called:
1. The user's old private key would be overwritten
2. Any messages encrypted with the old public key could no longer be decrypted
3. Other users would have the old public key cached but the user would have a new private key — messages would fail to decrypt

By checking first, the function is **idempotent** — calling it multiple times has the same effect as calling it once.

---

```bash
echo "Generating RSA-4096 key pair..."
# Set umask to 077 to ensure private.pem is created with 600 permissions directly
umask 077
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:4096
# Reset umask
umask 022
chmod 600 private.pem
openssl rsa -pubout -in private.pem -out public.pem
echo "Key pair generated successfully in ~/.ciphershell/$USERNAME"
```
**Lines 19–27 — Generate the key pair.**

- **`umask 077`** — Set permissions mask so new files get `600` permissions (owner: read+write; group: nothing; other: nothing). This takes effect before `openssl` creates the file.

- **`openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:4096`** — Generate a private key:
  - **`genpkey`** — "Generate private key" — the modern OpenSSL command (older command was `genrsa`).
  - **`-algorithm RSA`** — Use the RSA algorithm.
  - **`-out private.pem`** — Write the key to this file in PEM format (a base64-encoded format with header/footer lines like `-----BEGIN PRIVATE KEY-----`).
  - **`-pkeyopt rsa_keygen_bits:4096`** — Set RSA key size to 4096 bits. This takes several seconds to compute. 4096-bit RSA is considered extremely strong — breaking it would take longer than the age of the universe with current computing.

- **`umask 022`** — Restore normal permissions so subsequent files (`public.pem`) get normal permissions (644 — world-readable, which is fine for a public key).

- **`chmod 600 private.pem`** — Double-ensure the private key is protected. Belt and suspenders.

- **`openssl rsa -pubout -in private.pem -out public.pem`** — Extract the public key from the private key:
  - **`rsa`** — RSA key processing command.
  - **`-pubout`** — Output only the public key component.
  - **`-in private.pem`** — Read from the private key file (which contains both private and public components).
  - **`-out public.pem`** — Write the public key to this file.

**→ `private.pem`** is used by `crypto/decrypt.sh` line 28 to RSA-decrypt the AES key.
**→ `public.pem`** is copied by `client/register.sh` line 17 to `server/users.db/$USERNAME.pub`, then read by `crypto/encrypt.sh` line 9 to RSA-encrypt the AES key.

---

### `crypto/encrypt.sh` — Encryption Pipeline

**Role:** Implements hybrid encryption in 5 steps. Takes any file, encrypts it with a random AES key, wraps the AES key with RSA, bundles everything into a tar archive, and base64-encodes the result into a single text string.

---

```bash
#!/bin/bash
# encrypt.sh <recipient_public_key_file> <plaintext_file> <output_file>

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <recipient_public_key> <plaintext_file> <output_file>"
    exit 1
fi
```
**Lines 1–7** — Shebang, comment, argument count check.
- **`$#`** — The number of arguments passed to the script. `ne` = "not equal." Must have exactly 3.

---

```bash
RECIPIENT_PUB=$(realpath "$1")
PLAINTEXT=$(realpath "$2")
OUTPUT=$(realpath "$3")
```
**Lines 9–11 — Convert paths to absolute.**

- **`realpath`** — Resolves a path to its absolute canonical form. Follows symlinks, resolves `.` and `..`, converts relative paths.
  - E.g., `realpath "./server/users.db/bob.pub"` → `/home/user/CipherShell Chat/server/users.db/bob.pub`

**Why this is critical:** Line 31 does `cd "$TEMP_DIR"` to change directories. If any paths were relative, they would break after the `cd`. `realpath` converts them to absolute paths that work from any directory.

---

```bash
TEMP_DIR=$(mktemp -d)
if [ ! -d "$TEMP_DIR" ]; then
    echo "Error creating temp directory"
    exit 1
fi
```
**Lines 13–17 — Create a temporary directory.**

- **`mktemp -d`** — The `-d` flag creates a **directory** instead of a file. Returns a path like `/tmp/tmp.a3Kp8m/`.
- **`if [ ! -d "$TEMP_DIR" ]`** — `-d` tests if a path is an existing directory. This verifies `mktemp` succeeded (it could fail if `/tmp` is full or permissions are wrong).
- All intermediate files (`aes.key`, `payload.enc`, `key.enc`, `package.tar`) go in this directory. `rm -rf "$TEMP_DIR"` at the end cleans up everything at once.

---

```bash
# 1. Generate random AES key
openssl rand -base64 32 > "$TEMP_DIR/aes.key"
```
**Line 20 — Step 1: Generate a random AES key.**

- **`openssl rand`** — Generate cryptographically secure random bytes.
- **`-base64`** — Output in base64 encoding (so the key is printable text, which OpenSSL's `-pass file:` option can use directly).
- **`32`** — Generate 32 random bytes. After base64 encoding, this becomes ~44 characters but represents 32 bytes = 256 bits of entropy, matching AES-256.
- **`> "$TEMP_DIR/aes.key"`** — Write to a file. The key looks like: `K7mNpQ3rXs/LwXv2AbCdEfGhIjKlMnOpQrStUv==`

**Why random every time?** If the same AES key were reused, an attacker could correlate multiple messages. Random keys ensure each encrypted message looks completely different, even if the plaintext is identical.

**→ This key is used** immediately in lines 23 (to encrypt) and 27 (to RSA-encrypt the key itself).

---

```bash
# 2. Encrypt plaintext with AES key (use pbkdf2 to avoid warnings on newer openssl)
openssl enc -aes-256-cbc -salt -pbkdf2 -in "$PLAINTEXT" -out "$TEMP_DIR/payload.enc" -pass file:"$TEMP_DIR/aes.key"
```
**Line 23 — Step 2: Encrypt the content with AES.**

- **`openssl enc`** — The symmetric encryption command.
- **`-aes-256-cbc`** — Use AES with:
  - **256-bit key** — The strongest standard AES size (128 and 192 also exist).
  - **CBC (Cipher Block Chaining)** mode — Each 128-bit block of plaintext is XORed with the previous ciphertext block before being encrypted. This ensures identical plaintext blocks produce different ciphertext, and a change in one block affects all subsequent blocks.
- **`-salt`** — Adds a random 8-byte salt to the encrypted output. Even if you encrypt the same plaintext twice with the same key, the output will differ because the salt differs.
- **`-pbkdf2`** — Use PBKDF2 (Password-Based Key Derivation Function 2) to derive the actual encryption key from the password (the AES key string). Without this, newer versions of OpenSSL print a deprecation warning.
- **`-in "$PLAINTEXT"`** — The file to encrypt.
- **`-out "$TEMP_DIR/payload.enc"`** — Where to write the encrypted output (binary data).
- **`-pass file:"$TEMP_DIR/aes.key"`** — Use the contents of `aes.key` as the encryption password. `file:` prefix tells OpenSSL to read the password from a file rather than prompting interactively.

**→ payload.enc** is extracted and decrypted by `crypto/decrypt.sh` line 32.

---

```bash
# 3. Encrypt AES key with recipient's public key
# Using rsautl as per PRD (pkeyutl is the modern alternative)
openssl rsautl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc" 2>/dev/null || \
openssl pkeyutl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc"
```
**Lines 27–28 — Step 3: RSA-encrypt the AES key.**

- **`openssl rsautl`** — The older RSA utility command (deprecated in newer OpenSSL but still widely available).
- **`openssl pkeyutl`** — The modern replacement for `rsautl`.
- **`-encrypt`** — Perform encryption (as opposed to decryption or signing).
- **`-pubin`** — The key file provided is a public key (not a full keypair). Without this flag, OpenSSL expects a private key.
- **`-inkey "$RECIPIENT_PUB"`** — The recipient's RSA public key file (from `server/users.db/bob.pub`).
- **`-in "$TEMP_DIR/aes.key"`** — The data to encrypt (the AES key, ~44 bytes of base64).
- **`-out "$TEMP_DIR/key.enc"`** — Output the encrypted AES key here.
- **`2>/dev/null || \`** — Suppress stderr from `rsautl` (it prints deprecation warnings on newer OpenSSL). If it fails (exit code non-zero), try `pkeyutl` instead.

**Why RSA can be used here:** The AES key is ~44 bytes of base64. An RSA-4096 key can encrypt up to ~500 bytes. The AES key is well within this limit.

**Why the recipient can ONLY decrypt with their private key:** RSA's mathematical foundation makes it computationally infeasible to decrypt the AES key without the private key, even knowing the public key and the encrypted output.

**→ key.enc** is extracted and decrypted by `crypto/decrypt.sh` lines 28–29.

---

```bash
# 4. Package them together
cd "$TEMP_DIR" || exit 1
tar czf package.tar key.enc payload.enc
```
**Lines 31–32 — Step 4: Bundle into a tar archive.**

- **`cd "$TEMP_DIR"`** — Change into the temp directory so `tar` can find `key.enc` and `payload.enc` by simple filenames.
- **`tar czf package.tar key.enc payload.enc`** — Create a gzip-compressed tar archive.
  - **`c`** — Create a new archive.
  - **`z`** — Compress with gzip. This significantly reduces size.
  - **`f package.tar`** — Archive filename is `package.tar`.
  - **`key.enc payload.enc`** — Files to include.

Why tar? Combining both files into one archive means the final output is a **single file** that can be base64-encoded into a single string. Without this, we'd need to send two separate base64 strings and reassemble them on the other side.

**→ tar extracts** both files in `crypto/decrypt.sh` line 25 (`tar xzf package.tar`).

---

```bash
# 5. Base64 encode the package to output file
cd - > /dev/null
# macOS base64 doesn't support -w 0, so we handle both Linux and macOS robustly
base64 -w 0 "$TEMP_DIR/package.tar" > "$OUTPUT" 2>/dev/null || base64 "$TEMP_DIR/package.tar" | tr -d '\n' > "$OUTPUT"
```
**Lines 35–37 — Step 5: Base64 encode.**

- **`cd - > /dev/null`** — Change back to the previous directory. `cd -` goes back to wherever we were before the `cd "$TEMP_DIR"`. `> /dev/null` discards the directory name that `cd -` prints.

- **`base64 -w 0 "$TEMP_DIR/package.tar" > "$OUTPUT" 2>/dev/null`** — Convert the binary tar to a base64 text string.
  - **`-w 0`** — "Wrap at 0 columns" = **no line wrapping**. By default, `base64` wraps output at 76 characters per line. The server uses `readline()` to read messages — a newline in the middle would break the message in two. `-w 0` produces one continuous string on a single line.
  - **`2>/dev/null`** — Suppress errors. On macOS, `base64 -w 0` is invalid and produces an error.

- **`|| base64 "$TEMP_DIR/package.tar" | tr -d '\n' > "$OUTPUT"`** — macOS fallback:
  - `base64` without `-w 0` wraps at 76 chars (adds newlines every 76 characters).
  - `tr -d '\n'` — `tr` (translate) with `-d` (delete) removes all newline characters from the input.
  - Result: the same single-line base64 string.

**→ The base64 string** in `$OUTPUT` is read by `client/send.sh` line 36 (`cat "$TEMP_B64"`) and written to the FIFO.
**→ The base64 decode** is done by `crypto/decrypt.sh` line 22.

---

```bash
# Cleanup
rm -rf "$TEMP_DIR"
```
**Line 40 — Delete the entire temp directory.**

Removes `aes.key`, `payload.enc`, `key.enc`, `package.tar` all at once. The AES key in particular should never persist longer than necessary.

---

### `crypto/decrypt.sh` — Decryption Pipeline

**Role:** The exact inverse of `encrypt.sh`. Takes a base64 blob and a private key, and outputs the original plaintext.

---

```bash
#!/bin/bash
set -e
# decrypt.sh <private_key_file> <input_b64_file> <output_plaintext_file>
```
**Lines 1–3**

- **`set -e`** — This is a critical safety setting. It tells Bash: **exit immediately if any command returns a non-zero exit code (failure)**. This is placed at line 2, before anything else.

  Without `set -e`, if `base64 -d` fails (corrupt input), the script would continue trying to `tar xzf` a non-existent or empty file, then try to RSA-decrypt nothing, and potentially write garbage to the output file. With `set -e`, any failure aborts immediately.

  **→ listener.sh line 31** detects this abort by checking if the output file exists and is non-empty.

---

```bash
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <private_key_file> <input_b64_file> <output_plaintext_file>"
    exit 1
fi
```
**Lines 5–8** — Require exactly 3 arguments.

---

```bash
PRIVATE_KEY=$(realpath "$1")
INPUT=$(realpath "$2")
OUTPUT=$(realpath "$3")
```
**Lines 10–12 — Convert to absolute paths.**

Same reason as `encrypt.sh`: `cd "$TEMP_DIR"` at line 19 would break relative paths. `realpath` resolves them first.

**→ Receives from:** `client/listener.sh` line 29 — the three arguments are:
1. `~/.ciphershell/$USERNAME/private.pem`
2. `$TEMP_B64` (the temp file holding the base64 blob)
3. `$TEMP_OUT` (where to write the decrypted result)

---

```bash
TEMP_DIR=$(mktemp -d)
if [ ! -d "$TEMP_DIR" ]; then
    echo "Error creating temp directory"
    exit 1
fi
cd "$TEMP_DIR" || exit 1
```
**Lines 14–19 — Create and enter temp directory.**

- All intermediate files go here.
- `cd "$TEMP_DIR"` — Enter it so subsequent commands can use simple filenames.

---

```bash
# 1. Base64 decode
base64 -d "$INPUT" > package.tar 2>/dev/null || base64 -D "$INPUT" > package.tar 2>/dev/null || base64 --decode "$INPUT" > package.tar
```
**Line 22 — Step 1: Decode base64 back to binary.**

Three attempts with different flags for cross-platform compatibility:
- **`base64 -d`** — Linux (GNU coreutils) syntax. The standard on most Linux distributions.
- **`base64 -D`** — macOS (BSD) syntax. macOS uses capital `-D` for decode.
- **`base64 --decode`** — Long-form GNU syntax. A final fallback.

The `||` chains them: try the first, if it fails try the second, if that fails try the third. Due to `set -e`, if ALL three fail, the script exits.

**→ Reverses:** `crypto/encrypt.sh` line 37.

---

```bash
# 2. Extract
tar xzf package.tar
```
**Line 25 — Step 2: Extract the archive.**

- **`x`** — Extract files.
- **`z`** — Decompress with gzip (matching the `z` in `czf` used during creation).
- **`f package.tar`** — The archive filename.

After this, `key.enc` and `payload.enc` appear in `$TEMP_DIR`.

**→ Extracts what was created** by `crypto/encrypt.sh` line 32 (`tar czf package.tar key.enc payload.enc`).

---

```bash
# 3. Decrypt AES key with private key
openssl rsautl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key 2>/dev/null || \
openssl pkeyutl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key
```
**Lines 28–29 — Step 3: RSA-decrypt the AES key.**

- **`-decrypt`** — Perform decryption (opposite of `-encrypt`).
- **`-inkey "$PRIVATE_KEY"`** — The private key file. Notice: no `-pubin` flag here (that was for public keys in `encrypt.sh`). The private key is used.
- **`-in key.enc`** — The RSA-encrypted AES key.
- **`-out aes.key`** — Where to write the recovered AES key.

This only works if `$PRIVATE_KEY` (Bob's private key) mathematically corresponds to the public key that was used to encrypt in `encrypt.sh` line 27. If Alice accidentally tried to decrypt Bob's message using her own private key, this step would fail.

Same `rsautl || pkeyutl` fallback pattern for OpenSSL version compatibility.

**→ Reverses:** `crypto/encrypt.sh` line 27.
**→ `private.pem`** was created by `crypto/generate_keys.sh` line 22.

---

```bash
# 4. Decrypt payload
openssl enc -d -aes-256-cbc -pbkdf2 -in payload.enc -out "$OUTPUT" -pass file:aes.key
```
**Line 32 — Step 4: AES-decrypt the payload.**

- **`-d`** — Decrypt mode (the only difference from the encrypt command on line 23 of `encrypt.sh`).
- **`-aes-256-cbc`** — Must match exactly what was used to encrypt.
- **`-pbkdf2`** — Must match exactly.
- **`-in payload.enc`** — The AES-encrypted data.
- **`-out "$OUTPUT"`** — Write decrypted result to the output file (which `listener.sh` will read).
- **`-pass file:aes.key`** — Use the just-recovered `aes.key` as the decryption password.

The flags must match `encrypt.sh` line 23 exactly. If they don't, the decryption would fail or produce garbage.

**→ Reverses:** `crypto/encrypt.sh` line 23.
**→ `$OUTPUT`** is read by `client/listener.sh` lines 37–58 to display the message or save the file.

---

```bash
# Cleanup
cd - > /dev/null
rm -rf "$TEMP_DIR"
```
**Lines 35–36 — Clean up.**

- **`cd - > /dev/null`** — Return to the previous directory. `> /dev/null` silences the directory name that `cd -` would print.
- **`rm -rf "$TEMP_DIR"`** — Delete the entire temp directory. This removes `package.tar`, `key.enc`, `payload.enc`, and `aes.key` — especially important for `aes.key`, which contains the plaintext encryption key and should not persist on disk.

---

## 8. Cross-File Connection Map

This table shows every significant dependency between files, with specific line numbers:

| Action | Source | → | Destination | Lines |
|---|---|---|---|---|
| Launch server | `ciphershell.sh` | calls | `server/server.sh` | ciphershell:30 → server.sh:7 |
| Launch server (demo) | `demo.sh` | calls | `server/server.sh` | demo:18 → server.sh:7 |
| Start Python relay | `server/server.sh` | calls | `server/socket_mux.py` | server.sh:16 → socket_mux.py:78 |
| New TCP connection | `server/socket_mux.py` | calls | `handle_client()` | socket_mux.py:68 → socket_mux.py:6 |
| Register user | `ciphershell.sh` | calls | `client/register.sh` | ciphershell:39 → register.sh:9 |
| Register user (demo) | `demo.sh` | calls | `client/register.sh` | demo:23 → register.sh:9 |
| Generate keys | `client/register.sh` | calls | `crypto/generate_keys.sh` | register.sh:14 → generate_keys.sh:5 |
| Publish public key | `client/register.sh` | writes | `server/users.db/*.pub` | register.sh:17 |
| Login | `ciphershell.sh` | calls | `client/client.sh` | ciphershell:55 → client.sh:4-7 |
| Login (demo) | `demo.sh` | calls | `client/client.sh` | demo:29 → client.sh:4-7 |
| Creates FIFOs | `client/client.sh` | creates | `~/.ciphershell/*/pipes/` | client.sh:24-25 |
| LOGIN command | `client/client.sh` | → TCP → | `socket_mux.py:handle_client` | client.sh:35 → socket_mux.py:10-17 |
| Start listener | `client/client.sh` | calls | `client/listener.sh` | client.sh:39 → listener.sh:4-5 |
| Send message | `ciphershell.sh` | calls | `client/send.sh` | ciphershell:66 → send.sh:3-6 |
| Send message (demo) | `demo.sh` | calls | `client/send.sh` | demo:39 → send.sh:3-6 |
| Lookup recipient key | `client/send.sh` | reads | `server/users.db/*.pub` | send.sh:21 |
| Encrypt message | `client/send.sh` | calls | `crypto/encrypt.sh` | send.sh:32 → encrypt.sh:4 |
| SEND command | `client/send.sh` | → FIFO → nc → TCP → | `socket_mux.py:handle_client` | send.sh:34-38 → socket_mux.py:34-37 |
| Route message | `socket_mux.py` | → TCP → nc → FIFO → | `client/listener.sh` | socket_mux.py:40-43 → listener.sh:20-21 |
| ERROR response | `socket_mux.py` | → TCP → nc → FIFO → | `client/listener.sh` | socket_mux.py:51 → listener.sh:15-17 |
| Decrypt message | `client/listener.sh` | calls | `crypto/decrypt.sh` | listener.sh:29 → decrypt.sh:10-12 |
| Private key (decrypt) | `crypto/decrypt.sh` | reads | `~/.ciphershell/*/private.pem` | decrypt.sh:28-29 |
| Private key (created) | `crypto/generate_keys.sh` | creates | `~/.ciphershell/*/private.pem` | generate_keys.sh:22 |
| Public key (encrypt) | `crypto/encrypt.sh` | reads | `server/users.db/*.pub` | encrypt.sh:9 |
| Public key (created) | `crypto/generate_keys.sh` | creates | `~/.ciphershell/*/public.pem` | generate_keys.sh:26 |
| Public key (copied) | `client/register.sh` | copies | `public.pem → users.db/*.pub` | register.sh:17 |
| Encrypt file | `client/send_file.sh` | calls | `crypto/encrypt.sh` | send_file.sh:38 |
| File header format | `client/send_file.sh` | → | `client/listener.sh` | send_file.sh:35 → listener.sh:41-55 |
| MSG prefix format | `client/send.sh` | → | `client/listener.sh` | send.sh:30 → listener.sh:38-40 |
| base64 encode | `crypto/encrypt.sh` | → | `crypto/decrypt.sh` | encrypt.sh:37 → decrypt.sh:22 |
| AES encrypt/decrypt | `crypto/encrypt.sh` | → | `crypto/decrypt.sh` | encrypt.sh:23 → decrypt.sh:32 |
| RSA encrypt/decrypt | `crypto/encrypt.sh` | → | `crypto/decrypt.sh` | encrypt.sh:27 → decrypt.sh:28-29 |
| tar bundle/extract | `crypto/encrypt.sh` | → | `crypto/decrypt.sh` | encrypt.sh:32 → decrypt.sh:25 |

---

## 9. The Post Office Analogy

Everything in the system maps to a physical post office analogy:

**Registration** (`register.sh` + `generate_keys.sh`):
You visit a locksmith who creates:
- A **padlock** (your RSA public key) — anyone can lock things with it, but only your key opens it.
- A **unique key** (your RSA private key) — only you have this. Never leaves your machine.

You leave a copy of your padlock at the post office counter with your name on it (`server/users.db/alice.pub`).

**Sending a message** (`send.sh` + `encrypt.sh`):
Alice wants to send Bob a letter:
1. She goes to the post office counter and asks for **Bob's padlock** (reads `bob.pub`).
2. She generates a **random combination** for a combination lock (the AES key — random every time).
3. She locks her letter inside a **strongbox** using that combination (AES encrypt).
4. She locks the combination itself inside a **small box** using **Bob's padlock** (RSA encrypt with `bob.pub`). Now only Bob can open this box.
5. She puts both boxes together, wraps them in brown paper (tar + base64), and ships them to the post office addressed `"To: Bob"`.

**The post office** (`socket_mux.py`):
The clerk reads the label, finds Bob's mailbox, and drops the wrapped package in. The clerk:
- Never had a key to any of the boxes.
- Doesn't know what's inside.
- Just reads the label and moves the package.

**Receiving** (`listener.sh` + `decrypt.sh`):
Bob picks up his mail:
1. He unwraps the brown paper (base64 decode + untar) and finds two boxes.
2. He uses his **unique private key** to open the small box — gets the combination.
3. He dials the combination to open the strongbox — gets the letter.
4. He reads it.

**The FIFO pipes** (`pipes/in` and `pipes/out`):
Alice's house has two mail slots in the door:
- `pipes/in` — The outgoing slot. Alice (or anyone in the house = `send.sh`) drops letters through here.
- `pipes/out` — The incoming slot. The mail truck (`nc`) delivers letters here.

A dedicated mail truck (`netcat`) is parked outside permanently. It runs between Alice's house and the post office continuously.

A mail reader (`listener.sh`) sits next to the incoming slot, picks up every letter, opens it (decrypts it), and reads it aloud (prints to terminal).

**The `exec 3>` lock** (`client.sh` line 29):
The door's outgoing slot has a special lock that keeps it from closing. Even when no one is currently putting a letter through, the slot stays open. Without this lock, the mail truck would assume no more letters are coming and drive away (netcat exits when FIFO closes).

---

## 10. Creative Extension: Network Key Exchange

**Current limitation:** The public keys live in `server/users.db/` — a **local folder**. This means all users must be on the same machine (or share a filesystem). Two people on different computers across the internet cannot use this system as-is.

**The stub:** `socket_mux.py` lines 54–56 already have a placeholder for this:

```python
elif len(parts) >= 2 and parts[0] == 'PUBLISH_KEY':
    # Optional: handling key publication
    pass
```

**The idea:** Add two server commands so keys are exchanged over the same TCP protocol:
- `PUBLISH_KEY <username> <base64_public_key>` — Upload your public key to the server
- `GET_KEY <username>` — Download another user's public key from the server

**Full implementation:**

**In `server/socket_mux.py` — add key storage and two new commands:**
```python
clients = {}
public_keys = {}  # NEW: stores public keys by username

# Inside handle_client, replace the PUBLISH_KEY stub:
elif parts[0] == 'PUBLISH_KEY' and len(parts) == 3:
    key_owner = parts[1]
    key_data = parts[2]  # base64-encoded PEM public key
    public_keys[key_owner] = key_data
    print(f"Key published for {key_owner}", flush=True)

# Add a new GET_KEY handler:
elif parts[0] == 'GET_KEY' and len(parts) == 2:
    key_owner = parts[1]
    if key_owner in public_keys:
        reply = f"KEY {key_owner} {public_keys[key_owner]}\n"
    else:
        reply = f"ERROR no key registered for {key_owner}\n"
    writer.write(reply.encode())
    await writer.drain()
```

**In `client/register.sh` — upload key after generating it:**
```bash
# After: cp ~/.ciphershell/$USERNAME/public.pem "$ROOT_DIR/server/users.db/${USERNAME}.pub"
# Add: Upload to server (if connected)
FIFO="$HOME/.ciphershell/$USERNAME/pipes/in"
if [ -p "$FIFO" ]; then
    PUB_B64=$(base64 -w 0 ~/.ciphershell/$USERNAME/public.pem 2>/dev/null || \
              base64 ~/.ciphershell/$USERNAME/public.pem | tr -d '\n')
    echo "PUBLISH_KEY $USERNAME $PUB_B64" > "$FIFO"
    echo "Public key uploaded to server."
fi
```

**In `client/send.sh` — fetch key from server if not locally cached:**
```bash
PUB_KEY="$ROOT_DIR/server/users.db/${RECIPIENT}.pub"
if [ ! -f "$PUB_KEY" ]; then
    echo "Key not cached locally. Fetching from server..."
    FIFO_IN="$HOME/.ciphershell/$SENDER/pipes/in"
    FIFO_OUT="$HOME/.ciphershell/$SENDER/pipes/out"
    echo "GET_KEY $RECIPIENT" > "$FIFO_IN"
    sleep 0.5  # Give the server time to respond
    KEY_LINE=$(head -n 1 "$FIFO_OUT")
    if [[ "$KEY_LINE" == KEY* ]]; then
        mkdir -p "$ROOT_DIR/server/users.db"
        echo "$KEY_LINE" | cut -d' ' -f3- | base64 -d > "$PUB_KEY"
        echo "Key fetched and cached."
    else
        echo "Error: Could not retrieve key for $RECIPIENT"
        exit 1
    fi
fi
```

**What this changes:**
- Alice and Bob can be on completely different computers across the internet.
- Bob's public key is uploaded to the server at registration time.
- When Alice sends a message to Bob for the first time, she requests Bob's key from the server over the existing TCP connection.
- After caching, subsequent messages use the local copy (no extra round-trip).
- The server now acts as a **key broker** in addition to a message relay.
- The FIFO protocol already supports this — it's just three extra server commands.

---

*Every line reference in this document corresponds exactly to the source files in this project. All bash flags, openssl options, and Python patterns are explained at the level of what each character and word means.*
