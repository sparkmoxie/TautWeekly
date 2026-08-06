#!/usr/bin/env python3
"""Protocol-level tests for the dependency-free TautWeekly SMTP transport."""

from __future__ import annotations

import argparse
import base64
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path


USERNAME = "sender@example.com"
PASSWORD = "test token with spaces"


class SmtpState:
    def __init__(self, mechanisms: tuple[str, ...], reject_password: bool = False) -> None:
        self.mechanisms = mechanisms
        self.reject_password = reject_password
        self.commands: list[str] = []
        self.data_lines: list[str] = []
        self.error: BaseException | None = None


class SmtpHandler(socketserver.StreamRequestHandler):
    def _send(self, line: str) -> None:
        self.wfile.write((line + "\r\n").encode("ascii"))
        self.wfile.flush()

    def _read(self) -> str:
        raw = self.rfile.readline()
        if not raw:
            raise ConnectionError("client closed the SMTP connection")
        return raw.decode("utf-8").rstrip("\r\n")

    def handle(self) -> None:
        state: SmtpState = self.server.state  # type: ignore[attr-defined]
        authenticated = False
        login_step = ""
        try:
            self._send("220 mock.tautweekly.test ESMTP")
            while True:
                line = self._read()
                state.commands.append(line)
                upper = line.upper()

                if login_step == "username":
                    if line != base64.b64encode(USERNAME.encode()).decode():
                        raise AssertionError("AUTH LOGIN username did not match")
                    login_step = "password"
                    self._send("334 UGFzc3dvcmQ6")
                elif login_step == "password":
                    if line != base64.b64encode(PASSWORD.encode()).decode():
                        raise AssertionError("AUTH LOGIN password did not match")
                    login_step = ""
                    if state.reject_password:
                        self._send("535 5.7.1 Username and Password not accepted")
                    else:
                        authenticated = True
                        self._send("235 2.7.0 Authentication successful")
                elif login_step == "plain":
                    expected = base64.b64encode(("\0" + USERNAME + "\0" + PASSWORD).encode()).decode()
                    if line != expected:
                        raise AssertionError("AUTH PLAIN credential payload did not match")
                    login_step = ""
                    if state.reject_password:
                        self._send("535 5.7.1 Username and Password not accepted")
                    else:
                        authenticated = True
                        self._send("235 2.7.0 Authentication successful")
                elif upper.startswith("EHLO "):
                    self._send("250-mock.tautweekly.test")
                    self._send("250-AUTH " + " ".join(state.mechanisms))
                    self._send("250 SIZE 10485760")
                elif upper == "AUTH LOGIN":
                    if "LOGIN" not in state.mechanisms:
                        self._send("504 5.7.4 Unrecognized Authentication Type")
                    else:
                        login_step = "username"
                        self._send("334 VXNlcm5hbWU6")
                elif upper.startswith("AUTH LOGIN "):
                    # This is the legacy form that triggered Proton's skipped-auth path.
                    self._send("535 5.5.4 Optional Argument not permitted for that AUTH mode")
                elif upper == "AUTH PLAIN":
                    if "PLAIN" not in state.mechanisms:
                        self._send("504 5.7.4 Unrecognized Authentication Type")
                    else:
                        login_step = "plain"
                        self._send("334 ")
                elif upper.startswith("MAIL FROM:"):
                    if not authenticated:
                        self._send("550 5.7.1 Sender address rejected: not logged in")
                    else:
                        self._send("250 2.1.0 Sender accepted")
                elif upper.startswith("RCPT TO:"):
                    self._send("250 2.1.5 Recipient accepted")
                elif upper == "DATA":
                    self._send("354 End data with <CR><LF>.<CR><LF>")
                    while True:
                        data_line = self._read()
                        if data_line == ".":
                            break
                        state.data_lines.append(data_line)
                    self._send("250 2.0.0 Queued")
                elif upper == "QUIT":
                    self._send("221 2.0.0 Bye")
                    break
                else:
                    self._send("500 5.5.2 Command unrecognized")
        except (BrokenPipeError, ConnectionResetError, ConnectionError):
            # Expected when an authentication-failure test closes the connection.
            return
        except BaseException as exc:  # surfaced in the main test thread
            state.error = exc


class TestServer(socketserver.TCPServer):
    allow_reuse_address = True

    def __init__(self, state: SmtpState) -> None:
        self.state = state
        super().__init__(("127.0.0.1", 0), SmtpHandler)


def powershell_executable() -> str:
    for name in ("pwsh", "pwsh.exe", "powershell.exe", "powershell"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("PowerShell was not found")


def run_client(helper: Path, port: int, method: str) -> subprocess.CompletedProcess[str]:
    script = f"""
$ErrorActionPreference = 'Stop'
. '{str(helper).replace("'", "''")}'
$probe = [IO.MemoryStream]::new()
$probeWriter = [IO.StreamWriter]::new($probe, [Text.UTF8Encoding]::new($false), 1024, $true)
$probeWriter.NewLine = "`r`n"
Write-TautWeeklySmtpData -Writer $probeWriter -MimeText "first`r`n.leading dot"
$probeWriter.Flush()
$probeText = [Text.Encoding]::UTF8.GetString($probe.ToArray())
$probeWriter.Dispose()
$probe.Dispose()
if (-not $probeText.Contains("first`r`n..leading dot`r`n.`r`n")) {{
    throw 'SMTP DATA dot-stuffing regression'
}}
$mail = [System.Net.Mail.MailMessage]::new()
try {{
    $mail.From = [System.Net.Mail.MailAddress]::new('{USERNAME}', 'TautWeekly test')
    [void]$mail.To.Add('recipient@example.com')
    $mail.Subject = 'SMTP protocol regression'
    $mail.Body = "first line`r`n.leading dot"
    $config = [pscustomobject]@{{
        SmtpHost = '127.0.0.1'
        SmtpPort = {port}
        SmtpEnableSsl = $false
        SmtpUseAuthentication = $true
        SmtpUsername = '{USERNAME}'
        SmtpPassword = '{PASSWORD}'
        SmtpStripPasswordSpaces = $false
        SmtpAuthenticationMethod = '{method}'
        SmtpTimeoutSeconds = 10
    }}
    Send-TautWeeklySmtpMessage -MailMessage $mail -Config $config
}}
finally {{
    $mail.Dispose()
}}
"""
    with tempfile.TemporaryDirectory(prefix="tautweekly-smtp-test-") as temporary:
        path = Path(temporary) / "client.ps1"
        path.write_text(script, encoding="utf-8")
        command = [powershell_executable(), "-NoLogo", "-NoProfile"]
        if os.name == "nt":
            command.extend(["-ExecutionPolicy", "Bypass"])
        command.extend(["-File", str(path)])
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )


def scenario(helper: Path, mechanisms: tuple[str, ...], method: str, reject: bool = False) -> SmtpState:
    state = SmtpState(mechanisms, reject_password=reject)
    server = TestServer(state)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = run_client(helper, server.server_address[1], method)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    if state.error:
        raise state.error
    if reject:
        if result.returncode == 0:
            raise AssertionError("SMTP client accepted rejected credentials")
        if any(command.upper().startswith("MAIL FROM:") for command in state.commands):
            raise AssertionError("SMTP client sent MAIL FROM after failed authentication")
    else:
        if result.returncode != 0:
            raise AssertionError(f"PowerShell SMTP client failed:\n{result.stdout}\n{result.stderr}")
        auth_index = next(i for i, command in enumerate(state.commands) if command.upper().startswith("AUTH "))
        mail_index = next(i for i, command in enumerate(state.commands) if command.upper().startswith("MAIL FROM:"))
        if auth_index >= mail_index:
            raise AssertionError("SMTP envelope started before authentication")
    return state


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--helper",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "platforms" / "windows" / "Smtp-Transport.ps1",
    )
    args = parser.parse_args()
    helper = args.helper.resolve()
    if not helper.is_file():
        raise FileNotFoundError(helper)

    login = scenario(helper, ("LOGIN", "PLAIN"), "Auto")
    if "AUTH LOGIN" not in login.commands:
        raise AssertionError("Auto did not prefer challenge-style AUTH LOGIN")
    if any(command.upper().startswith("AUTH LOGIN ") for command in login.commands):
        raise AssertionError("AUTH LOGIN incorrectly included an optional initial response")

    plain = scenario(helper, ("PLAIN",), "Plain")
    if "AUTH PLAIN" not in plain.commands:
        raise AssertionError("Explicit AUTH PLAIN was not used")

    scenario(helper, ("LOGIN", "PLAIN"), "Auto", reject=True)
    print("[PASS] SMTP LOGIN/PLAIN authentication completes before MAIL FROM and failed auth stops delivery.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
