"""Relay usbmuxd from Windows' Apple Mobile Device Service into WSL.

USB passthrough with usbipd stalls on large transfers (xtool reports
`muxError`), so xtool in WSL talks to the iPad through Windows instead:

    xtool (WSL) -> 127.0.0.1:27115 in WSL (`listen`, run under WSL python3)
                -> stdin/stdout of `bridge` (run under Windows python.exe via WSL interop)
                -> 127.0.0.1:27015 on Windows (Apple Mobile Device Service)

The WSL side must not listen on 27015: WSL forwards its localhost ports to
Windows, so the Apple service could not bind 27015 (it hangs in "starting")
and each bridge would connect back into the relay, spawning bridges forever.

No firewall rule or portproxy (admin rights) is needed. Usually started by
scripts/xtool-wsl.sh rather than by hand.
"""

import os
import socket
import subprocess
import sys
import threading

APPLE_PORT = 27015  # Apple Mobile Device Service on Windows
RELAY_PORT = 27115  # this relay inside WSL; must differ from APPLE_PORT


def pump(read, write, close):
    try:
        while True:
            data = read(65536)
            if not data:
                break
            write(data)
    except OSError:
        pass
    finally:
        close()


def bridge():
    """Windows side: stdin/stdout <-> Apple Mobile Device Service."""
    sock = socket.create_connection(("127.0.0.1", APPLE_PORT))
    stdin, stdout = sys.stdin.buffer.raw, sys.stdout.buffer.raw

    def write_out(data):
        view = memoryview(data)
        while view:
            view = view[stdout.write(view):]

    def close_in():
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    upstream = threading.Thread(target=pump, args=(stdin.read, sock.sendall, close_in), daemon=True)
    upstream.start()
    pump(sock.recv, write_out, lambda: None)


def listen(windows_python, windows_script):
    """WSL side: one Windows bridge process per usbmuxd client connection."""
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", RELAY_PORT))
    server.listen()
    print(f"usbmuxd relay listening on 127.0.0.1:{RELAY_PORT}", flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client, windows_python, windows_script), daemon=True).start()


def serve(client, windows_python, windows_script):
    proc = subprocess.Popen(
        [windows_python, windows_script, "bridge"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0,
    )

    def close_stdin():
        try:
            proc.stdin.close()
        except OSError:
            pass

    threading.Thread(target=pump, args=(client.recv, proc.stdin.write, close_stdin), daemon=True).start()
    pump(proc.stdout.read, client.sendall, lambda: None)
    client.close()
    proc.wait()


if __name__ == "__main__":
    if sys.argv[1:2] == ["bridge"]:
        bridge()
    elif sys.argv[1:2] == ["listen"] and len(sys.argv) == 4:
        listen(sys.argv[2], sys.argv[3])
    else:
        sys.exit(f"usage: {os.path.basename(__file__)} listen <windows python.exe> <windows path of this script> | bridge")
