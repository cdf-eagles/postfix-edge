"""A minimal LMTP server for the smoke test.

Accepts RCPT only for the addresses given with --accept, answers 550 for any
other, and writes each delivered message to the spool directory.
"""

import argparse
import pathlib
import signal
import socketserver
import sys
import time


class LMTPHandler(socketserver.StreamRequestHandler):
    def reply(self, line: str) -> None:
        self.wfile.write(line.encode("ascii") + b"\r\n")
        self.wfile.flush()

    def handle(self) -> None:
        accepted: list[str] = []
        self.reply("220 sink LMTP ready")
        while True:
            raw = self.rfile.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            verb = line.split(" ", 1)[0].upper()
            if verb == "LHLO":
                self.reply("250 sink")
            elif verb == "MAIL":
                accepted = []
                self.reply("250 2.1.0 OK")
            elif verb == "RCPT":
                address = line.split(":", 1)[1].strip().split(" ", 1)[0].strip("<>").lower()
                if address in self.server.accept:
                    accepted.append(address)
                    self.reply("250 2.1.5 OK")
                else:
                    self.reply("550 5.1.1 User unknown")
            elif verb == "DATA":
                if not accepted:
                    self.reply("503 5.5.1 No valid recipients")
                    continue
                self.reply("354 Go ahead")
                body = self.read_data()
                name = f"{time.time_ns()}.eml"
                (self.server.spool / name).write_bytes(body)
                for _ in accepted:
                    self.reply("250 2.0.0 Delivered")
                accepted = []
            elif verb in ("RSET", "NOOP"):
                accepted = [] if verb == "RSET" else accepted
                self.reply("250 2.0.0 OK")
            elif verb == "QUIT":
                self.reply("221 2.0.0 Bye")
                return
            else:
                self.reply("502 5.5.2 Command not recognised")

    def read_data(self) -> bytes:
        lines = []
        while True:
            raw = self.rfile.readline()
            if not raw or raw in (b".\r\n", b".\n"):
                return b"".join(lines)
            lines.append(raw[1:] if raw.startswith(b"..") else raw)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=24)
    parser.add_argument("--spool", type=pathlib.Path, required=True)
    parser.add_argument("--accept", action="append", required=True)
    args = parser.parse_args()
    args.spool.mkdir(parents=True, exist_ok=True)
    # As PID 1 in its container, the sink gets no default SIGTERM action.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with Server((args.listen, args.port), LMTPHandler) as server:
        server.accept = {a.lower() for a in args.accept}
        server.spool = args.spool
        print(f"lmtp_sink: listening on {args.listen}:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
