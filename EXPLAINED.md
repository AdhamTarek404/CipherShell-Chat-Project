# CipherShell Chat — Full Deep Dive

> This document explains every concept, every file, and every line of the project.
> Cross-file connections are marked with arrows like `→ connects to`.

---

## Table of Contents

1. [The Big Idea](#1-the-big-idea)
2. [System Architecture](#2-system-architecture)
3. [How a Message Travels (End-to-End Flow)](#3-how-a-message-travels-end-to-end-flow)
4. [The Encryption System — How Hybrid Crypto Works](#4-the-encryption-system--how-hybrid-crypto-works)
5. [The FIFO Trick — How Multiple Scripts Share One Connection](#5-the-fifo-trick--how-multiple-scripts-share-one-connection)
6. [File-by-File: Line-by-Line](#6-file-by-file-line-by-line)
   - [ciphershell.sh](#ciphershellsh)
   - [demo.sh](#demosh)
   - [server/server.sh](#serverserversh)
   - [server/socket_mux.py](#serversocket_muxpy)
   - [client/register.sh](#clientregistersh)
   - [client/client.sh](#clientclientsh)
   - [client/listener.sh](#clientlistenersh)
   - [client/send.sh](#clientsendsh)
   - [client/send_file.sh](#clientsend_filesh)
   - [crypto/generate_keys.sh](#cryptogenerate_keyssh)
   - [crypto/encrypt.sh](#cryptoencryptsh)
   - [crypto/decrypt.sh](#cryptodecryptsh)
7. [Cross-File Connection Map](#7-cross-file-connection-map)
8. [The Post Office Analogy](#8-the-post-office-analogy)
9. [Creative Extension Idea: Network Key Exchange](#9-creative-extension-idea-network-key-exchange)

---

## 1. The Big Idea

CipherShell Chat is a **terminal-based encrypted chat system** written almost entirely in Bash (~90%) with a small Python server (~10%).

**Core principle:** Two users can send messages and files over a TCP network, and the server in the middle **never sees the actual content**. It only ever sees scrambled, unreadable encrypted blobs. This is called **End-to-End Encryption (E2EE)**.

**What makes it interesting as a project:**
- No web frameworks, no external libraries, no dependencies beyond standard Unix tools
- Encryption is done with `openssl` commands directly in Bash
- Network communication uses `netcat` (nc), the simplest possible TCP tool
- The tricky problem of "how do multiple scripts share one TCP connection" is solved with **named pipes (FIFOs)**

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR MACHINE                             │
│                                                                 │
│  ~/.ciphershell/alice/                                          │
│    ├── private.pem   ← only Alice can decrypt                   │
│    ├── public.pem    ← copied to server/users.db/alice.pub      │
│    └── pipes/                                                   │
│         ├── in  (FIFO) ← send.sh writes here                   │
│         └── out (FIFO) ← listener.sh reads here                │
│                                                                 │
│  client.sh ──nc──► pipes/in ──TCP──►┐                          │
│                                     │                           │
│  listener.sh ◄── pipes/out ◄──TCP──┘                           │
└─────────────────────────────────────────────────────────────────┘
                              │ TCP
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SERVER (socket_mux.py)                      │
│                                                                 │
│   clients = { "alice": writer_A, "bob": writer_B }             │
│                                                                 │
│   Receives:  SEND bob <encrypted_blob>                          │
│   Forwards:  FROM alice <encrypted_blob>    ← same blob!        │
│                                                                 │
│   server/users.db/                                              │
│     ├── alice.pub   ← Bob reads this to encrypt to Alice        │
│     └── bob.pub     ← Alice reads this to encrypt to Bob        │
└─────────────────────────────────────────────────────────────────┘
                              │ TCP
                              ▼
                         Bob's machine
                      (mirror of Alice's setup)
```

---

## 3. How a Message Travels (End-to-End Flow)

This is the full journey of one message from Alice to Bob:

```
Step 1 — Alice runs send.sh:
  "Hello Bob" ──► prepend "MSG: " ──► write to temp file

Step 2 — encrypt.sh is called:
  temp file ──► AES-256 encrypt ──► payload.enc
  random AES key ──► RSA encrypt with bob.pub ──► key.enc
  tar(key.enc + payload.enc) ──► base64 ──► one long string

Step 3 — send.sh writes to FIFO:
  "SEND bob <base64string>" ──► pipes/in FIFO

Step 4 — netcat reads from FIFO and sends over TCP:
  nc reads pipes/in ──► sends bytes to server

Step 5 — server (socket_mux.py) routes:
  receives "SEND bob <base64string>"
  looks up Bob in clients{} dict
  writes "FROM alice <base64string>" to Bob's TCP connection

Step 6 — Bob's netcat receives and writes to his FIFO:
  nc receives ──► writes to pipes/out FIFO

Step 7 — Bob's listener.sh reads from FIFO:
  reads "FROM alice <base64string>"
  extracts base64string ──► writes to temp file

Step 8 — decrypt.sh is called:
  base64string ──► base64 decode ──► package.tar
  untar ──► key.enc + payload.enc
  key.enc ──► RSA decrypt with bob's private.pem ──► AES key
  payload.enc ──► AES decrypt with AES key ──► "MSG: Hello Bob"

Step 9 — listener.sh reads the decrypted content:
  detects "MSG: " prefix ──► prints "[Message from alice]: Hello Bob"
```

---

## 4. The Encryption System — How Hybrid Crypto Works

**Problem:** RSA (the most common public-key system) can only encrypt a small amount of data (limited by key size). AES can encrypt unlimited data but needs both sides to share the same key in advance.

**Solution — Hybrid Encryption:**

```
┌─────────────────────────────────────────────────────┐
│  Step 1: Generate a random AES key (throwaway key)  │
│          "k9sLp3mNqR8..." (random 32 bytes)          │
└───────────────────┬─────────────────────────────────┘
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
┌────────────────┐    ┌────────────────────────────┐
│ Encrypt the    │    │ Encrypt the AES key itself  │
│ actual message │    │ with Bob's RSA public key   │
│ with AES-256   │    │ (only Bob's private key     │
│                │    │  can unlock this)           │
│ → payload.enc  │    │ → key.enc                  │
└────────────────┘    └────────────────────────────┘
         │                     │
         └──────────┬──────────┘
                    ▼
             tar + base64
                    │
                    ▼
         One single text blob
         sent over the wire
```

On the receiving end (`decrypt.sh`), the process reverses exactly.

**Why this is secure:**
- Even if someone intercepts the blob on the wire, they need Bob's private key to unlock the AES key, and without the AES key they can't decrypt the payload.
- The server only ever sees the blob — it has no keys.

---

## 5. The FIFO Trick — How Multiple Scripts Share One Connection

This is one of the cleverest parts of the project. The problem:

- `client.sh` opens one TCP connection via `netcat`
- `send.sh` and `send_file.sh` are *separate scripts* run at any time later
- How can they inject data into that same open TCP connection?

**Answer: Named Pipes (FIFOs)**

A FIFO is a special file that works like a pipe — one process writes to it, another reads from it, and they stay synchronized:

```
send.sh ──────────────────────────────────────────────────────────►
                                                                    │
                                                                    ▼
                                                            pipes/in  (FIFO file)
                                                                    │
                                                                    ▼
client.sh: nc reads from pipes/in ──────────TCP──────────► server
client.sh: nc writes to pipes/out ◄─────────TCP────────── server
                                                                    │
                                                            pipes/out (FIFO file)
                                                                    │
                                                                    ▼
listener.sh reads from pipes/out ◄────────────────────────────────
```

The key line in `client.sh` that makes this work is:
```bash
exec 3> ~/.ciphershell/$USERNAME/pipes/in
```
This opens the FIFO on **file descriptor 3** and keeps it open permanently, so `netcat` doesn't exit when no one is writing. Without this, nc would see EOF and close the connection the moment `send.sh` finishes writing.

---

## 6. File-by-File: Line-by-Line

---

### `ciphershell.sh`

**Role:** The front door of the whole project. An interactive menu that calls all other scripts so the user doesn't have to remember commands.

```bash
#!/bin/bash
```
> **Line 1:** Tells the OS this file should be run with the Bash interpreter.

```bash
# ciphershell.sh - Interactive launcher for CipherShell Chat
```
> **Line 2:** A comment — just documentation, not executed.

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
```
> **Line 4:** Finds the directory where *this script lives* and stores it in `SCRIPT_DIR`.
> - `${BASH_SOURCE[0]}` is this script's own path, even if you run it from a different directory.
> - `dirname` strips the filename, leaving just the folder.
> - `cd ... && pwd` converts it to an absolute path.
> - `&> /dev/null` silences any output from the `cd`.
> - **Why this matters:** All other scripts are called using `"$SCRIPT_DIR/..."` so the paths always work no matter where you are in the terminal when you launch this.
> - → **Connects to:** Lines 30, 39, 55, 66, 78, 83 — every place that calls another script uses this variable.

```bash
show_menu() {
```
> **Lines 6–20:** Defines a reusable function that clears the screen and prints the menu.
> `clear` wipes the terminal so the menu always appears at the top.

```bash
while true; do
    show_menu
    read -r choice
```
> **Lines 22–24:** An infinite loop. Every iteration: show the menu, then wait for user input into `$choice`. The `-r` flag stops backslash from being interpreted as an escape character.

```bash
    case $choice in
```
> **Line 25:** A switch statement in Bash. Jumps to whichever block matches what the user typed.

```bash
        1)
            ...
            bash "$SCRIPT_DIR/server/server.sh" "$port" > server.log 2>&1 &
            SERVER_PID=$!
```
> **Lines 26–34:** Option 1 — Start server.
> - `bash "..."` runs `server.sh` with the port number.
> - `> server.log` redirects stdout to a log file; `2>&1` also sends stderr there.
> - `&` at the end runs it **in the background** so the menu stays responsive.
> - `$!` is a special variable holding the PID (process ID) of the last background command.
> - `SERVER_PID=$!` saves the PID so option 7 can kill the server later.
> - → **Connects to:** `server/server.sh` line 7 (receives `$port` as `$1`).
> - → **Connects to:** Line 88 (option 7 uses `$SERVER_PID` to kill the server).

```bash
        2)
            ...
            bash "$SCRIPT_DIR/client/register.sh" "$username"
```
> **Lines 35–42:** Option 2 — Register a new user.
> - Checks `[ -n "$username" ]` (is the string non-empty?) before calling.
> - → **Connects to:** `client/register.sh` line 9 (receives `$username` as `$1`).

```bash
        3)
            ...
            bash "$SCRIPT_DIR/client/client.sh" login "$username" "$host" "$port"
```
> **Lines 43–57:** Option 3 — Login. Passes 4 arguments: the literal word `"login"`, username, host, port.
> - Note this option does **not** have `read -n 1 -s -r -p "Press any key..."` afterward — that's intentional. `client.sh` blocks (waits) until you press Ctrl+C, so the menu only returns after the session ends.
> - → **Connects to:** `client/client.sh` lines 4–7 (CMD=$1, USERNAME=$2, HOST=$3, PORT=$4).

```bash
        4)
            ...
            bash "$SCRIPT_DIR/client/send.sh" "$sender" "$recipient" "$message"
```
> **Lines 58–69:** Option 4 — Send a message. Collects three inputs then passes them to `send.sh`.
> - → **Connects to:** `client/send.sh` lines 3–6 (SENDER=$1, RECIPIENT=$2, then shift+$* for message).

```bash
        5)
            ...
            bash "$SCRIPT_DIR/client/send_file.sh" "$sender" "$recipient" "$filepath"
```
> **Lines 70–81:** Option 5 — Send a file. Same pattern as option 4 but calls `send_file.sh`.
> - → **Connects to:** `client/send_file.sh` lines 3–5 (SENDER=$1, RECIPIENT=$2, FILE=$3).

```bash
        6)
            bash "$SCRIPT_DIR/demo.sh"
```
> **Lines 82–85:** Option 6 — Runs the automated demo. Just delegates to `demo.sh`.
> - → **Connects to:** All of `demo.sh` — it is the full automated end-to-end test.

```bash
        7)
            ...
            if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
```
> **Lines 86–98:** Option 7 — Exit.
> - `kill -0 $PID` doesn't actually kill the process — it just **checks if it's still running**. Returns 0 (success) if alive.
> - `2>/dev/null` silences the error if the process is already dead.
> - Only asks to kill if a server was started in this session (i.e., `$SERVER_PID` is set).
> - `pkill -P "$SERVER_PID"` kills child processes of the server too (like the Python script).
> - → **Connects to:** Line 31 where `SERVER_PID` was saved.

```bash
        *)
            echo "Invalid option."
            sleep 1
```
> **Lines 99–102:** The default case — any input that isn't 1–7 shows an error and waits 1 second before redrawing the menu.

---

### `demo.sh`

**Role:** A fully automated script that runs the entire system from zero to finish — registers two users, logs them in, sends messages and a file between them, and prints the results. Used for testing and demonstration.

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR" || exit 1
```
> **Lines 8–9:** Same `SCRIPT_DIR` pattern as `ciphershell.sh`. Then `cd` into the project root, so all relative paths (like `server/server.sh`) work correctly. `|| exit 1` means "if cd fails, abort".

```bash
rm -rf ~/.ciphershell/alice ~/.ciphershell/bob
rm -rf server/users.db
pkill -f "socket_mux.py" || true
pkill -f "nc 127.0.0.1 9000" || true
```
> **Lines 12–15:** Cleanup. Deletes all keys and state from previous runs so the demo always starts fresh.
> - `rm -rf` forcefully deletes directories and everything inside them.
> - `pkill -f "..."` kills any processes whose command line matches that string.
> - `|| true` means "if pkill finds nothing to kill, that's fine — don't treat it as an error".
> - → **Connects to:** `crypto/generate_keys.sh` line 11 — the `~/.ciphershell/` folder is what `generate_keys.sh` creates.

```bash
bash server/server.sh 9000 > server.log 2>&1 &
SERVER_PID=$!
sleep 2
```
> **Lines 18–20:** Starts the server in the background, saves the PID, then waits 2 seconds to give the server time to bind to the port before clients try to connect.
> - → **Connects to:** `server/server.sh` line 16 — it starts `socket_mux.py` which is what actually opens the port.

```bash
bash client/register.sh alice
bash client/register.sh bob
```
> **Lines 23–26:** Registers both users. Each call generates keys and copies the public key into `server/users.db/`.
> - → **Connects to:** `client/register.sh` lines 14 and 17 — calls `generate_keys.sh` then copies the public key.

```bash
bash client/client.sh login alice 127.0.0.1 9000 > alice_client.log 2>&1 &
ALICE_CLIENT_PID=$!
sleep 2
```
> **Lines 29–31:** Logs Alice in as a background process. All output (including decrypted messages from `listener.sh`) goes into `alice_client.log`.
> - → **Connects to:** `client/client.sh` — the full login session including FIFO setup and `netcat`.
> - → **Connects to:** Lines 57–60 — these log files are printed at the end of the demo.

```bash
bash client/send.sh alice bob "Hello Bob, this is a secret message!"
sleep 2
```
> **Lines 39–40:** Sends a message from Alice to Bob. The `sleep 2` gives time for the message to travel through the server and be decrypted by Bob's listener.
> - → **Connects to:** `client/send.sh` — which encrypts and writes to Alice's `pipes/in` FIFO.

```bash
echo "Confidential server logs" > secret_file.txt
bash client/send_file.sh bob alice secret_file.txt
```
> **Lines 47–48:** Creates a small file, then sends it from Bob to Alice.
> - → **Connects to:** `client/send_file.sh` — which packages the file with a `FILE:` header before encrypting.
> - → **Connects to:** `client/listener.sh` lines 41–56 — Alice's listener detects the `FILE:` prefix and saves it to disk.

```bash
kill $ALICE_CLIENT_PID $BOB_CLIENT_PID $SERVER_PID 2>/dev/null
pkill -f "socket_mux.py" || true
rm secret_file.txt
```
> **Lines 64–66:** Teardown. Kills all background processes and removes the temp file. The `kill` command sends SIGTERM (graceful shutdown signal) to each PID.

---

### `server/server.sh`

**Role:** A tiny launcher. Its only job is to go to the right directory and start the Python server.

```bash
cd "$(dirname "$0")" || exit 1
```
> **Line 5:** Changes to the directory containing this script. Critical because `socket_mux.py` is in the same folder, and Python needs to find it by relative path.
> - `$0` is the path to this script itself.
> - `dirname` strips the filename to get just the folder.
> - → **Connects to:** Line 16 — `python3 socket_mux.py` works only because we're now in the right directory.

```bash
PORT=${1:-9000}
```
> **Line 7:** Sets `PORT` to the first argument (`$1`), or defaults to `9000` if none is given. The `:-` syntax means "use this default if the variable is unset or empty".
> - → **Connects to:** `ciphershell.sh` line 30 — passes `$port` as the first argument.
> - → **Connects to:** `demo.sh` line 18 — passes `9000` directly.

```bash
mkdir -p users.db
```
> **Line 10:** Creates the `server/users.db/` directory if it doesn't exist. The `-p` flag means "no error if already exists, create parent dirs too".
> - → **Connects to:** `client/register.sh` line 17 — public keys are copied *into* this directory.
> - → **Connects to:** `client/send.sh` line 21 — `send.sh` reads public keys *from* this directory.

```bash
python3 socket_mux.py "$PORT"
```
> **Line 16:** Starts the Python relay server. This is a **blocking call** — `server.sh` stays running as long as `socket_mux.py` is running.
> - → **Connects to:** `socket_mux.py` line 78 — `sys.argv[1]` receives `$PORT`.

---

### `server/socket_mux.py`

**Role:** The actual server. An async TCP relay that keeps track of who is connected and forwards encrypted messages between users. It never decrypts anything.

```python
import asyncio
import sys
```
> **Lines 1–2:** `asyncio` is Python's built-in library for writing concurrent code without threads. `sys` is used to read command-line arguments.

```python
clients = {}
```
> **Line 4:** A global dictionary mapping usernames to their TCP writer objects. When Alice connects as "alice", this becomes `{"alice": <writer_for_alice>}`. This is how the server knows where to send messages.
> - → **Connects to:** Lines 23, 39, 42, 63 — every place that reads from or writes to this dict.

```python
async def handle_client(reader, writer):
```
> **Line 6:** An async function that handles one client's entire lifetime. Python's `asyncio` calls this once per TCP connection. `reader` reads data from the client, `writer` sends data to the client.
> - → **Connects to:** Lines 68–69 — `asyncio.start_server` maps every new connection to this function.

```python
    line = await reader.readline()
    if not line:
        return
    parts = line.decode(errors='ignore').strip().split(' ', 1)
    if len(parts) != 2 or parts[0] != 'LOGIN':
        writer.close()
        return
    username = parts[1]
```
> **Lines 10–17:** The first thing the server expects from any client is a `LOGIN` command.
> - `await reader.readline()` waits (without blocking other connections) for a line of text.
> - `.decode(errors='ignore')` converts bytes to a string, ignoring any non-UTF8 bytes.
> - `.strip()` removes trailing newline/spaces.
> - `.split(' ', 1)` splits on the first space only, giving at most 2 parts: `["LOGIN", "alice"]`.
> - If it's not exactly `LOGIN <username>`, the connection is closed immediately.
> - → **Connects to:** `client/client.sh` line 35 — `echo "LOGIN $USERNAME" >&3` sends exactly this format.

```python
    if username in clients:
        try:
            clients[username].close()
        except Exception:
            pass
    clients[username] = writer
```
> **Lines 18–23:** Handles the case where someone logs in with a username already in use. The old connection is closed and replaced. This allows re-login after a dropped connection.
> - → **Connects to:** Line 4 (`clients` dict) and line 63 (cleanup on disconnect).

```python
    while True:
        line = await reader.readline()
        if not line:
            break
        msg = line.decode(errors='ignore').strip()
        if not msg:
            continue
```
> **Lines 26–32:** The main message loop. Keeps reading lines forever until the client disconnects (empty `line` means EOF/disconnected).

```python
        parts = msg.split(' ', 2)
        if len(parts) == 3 and parts[0] == 'SEND':
            recipient = parts[1]
            payload = parts[2]
```
> **Lines 34–37:** Parses a `SEND` command. Splitting with max 2 splits gives `["SEND", "bob", "<entire base64 blob>"]`. The entire rest of the line is the payload — important because base64 can be very long.
> - → **Connects to:** `client/send.sh` lines 34–38 — the format `SEND $RECIPIENT <base64>` is built there.

```python
            if recipient in clients:
                out_msg = f"FROM {username} {payload}\n"
                try:
                    clients[recipient].write(out_msg.encode())
                    await asyncio.wait_for(clients[recipient].drain(), timeout=5.0)
```
> **Lines 39–43:** The core routing logic. If the recipient is online, format the message as `FROM <sender> <payload>` and write it to the recipient's TCP connection.
> - `f"FROM {username} {payload}\n"` — notice the payload is forwarded **unchanged**. The server never touches the encrypted blob.
> - `.drain()` flushes the write buffer to actually send the bytes. `wait_for(..., timeout=5.0)` prevents hanging indefinitely if the recipient's connection is slow.
> - → **Connects to:** `client/listener.sh` line 20–21 — the listener parses exactly `FROM sender payload`.

```python
            else:
                err_msg = f"ERROR {recipient} is not online\n"
                writer.write(err_msg.encode())
```
> **Lines 49–53:** If the recipient isn't in `clients`, send an error back to the sender.
> - → **Connects to:** `client/listener.sh` line 15 — `if [[ $line == ERROR* ]]` catches this.

```python
    except asyncio.LimitOverrunError:
        print(f"Payload too large from {username}", flush=True)
```
> **Lines 57–58:** Catches the case where a single line exceeds the 50MB read limit. Large files are the main cause.
> - → **Connects to:** Line 70 — `limit=1024 * 1024 * 50` is where the 50MB limit is set.

```python
    finally:
        writer.close()
        if username and username in clients and clients[username] == writer:
            del clients[username]
```
> **Lines 61–64:** The `finally` block runs no matter how the function exits (normal disconnect, error, etc.). It cleans up the writer and removes the user from `clients`.
> - The extra check `clients[username] == writer` prevents accidentally removing a new connection that replaced this one (re-login case from lines 18–23).

```python
async def main(port):
    server = await asyncio.start_server(
        handle_client, '0.0.0.0', port,
        limit=1024 * 1024 * 50
    )
```
> **Lines 67–71:** Creates the TCP server.
> - `'0.0.0.0'` means listen on all network interfaces (not just localhost), so remote connections work.
> - `handle_client` is registered as the callback for every new connection.
> - `limit=50MB` sets the max line length for `readline()` calls — needed for large encrypted files.

```python
if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    try:
        asyncio.run(main(port))
    except KeyboardInterrupt:
        print("\nServer shutting down.")
```
> **Lines 77–82:** Entry point when the script is run directly (not imported).
> - `sys.argv[1]` is the port argument passed from `server.sh` line 16.
> - `asyncio.run()` starts the event loop and runs until interrupted.
> - `KeyboardInterrupt` catches Ctrl+C for a clean shutdown message.

---

### `client/register.sh`

**Role:** Creates a user's cryptographic identity and publishes their public key to the server's database.

```bash
if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi
```
> **Lines 4–7:** Guard clause. `-z` tests if a string is empty. If no username argument was given, show usage and exit. `$0` is the name of this script.

```bash
USERNAME=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
```
> **Lines 9–11:** Setup.
> - `SCRIPT_DIR` = the `client/` folder (where this script lives).
> - `ROOT_DIR` = the parent of `client/`, i.e., the project root. This is how the script finds `crypto/` and `server/`.

```bash
bash "$ROOT_DIR/crypto/generate_keys.sh" "$USERNAME"
```
> **Line 14:** Calls the key generator. This creates `~/.ciphershell/<username>/private.pem` and `~/.ciphershell/<username>/public.pem`.
> - → **Connects to:** `crypto/generate_keys.sh` — the entire file is called here.
> - → **Connects to:** Line 17 — the `public.pem` that `generate_keys.sh` creates is immediately copied in the next line.

```bash
mkdir -p "$ROOT_DIR/server/users.db"
cp ~/.ciphershell/$USERNAME/public.pem "$ROOT_DIR/server/users.db/${USERNAME}.pub"
```
> **Lines 16–17:** Creates the key database directory (if needed) and copies the public key there.
> - The file is named `<username>.pub` — this naming is what lets `send.sh` find it later.
> - → **Connects to:** `server/server.sh` line 10 — that also creates `users.db/`, but register.sh does it too in case the server hasn't run yet.
> - → **Connects to:** `client/send.sh` line 21 — `"$ROOT_DIR/server/users.db/${RECIPIENT}.pub"` reads back exactly the file created here.

---

### `client/client.sh`

**Role:** The login manager. Opens and maintains the TCP connection to the server, and sets up the named pipes that allow other scripts to use that connection.

```bash
CMD=$1
USERNAME=$2
HOST=${3:-127.0.0.1}
PORT=${4:-9000}
```
> **Lines 4–7:** Parses 4 arguments. `HOST` and `PORT` have defaults if not provided.
> - → **Connects to:** `ciphershell.sh` line 55 — passes all 4 arguments: `login "$username" "$host" "$port"`.
> - → **Connects to:** `demo.sh` line 29 — passes `login alice 127.0.0.1 9000`.

```bash
if [ "$CMD" != "login" ] || [ -z "$USERNAME" ]; then
    echo "Usage: $0 login <username> [host] [port]"
    exit 1
fi
```
> **Lines 9–12:** Validates that the first argument is literally the word "login" AND a username was given. This makes the script self-documenting — you can't accidentally run it without knowing the syntax.

```bash
if [ ! -f ~/.ciphershell/$USERNAME/private.pem ]; then
    echo "Error: Keypair not found. Please run register.sh first."
    exit 1
fi
```
> **Lines 14–17:** Checks that the user has registered before trying to log in. `-f` tests if a regular file exists.
> - → **Connects to:** `crypto/generate_keys.sh` line 22 — that's the command that creates `private.pem`.

```bash
ORIGINAL_UMASK=$(umask)
umask 077
mkdir -p ~/.ciphershell/$USERNAME/pipes
rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
mkfifo ~/.ciphershell/$USERNAME/pipes/in
mkfifo ~/.ciphershell/$USERNAME/pipes/out
umask $ORIGINAL_UMASK
```
> **Lines 20–26:** Creates the named pipes (FIFOs) securely.
> - `umask 077` means new files get permissions `700` (only owner can read/write/execute). This is important because these pipes carry sensitive encrypted data.
> - `rm -f` deletes any leftover FIFOs from previous sessions to avoid stale state.
> - `mkfifo` creates a **named pipe** — a special file that blocks when you read from it until someone writes, and vice versa.
> - `umask $ORIGINAL_UMASK` restores the original permissions setting so other files created later aren't affected.
> - → **Connects to:** `client/send.sh` line 16 — `[ ! -p ... ]` checks if the FIFO exists before trying to write.
> - → **Connects to:** `client/listener.sh` line 62 — reads from `pipes/out`.

```bash
exec 3> ~/.ciphershell/$USERNAME/pipes/in
```
> **Line 29:** This is the key to the whole FIFO trick. Opens `pipes/in` for writing on **file descriptor 3**, and keeps it open for the life of this script.
> - Normally a FIFO closes when the writer closes it. If `send.sh` is the only writer, after it finishes writing, the FIFO would close and `netcat` would see EOF and disconnect.
> - By keeping fd 3 open here, the FIFO stays open permanently — `netcat` keeps running even between messages.
> - → **Connects to:** Line 35 — `echo "LOGIN $USERNAME" >&3` writes through this file descriptor.
> - → **Connects to:** `client/send.sh` lines 34–38 — `send.sh` also writes to this same FIFO file.

```bash
nc "$HOST" "$PORT" < ~/.ciphershell/$USERNAME/pipes/in > ~/.ciphershell/$USERNAME/pipes/out &
NC_PID=$!
```
> **Lines 31–32:** Starts `netcat`, which opens a TCP connection.
> - `< pipes/in` means nc reads its input from the FIFO (blocking until something is written there).
> - `> pipes/out` means everything nc receives from the server gets written to the output FIFO.
> - `&` runs nc in the background.
> - → **Connects to:** Line 29 — nc reads from `pipes/in` which was opened by `exec 3>`.
> - → **Connects to:** `client/listener.sh` line 62 — listener reads from `pipes/out`.
> - → **Connects to:** `socket_mux.py` line 10 — the server's `reader.readline()` reads what nc sends.

```bash
echo "LOGIN $USERNAME" >&3
```
> **Line 35:** Sends the LOGIN command to the server through fd 3 → FIFO → netcat → TCP.
> - `>&3` redirects this echo to file descriptor 3 (the FIFO).
> - → **Connects to:** `socket_mux.py` lines 10–17 — the server parses this exact `LOGIN <username>` format.

```bash
bash "$SCRIPT_DIR/listener.sh" ~/.ciphershell/$USERNAME/pipes/out "$USERNAME" &
LISTENER_PID=$!
```
> **Lines 39–40:** Starts the listener as a background process. Passes the output FIFO path and username.
> - → **Connects to:** `client/listener.sh` lines 4–5 — receives these as `INPUT_FIFO` and `USERNAME`.

```bash
cleanup() {
    kill $NC_PID $LISTENER_PID 2>/dev/null
    rm -f ~/.ciphershell/$USERNAME/pipes/in ~/.ciphershell/$USERNAME/pipes/out
}
trap cleanup EXIT
```
> **Lines 48–52:** Sets up automatic cleanup. `trap cleanup EXIT` means "run the `cleanup` function whenever this script exits for any reason" — including Ctrl+C, errors, or normal exit.
> - This guarantees no zombie processes or stale FIFO files are left behind.
> - → **Connects to:** Lines 32, 40 — `NC_PID` and `LISTENER_PID` were saved there.

```bash
wait $NC_PID
```
> **Line 54:** The main thread waits here until `netcat` exits. This is what keeps `client.sh` running. When nc exits (server disconnects, or Ctrl+C), this returns and the `cleanup` trap fires.

---

### `client/listener.sh`

**Role:** The "inbox" of the client. Reads everything coming from the server, decrypts each message, and displays it (or saves it as a file).

```bash
INPUT_FIFO=$1
USERNAME=$2
```
> **Lines 4–5:** Receives its two arguments.
> - `INPUT_FIFO` = path to `~/.ciphershell/<username>/pipes/out` — where netcat writes server messages.
> - `USERNAME` = needed to find the private key for decryption.
> - → **Connects to:** `client/client.sh` line 39 — passes exactly these two values.

```bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
```
> **Lines 11–12:** Same path resolution pattern. `ROOT_DIR` is used to find `crypto/decrypt.sh`.

```bash
while read -r line; do
```
> **Line 14:** The main loop. `read -r line` reads one line at a time from whatever is connected to stdin. Combined with `done < "$INPUT_FIFO"` at the end (line 62), this reads from the FIFO — blocking until data arrives.
> - → **Connects to:** Line 62 — `done < "$INPUT_FIFO"` is the other half of this loop.

```bash
    if [[ $line == ERROR* ]]; then
        echo -e "\n[Server Error]: ${line#ERROR }"
        continue
    fi
```
> **Lines 15–18:** Checks if the line starts with `ERROR`. If so, print it and skip to the next iteration.
> - `${line#ERROR }` strips the prefix `"ERROR "` from the string, leaving just the error message.
> - → **Connects to:** `socket_mux.py` line 51 — the server sends `"ERROR <reason>\n"` in exactly this format.

```bash
    sender=$(echo "$line" | cut -d' ' -f2)
    payload=$(echo "$line" | cut -d' ' -f3-)
```
> **Lines 20–21:** Parses the `FROM alice <base64blob>` line.
> - `cut -d' ' -f2` splits on spaces and takes field 2 → the sender name.
> - `cut -d' ' -f3-` takes field 3 and everything after → the full base64 payload (which may contain characters but not spaces, since it's base64 encoded).
> - → **Connects to:** `socket_mux.py` line 40 — the server formats it as `f"FROM {username} {payload}\n"`.

```bash
    TEMP_B64=$(mktemp)
    TEMP_OUT=$(mktemp)
    echo "$payload" > "$TEMP_B64"
```
> **Lines 25–27:** Creates two temporary files. Writes the base64 payload to the first one.
> - `mktemp` creates a unique temporary file in `/tmp` and returns its path.
> - → **Connects to:** Line 29 — `TEMP_B64` is passed to `decrypt.sh` as the input file.

```bash
    bash "$ROOT_DIR/crypto/decrypt.sh" ~/.ciphershell/$USERNAME/private.pem "$TEMP_B64" "$TEMP_OUT" 2>/dev/null
```
> **Line 29:** The core decryption call. Passes 3 arguments to `decrypt.sh`:
> 1. The user's private key (`~/.ciphershell/<user>/private.pem`)
> 2. The input file containing the base64 blob
> 3. The output file where plaintext will be written
> - `2>/dev/null` suppresses any error messages from decrypt (e.g., if it gets a corrupt message).
> - → **Connects to:** `crypto/decrypt.sh` lines 10–12 — receives these as `PRIVATE_KEY`, `INPUT`, `OUTPUT`.
> - → **Connects to:** `crypto/generate_keys.sh` line 22 — `private.pem` was created there.

```bash
    if [ ! -f "$TEMP_OUT" ] || [ ! -s "$TEMP_OUT" ]; then
```
> **Line 31:** Checks if decryption succeeded. `-f` checks the file exists, `-s` checks it's non-empty.
> - → **Connects to:** `crypto/decrypt.sh` line 2 (`set -e`) — if decrypt fails, it exits without writing the output file.

```bash
    msg_type=$(head -c 5 "$TEMP_OUT")
    if [ "$msg_type" = "MSG: " ]; then
        content=$(tail -c +6 "$TEMP_OUT")
        echo -e "\n[Message from $sender]: $content"
```
> **Lines 37–40:** Reads the first 5 characters of the decrypted output to determine the message type.
> - `head -c 5` reads exactly 5 bytes (not lines).
> - If those 5 bytes are `"MSG: "`, it's a text message.
> - `tail -c +6` reads from byte 6 onward — everything after the prefix.
> - → **Connects to:** `client/send.sh` line 30 — `echo -n "MSG: $MESSAGE"` writes the prefix.

```bash
    elif [ "$msg_type" = "FILE:" ]; then
        raw_filename=$(head -n 1 "$TEMP_OUT" | cut -c 6- | tr -d '\r')
        filename=$(basename "$raw_filename")
        if [ -z "$filename" ] || [ "$filename" = "." ] || [ "$filename" = ".." ]; then
            filename="received_file_$(date +%s)"
        fi
        if [ -f "$filename" ]; then
            filename="${filename}_$(date +%s)"
        fi
        tail -n +2 "$TEMP_OUT" > "$filename"
        echo -e "\n[File received from $sender]: Saved as $filename"
```
> **Lines 41–56:** Handles the file case.
> - `head -n 1` reads the first **line** (the filename header).
> - `cut -c 6-` strips the first 5 characters (`FILE:`), leaving just the filename.
> - `tr -d '\r'` removes Windows-style carriage returns that might appear.
> - `basename "$raw_filename"` strips any directory path from the filename — this prevents a malicious sender from writing to `/etc/passwd` or similar (**directory traversal attack prevention**).
> - `date +%s` is the current Unix timestamp — used to create unique names for conflicts.
> - `tail -n +2 "$TEMP_OUT"` reads from line 2 onward — the actual file content (skipping the filename header line).
> - → **Connects to:** `client/send_file.sh` line 35 — `echo "FILE:$FILENAME"` writes exactly this format.

```bash
    rm -f "$TEMP_B64" "$TEMP_OUT"
done < "$INPUT_FIFO"
```
> **Lines 61–62:** Cleans up temp files after each message, then loops back. The `done < "$INPUT_FIFO"` connects the entire `while read` loop to the FIFO file.
> - → **Connects to:** `client/client.sh` line 31 — nc writes to `pipes/out`, which is what `INPUT_FIFO` points to.

---

### `client/send.sh`

**Role:** Sends an encrypted text message through the already-open TCP connection.

```bash
SENDER=$1
RECIPIENT=$2
shift 2
MESSAGE="$*"
```
> **Lines 3–6:** Parses arguments.
> - `shift 2` discards the first 2 arguments ($1 and $2), shifting everything left.
> - `"$*"` then captures everything remaining as the message — this allows messages with spaces (e.g., `send.sh alice bob Hello World` → MESSAGE = "Hello World").

```bash
if [ ! -p ~/.ciphershell/$SENDER/pipes/in ]; then
    echo "Error: Not connected. Run ./client.sh login first."
    exit 1
fi
```
> **Lines 16–19:** Checks that the sender's FIFO exists. `-p` tests for a named pipe specifically.
> - If `client.sh` hasn't been run for this user, the FIFO won't exist, and writing to it would fail or create a regular file.
> - → **Connects to:** `client/client.sh` line 24 — `mkfifo pipes/in` creates the FIFO this checks for.

```bash
PUB_KEY="$ROOT_DIR/server/users.db/${RECIPIENT}.pub"
if [ ! -f "$PUB_KEY" ]; then
    echo "Error: Public key for $RECIPIENT not found in server/users.db"
    exit 1
fi
```
> **Lines 21–25:** Looks up the recipient's public key.
> - → **Connects to:** `client/register.sh` line 17 — that's where the `.pub` file was created.
> - → **Connects to:** `crypto/encrypt.sh` line 9 — this path is passed as `RECIPIENT_PUB`.

```bash
echo -n "MSG: $MESSAGE" > "$TEMP_TXT"
```
> **Line 30:** Writes the plaintext with the `MSG: ` prefix. The `-n` flag suppresses the trailing newline (so the message is exactly the text, no extra line at the end).
> - → **Connects to:** `client/listener.sh` line 38 — the listener checks for exactly `"MSG: "` (5 chars).

```bash
bash "$ROOT_DIR/crypto/encrypt.sh" "$PUB_KEY" "$TEMP_TXT" "$TEMP_B64"
```
> **Line 32:** Encrypts the plaintext file. Result is a base64 string in `TEMP_B64`.
> - → **Connects to:** `crypto/encrypt.sh` — the entire encryption pipeline runs here.

```bash
{
    echo -n "SEND $RECIPIENT "
    cat "$TEMP_B64"
    echo ""
} > ~/.ciphershell/$SENDER/pipes/in
```
> **Lines 34–38:** Writes one complete line to the FIFO: `SEND bob <base64blob>`.
> - The `{ ... }` group captures all three outputs as a unit and redirects them together to the FIFO.
> - `echo -n "SEND $RECIPIENT "` — no newline, so the next `cat` appends on the same line.
> - `cat "$TEMP_B64"` — outputs the base64 (which has no newlines due to `-w 0` in `encrypt.sh`).
> - `echo ""` — adds the final newline that the server needs to recognize the end of the line.
> - → **Connects to:** `socket_mux.py` line 34 — `msg.split(' ', 2)` parses this exact format.
> - → **Connects to:** `client/client.sh` line 31 — nc is reading from this FIFO and sending it over TCP.

---

### `client/send_file.sh`

**Role:** Sends an encrypted file. Nearly identical to `send.sh` but packages the file differently.

```bash
SENDER=$1
RECIPIENT=$2
FILE=$3
```
> **Lines 3–5:** Unlike `send.sh`, the third argument is a file path, not a message string.

```bash
if [ ! -f "$FILE" ]; then
    echo "Error: File $FILE not found."
    exit 1
fi
```
> **Lines 12–15:** Validates the file exists before doing anything. `-f` checks for a regular file (not a directory or pipe).

```bash
FILENAME=$(basename "$FILE")
echo "FILE:$FILENAME" > "$TEMP_TXT"
cat "$FILE" >> "$TEMP_TXT"
```
> **Lines 33–36:** Constructs the plaintext package:
> - Line 1: `FILE:<filename>` — the header.
> - Lines 2+: The raw file content, appended with `>>`.
> - → **Connects to:** `client/listener.sh` lines 41–55 — the listener uses `head -n 1` and `tail -n +2` to split these back apart.

```bash
bash "$ROOT_DIR/crypto/encrypt.sh" "$PUB_KEY" "$TEMP_TXT" "$TEMP_B64"
```
> **Line 38:** Encrypts the entire package (header + file content) as one blob.
> - → **Connects to:** `crypto/encrypt.sh` — same encryption pipeline as `send.sh`.

```bash
} > ~/.ciphershell/$SENDER/pipes/in
```
> **Line 44:** Same FIFO write as `send.sh` — injects `SEND recipient <base64>` into the TCP connection.
> - → **Connects to:** `client/client.sh` line 31 — nc reads from this FIFO.

---

### `crypto/generate_keys.sh`

**Role:** Creates a user's RSA-4096 key pair. Run once per user during registration.

```bash
mkdir -p ~/.ciphershell/$USERNAME
cd ~/.ciphershell/$USERNAME || exit 1
```
> **Lines 11–12:** Creates and enters the user's personal directory. Everything for a user lives here.
> - → **Connects to:** `client/client.sh` line 14 — checks `private.pem` exists in this directory.
> - → **Connects to:** `client/register.sh` line 17 — copies `public.pem` from this directory.

```bash
if [ -f private.pem ] && [ -f public.pem ]; then
    echo "Keys already exist for $USERNAME"
    exit 0
fi
```
> **Lines 14–17:** Idempotency guard. If keys already exist, do nothing and exit cleanly. This prevents accidentally overwriting existing keys, which would make old encrypted messages permanently unreadable.

```bash
umask 077
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:4096
```
> **Lines 21–22:** Generates the private key.
> - `umask 077` makes sure `private.pem` is created with `600` permissions (owner read/write only).
> - `genpkey -algorithm RSA` generates an RSA key.
> - `-pkeyopt rsa_keygen_bits:4096` specifies 4096-bit key size — this is a strong modern choice (2048 is minimum acceptable, 4096 is considered very secure as of 2026).
> - → **Connects to:** `crypto/decrypt.sh` line 28 — `private.pem` is used here to decrypt the AES key.

```bash
umask 022
chmod 600 private.pem
openssl rsa -pubout -in private.pem -out public.pem
```
> **Lines 24–26:** Resets permissions, enforces `600` on the private key, then derives the public key.
> - `openssl rsa -pubout` extracts only the public component from the private key.
> - → **Connects to:** `crypto/encrypt.sh` line 9 — `public.pem` (copied to `users.db/`) is used to encrypt.

---

### `crypto/encrypt.sh`

**Role:** Hybrid-encrypts a file. Produces a single base64 string that can travel safely over the wire.

```bash
RECIPIENT_PUB=$(realpath "$1")
PLAINTEXT=$(realpath "$2")
OUTPUT=$(realpath "$3")
```
> **Lines 9–11:** `realpath` converts relative paths to absolute paths. This is essential because the script later does `cd "$TEMP_DIR"`, which would break relative paths.

```bash
TEMP_DIR=$(mktemp -d)
```
> **Line 13:** Creates a temporary **directory** (not just a file). All intermediate files go here so cleanup is one `rm -rf`.

```bash
openssl rand -base64 32 > "$TEMP_DIR/aes.key"
```
> **Line 20:** Generates 32 random bytes and base64-encodes them for use as the AES key. This key is **different every single time** — even if you send the same message twice, the encrypted output will look completely different.
> - → **Connects to:** Lines 23 and 27 — the AES key is used in both the next two steps.

```bash
openssl enc -aes-256-cbc -salt -pbkdf2 -in "$PLAINTEXT" -out "$TEMP_DIR/payload.enc" -pass file:"$TEMP_DIR/aes.key"
```
> **Line 23:** Encrypts the actual message/file content with AES-256-CBC.
> - `-aes-256-cbc` — 256-bit AES in Cipher Block Chaining mode (a standard, well-tested mode).
> - `-salt` — adds a random salt to prevent identical plaintext from producing identical ciphertext.
> - `-pbkdf2` — uses the PBKDF2 key derivation function when converting the password to a key. Required to avoid deprecation warnings in newer OpenSSL versions.
> - `-pass file:aes.key` — uses the contents of the key file as the encryption password.
> - → **Connects to:** `crypto/decrypt.sh` line 32 — the mirror operation uses the same flags.

```bash
openssl rsautl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc" 2>/dev/null || \
openssl pkeyutl -encrypt -pubin -inkey "$RECIPIENT_PUB" -in "$TEMP_DIR/aes.key" -out "$TEMP_DIR/key.enc"
```
> **Lines 27–28:** RSA-encrypts the AES key using the recipient's public key. Only their private key can undo this.
> - `rsautl` is the older command, `pkeyutl` is the newer equivalent. The `||` tries `rsautl` first and falls back to `pkeyutl` for compatibility across OpenSSL versions.
> - `-pubin` means the input key is a public key (not a full keypair).
> - → **Connects to:** `crypto/generate_keys.sh` line 26 — `public.pem` is what `$RECIPIENT_PUB` points to.
> - → **Connects to:** `crypto/decrypt.sh` line 28 — the inverse operation uses the private key.

```bash
cd "$TEMP_DIR" || exit 1
tar czf package.tar key.enc payload.enc
```
> **Lines 31–32:** Bundles `key.enc` and `payload.enc` into a single compressed archive.
> - `c` = create, `z` = gzip compress, `f` = filename follows.
> - → **Connects to:** `crypto/decrypt.sh` line 25 — `tar xzf package.tar` extracts them.

```bash
base64 -w 0 "$TEMP_DIR/package.tar" > "$OUTPUT" 2>/dev/null || base64 "$TEMP_DIR/package.tar" | tr -d '\n' > "$OUTPUT"
```
> **Line 37:** Converts the binary `.tar` to a base64 text string.
> - `-w 0` on Linux disables line wrapping, producing one continuous string. This is critical because the server splits messages on newlines.
> - macOS's `base64` doesn't support `-w 0`, so the `||` fallback uses `tr -d '\n'` to remove all newlines manually.
> - → **Connects to:** `client/send.sh` line 36 — `cat "$TEMP_B64"` sends this base64 string into the FIFO.
> - → **Connects to:** `crypto/decrypt.sh` line 22 — the reverse base64 decode happens there.

---

### `crypto/decrypt.sh`

**Role:** The exact reverse of `encrypt.sh`. Takes a base64 blob and outputs the original plaintext.

```bash
set -e
```
> **Line 2:** Tells Bash to exit immediately if any command fails. This is a safety net — if base64 decode fails, or `tar` fails, the script stops rather than continuing with corrupted data.
> - → **Connects to:** `client/listener.sh` line 31 — the listener checks `[ ! -s "$TEMP_OUT" ]` to detect if decrypt failed (which it would if `set -e` caused an exit).

```bash
PRIVATE_KEY=$(realpath "$1")
INPUT=$(realpath "$2")
OUTPUT=$(realpath "$3")
```
> **Lines 10–12:** Same `realpath` pattern as `encrypt.sh`, for the same reason — `cd "$TEMP_DIR"` later would break relative paths.
> - → **Connects to:** `client/listener.sh` line 29 — passes `private.pem`, the b64 temp file, and the output temp file.

```bash
base64 -d "$INPUT" > package.tar 2>/dev/null || base64 -D "$INPUT" > package.tar 2>/dev/null || base64 --decode "$INPUT" > package.tar
```
> **Line 22:** Three-way compatibility for base64 decoding: `-d` (Linux), `-D` (macOS), `--decode` (GNU fallback).
> - → **Connects to:** `crypto/encrypt.sh` line 37 — reverses the base64 encoding done there.

```bash
tar xzf package.tar
```
> **Line 25:** Extracts `key.enc` and `payload.enc` from the archive.
> - → **Connects to:** `crypto/encrypt.sh` line 32 — `tar czf` created this archive.

```bash
openssl rsautl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key 2>/dev/null || \
openssl pkeyutl -decrypt -inkey "$PRIVATE_KEY" -in key.enc -out aes.key
```
> **Lines 28–29:** RSA-decrypts `key.enc` using the recipient's **private** key to recover the AES key.
> - This only works if the private key matches the public key that was used to encrypt in `encrypt.sh` line 27.
> - → **Connects to:** `crypto/generate_keys.sh` line 22 — the private key was generated there.
> - → **Connects to:** `crypto/encrypt.sh` line 27 — the AES key was encrypted there.

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in payload.enc -out "$OUTPUT" -pass file:aes.key
```
> **Line 32:** Decrypts the payload using the recovered AES key. The `-d` flag means "decrypt" (vs encrypt in `encrypt.sh` line 23).
> - The flags `-aes-256-cbc -pbkdf2` must exactly match those used in `encrypt.sh` line 23.
> - `$OUTPUT` is the final plaintext file — this is what `listener.sh` reads for the message or file content.
> - → **Connects to:** `client/listener.sh` lines 37–55 — reads `$OUTPUT` and decides whether it's MSG or FILE.

```bash
cd - > /dev/null
rm -rf "$TEMP_DIR"
```
> **Lines 35–36:** Returns to the previous directory (`cd -`) and deletes all temporary files.
> - `> /dev/null` silences the `cd -` output (which prints the directory name).

---

## 7. Cross-File Connection Map

This table shows every major cross-file dependency in the project:

| When this runs... | ...it calls or connects to |
|---|---|
| `ciphershell.sh` option 1 | `server/server.sh` (line 30 → server.sh line 7) |
| `ciphershell.sh` option 2 | `client/register.sh` (line 39 → register.sh line 9) |
| `ciphershell.sh` option 3 | `client/client.sh` (line 55 → client.sh lines 4–7) |
| `ciphershell.sh` option 4 | `client/send.sh` (line 66 → send.sh lines 3–6) |
| `ciphershell.sh` option 5 | `client/send_file.sh` (line 78 → send_file.sh lines 3–5) |
| `ciphershell.sh` option 6 | `demo.sh` (line 83 → all of demo.sh) |
| `demo.sh` | `server/server.sh`, `client/register.sh`, `client/client.sh`, `client/send.sh`, `client/send_file.sh` |
| `server/server.sh` | `server/socket_mux.py` (line 16 → socket_mux.py line 78) |
| `client/register.sh` | `crypto/generate_keys.sh` (line 14), writes `server/users.db/` (line 17) |
| `client/client.sh` | Creates FIFOs used by `send.sh`, `send_file.sh`, and `listener.sh`; calls `listener.sh` (line 39) |
| `client/client.sh` login (line 35) | `socket_mux.py` LOGIN handler (lines 10–17) |
| `client/send.sh` | Reads `server/users.db/<recipient>.pub` (line 21), calls `crypto/encrypt.sh` (line 32), writes to FIFO → `socket_mux.py` SEND handler (lines 34–37) |
| `client/send_file.sh` | Same as `send.sh` + `listener.sh` FILE handler (lines 41–56) |
| `client/listener.sh` | Calls `crypto/decrypt.sh` (line 29), reads FROM `socket_mux.py` routing (line 40) |
| `crypto/generate_keys.sh` | Creates `private.pem` used by `decrypt.sh`; creates `public.pem` copied by `register.sh` |
| `crypto/encrypt.sh` | Uses `public.pem` from `users.db/`; output base64 sent by `send.sh`/`send_file.sh` |
| `crypto/decrypt.sh` | Uses `private.pem` from `~/.ciphershell/`; output read by `listener.sh` |

---

## 8. The Post Office Analogy

To make the whole system concrete, imagine a physical post office:

**Registration (`register.sh` + `generate_keys.sh`):**
You visit a locksmith who gives you:
- A **padlock** (your public key) — anyone can lock things with it
- A **unique key to that padlock** (your private key) — only you have this
You leave a copy of your padlock at the post office (`server/users.db/alice.pub`).

**Sending a message (`send.sh` + `encrypt.sh`):**
Alice wants to send Bob a letter.
1. She gets a random **combination lock** (the AES key) from a machine.
2. She locks her letter inside a **strongbox** using that combination (AES encrypt).
3. She locks the combination itself inside a **small box** using **Bob's padlock** from the post office (RSA encrypt).
4. She ships both boxes to the post office labeled `"To: Bob"`.

**The post office (`socket_mux.py`):**
The post office reads the label, finds Bob's mailbox, and drops both boxes in. It never had a key to anything — it just moved sealed boxes.

**Receiving (`listener.sh` + `decrypt.sh`):**
Bob picks up his mail.
1. He uses his **unique private key** to unlock the small box — gets the combination.
2. He dials the combination to open the strongbox — gets the letter.

**The FIFO pipes (`pipes/in`, `pipes/out`):**
Think of these as **mail slots** at Bob's house. His connection to the post office (`netcat`) is a dedicated mail truck parked outside. Anyone in the house (`send.sh`) can drop letters through the `in` slot, and the mail truck sends them. Letters arriving from the post office come through the `out` slot, where a dedicated mail-reader (`listener.sh`) watches and opens them.

---

## 9. Creative Extension Idea: Network Key Exchange

Right now, the `PUBLISH_KEY` command in `socket_mux.py` is a stub that does nothing:

```python
# socket_mux.py lines 54–56
elif len(parts) >= 2 and parts[0] == 'PUBLISH_KEY':
    # Optional: handling key publication
    pass
```

**The problem this creates:** Both users must be on the same machine (or share a filesystem) for `server/users.db/` to work. Two people on different computers across the internet can't use this system as-is.

**The fix — Network Key Exchange:**

You could complete the system so public keys are shared over the TCP connection itself:

**In `socket_mux.py`:**
```python
# Store public keys in a dict alongside clients
public_keys = {}

# In handle_client, handle PUBLISH_KEY:
elif parts[0] == 'PUBLISH_KEY' and len(parts) == 3:
    keyname = parts[1]
    key_data = parts[2]  # base64-encoded public key
    public_keys[keyname] = key_data

# Add a new GET_KEY command:
elif parts[0] == 'GET_KEY' and len(parts) == 2:
    keyname = parts[1]
    if keyname in public_keys:
        reply = f"KEY {keyname} {public_keys[keyname]}\n"
    else:
        reply = f"ERROR no key for {keyname}\n"
    writer.write(reply.encode())
    await writer.drain()
```

**In `register.sh`:** After generating keys, upload the public key:
```bash
# Base64 encode the public key (single line)
PUB_B64=$(base64 -w 0 ~/.ciphershell/$USERNAME/public.pem)
# Send it to the server through the TCP connection
echo "PUBLISH_KEY $USERNAME $PUB_B64" >&3
```

**In `send.sh`:** Before encrypting, fetch the key if not already local:
```bash
if [ ! -f "$PUB_KEY" ]; then
    echo "GET_KEY $RECIPIENT" >&3
    # Read the reply from pipes/out
    KEY_LINE=$(head -n 1 ~/.ciphershell/$SENDER/pipes/out)
    echo "$KEY_LINE" | cut -d' ' -f3- | base64 -d > "$PUB_KEY"
fi
```

This would make CipherShell a **genuine network-ready encrypted chat** where strangers on different computers could talk securely — the server would be the key broker, and all key material would flow through the same protocol already in place.

---

*Generated from the full source of CipherShell Chat — all line references point to exact lines in the files listed.*
