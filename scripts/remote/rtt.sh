#!/usr/bin/env bash
# TCP round-trip time between VMs: 64-byte ping-pong over one persistent connection (no ICMP, which Azure
# deprioritises, and no per-connection setup cost).
#
#   rtt.sh serve PORT SECONDS        echo server on PORT for SECONDS (run detached on every host)
#   rtt.sh probe PORT NAME=IP...     2000 round trips per target after 200 warm-up ones; one JSON line per target
set -euo pipefail
mode="${1:?serve|probe}"; shift
exec python3 -I - "$mode" "$@" <<'PY'
import json, socket, socketserver, statistics, sys, threading, time

mode, port = sys.argv[1], int(sys.argv[2])

class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        while True:
            data = self.request.recv(64)
            if not data:
                return
            self.request.sendall(data)

if mode == "serve":
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer.daemon_threads = True
    server = socketserver.ThreadingTCPServer(("0.0.0.0", port), Echo)
    threading.Timer(float(sys.argv[3]), server.shutdown).start()
    server.serve_forever()
    sys.exit(0)

payload = b"x" * 64
for pair in sys.argv[3:]:
    name, ip = pair.split("=", 1)
    result = {"from": socket.gethostname(), "to": name, "ip": ip, "method": "tcp-64B-pingpong"}
    try:
        sock = socket.create_connection((ip, port), timeout=5)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        samples = []
        for i in range(2200):
            start = time.perf_counter_ns()
            sock.sendall(payload)
            got = 0
            while got < len(payload):
                chunk = sock.recv(64 - got)
                if not chunk:
                    raise ConnectionError("closed")
                got += len(chunk)
            if i >= 200:
                samples.append((time.perf_counter_ns() - start) / 1000)
        sock.close()
        samples.sort()
        q = lambda p: round(samples[min(len(samples) - 1, int(p * len(samples)))], 1)
        result.update({"samples": len(samples), "min_us": round(samples[0], 1), "p50_us": q(0.5),
                       "p90_us": q(0.9), "p99_us": q(0.99), "max_us": round(samples[-1], 1),
                       "mean_us": round(statistics.fmean(samples), 1)})
    except OSError as err:
        result["error"] = str(err)
    print(json.dumps(result), flush=True)
PY
