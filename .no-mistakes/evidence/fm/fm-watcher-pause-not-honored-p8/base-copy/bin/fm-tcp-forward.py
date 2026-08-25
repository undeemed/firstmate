#!/usr/bin/env python3
"""Tiny TCP forwarder: expose a localhost-only service on an external port."""
import socket, socketserver, sys, threading

LISTEN_PORT, TARGET_PORT = int(sys.argv[1]), int(sys.argv[2])

class Fwd(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            up = socket.create_connection(("127.0.0.1", TARGET_PORT), timeout=10)
        except OSError:
            return
        def pipe(a, b):
            try:
                while True:
                    d = a.recv(65536)
                    if not d:
                        break
                    b.sendall(d)
            except OSError:
                pass
            finally:
                for s in (a, b):
                    try: s.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
        t = threading.Thread(target=pipe, args=(up, self.request), daemon=True)
        t.start()
        pipe(self.request, up)
        t.join()

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Srv(("0.0.0.0", LISTEN_PORT), Fwd).serve_forever()
