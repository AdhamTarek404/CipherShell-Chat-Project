import asyncio
import sys

clients = {}

async def handle_client(reader, writer):
    username = None
    try:
        # Increase read limit to 50MB for file transfers
        line = await reader.readline()
        if not line:
            return
        parts = line.decode(errors='ignore').strip().split(' ', 1)
        if len(parts) != 2 or parts[0] != 'LOGIN':
            writer.close()
            return
        username = parts[1]
        if username in clients:
            try:
                clients[username].close()
            except Exception:
                pass
        clients[username] = writer
        print(f"User {username} connected.", flush=True)
        
        while True:
            line = await reader.readline()
            if not line:
                break
            msg = line.decode(errors='ignore').strip()
            if not msg:
                continue
                
            parts = msg.split(' ', 2)
            if len(parts) == 3 and parts[0] == 'SEND':
                recipient = parts[1]
                payload = parts[2]
                
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
                else:
                    # Send error back to sender
                    err_msg = f"ERROR {recipient} is not online\n"
                    writer.write(err_msg.encode())
                    await writer.drain()
            elif len(parts) >= 2 and parts[0] == 'PUBLISH_KEY':
                # Optional: handling key publication
                pass
    except asyncio.LimitOverrunError:
        print(f"Payload too large from {username}", flush=True)
    except Exception as e:
        print(f"Error handling {username}: {e}", flush=True)
    finally:
        writer.close()
        if username and username in clients and clients[username] == writer:
            del clients[username]
            print(f"User {username} disconnected.", flush=True)

async def main(port):
    server = await asyncio.start_server(
        handle_client, '0.0.0.0', port,
        limit=1024 * 1024 * 50 # 50 MB limit
    )
    addr = server.sockets[0].getsockname()
    print(f'Serving CipherShell Relay on {addr}', flush=True)
    async with server:
        await server.serve_forever()

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    try:
        asyncio.run(main(port))
    except KeyboardInterrupt:
        print("\nServer shutting down.")
