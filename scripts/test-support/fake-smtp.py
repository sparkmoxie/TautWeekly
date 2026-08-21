#!/usr/bin/env python3
"""Minimal deterministic SMTP sink for renderer integration tests."""

from __future__ import annotations

import argparse
import json
import socketserver
from pathlib import Path


class Handler(socketserver.StreamRequestHandler):
    def send(self, line: str) -> None:
        self.wfile.write((line + "\r\n").encode("ascii"))
        self.wfile.flush()

    def read(self) -> str:
        line = self.rfile.readline()
        if not line:
            raise ConnectionError("SMTP client disconnected")
        return line.decode("utf-8", errors="replace").rstrip("\r\n")

    def record(self, command: str) -> None:
        with self.server.call_log.open("a", encoding="utf-8") as handle:  # type: ignore[attr-defined]
            handle.write(json.dumps({"command": command}) + "\n")

    def handle(self) -> None:
        self.send("220 smtp.tautweekly.test ESMTP")
        while True:
            line = self.read()
            upper = line.upper()
            self.record(line)
            if upper.startswith("EHLO "):
                self.send("250-smtp.tautweekly.test")
                self.send("250 SIZE 10485760")
            elif upper.startswith("RCPT TO:") and any(value in line.lower() for value in self.server.reject_recipients):  # type: ignore[attr-defined]
                self.send("550 Rejected by virtual recipient policy")
            elif upper.startswith("MAIL FROM:") or upper.startswith("RCPT TO:"):
                self.send("250 Accepted")
            elif upper == "DATA":
                self.send("354 End data with <CR><LF>.<CR><LF>")
                data_lines: list[str] = []
                while True:
                    data_line = self.read()
                    if data_line == ".":
                        break
                    if data_line.startswith(".."):
                        data_line = data_line[1:]
                    data_lines.append(data_line)
                data_file: Path | None = self.server.data_file  # type: ignore[attr-defined]
                if data_file is not None:
                    data_file.write_bytes(("\r\n".join(data_lines) + "\r\n").encode("utf-8"))
                self.send("250 Queued")
            elif upper == "QUIT":
                self.send("221 Bye")
                return
            else:
                self.send("500 Unsupported command")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--call-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--data-file", type=Path)
    parser.add_argument("--reject-recipient", action="append", default=[])
    args = parser.parse_args()

    args.call_log.write_text("", encoding="utf-8")
    with Server(("127.0.0.1", args.port), Handler) as server:
        server.call_log = args.call_log  # type: ignore[attr-defined]
        server.data_file = args.data_file  # type: ignore[attr-defined]
        server.reject_recipients = [value.lower() for value in args.reject_recipient]  # type: ignore[attr-defined]
        args.ready_file.write_text(str(server.server_address[1]), encoding="utf-8")
        server.serve_forever()


if __name__ == "__main__":
    main()
