"""SMTP client checks for the smoke test, run inside the container's network namespace.

Mode "accept": the client is in mynetworks, so the banner, STARTTLS, the
absence of AUTH, relay refusal, unknown-recipient refusal, and delivery
through LMTP to the sink are each checked. Mode "refuse": the client is
outside mynetworks, so a recipient in a relay domain must be refused. Mode
"encrypt": STARTTLS is mandatory, so MAIL before STARTTLS must be refused
and a recipient accepted after it.
"""

import argparse
import pathlib
import smtplib
import ssl
import sys
import time
import uuid

failures = 0


def check(ok: bool, what: str) -> None:
    global failures
    print(f"{'PASS' if ok else 'FAIL'}: {what}", flush=True)
    if not ok:
        failures += 1


def rcpt_settled(smtp: smtplib.SMTP, address: str) -> tuple[int, bytes]:
    """RCPT, retried while Postfix answers 450 during recipient verification."""
    code, msg = 0, b""
    for _ in range(15):
        code, msg = smtp.rcpt(address)
        if code != 450:
            break
        time.sleep(2)
    return code, msg


def connect(args: argparse.Namespace) -> smtplib.SMTP:
    for _ in range(30):
        try:
            smtp = smtplib.SMTP(timeout=30)
            code, banner = smtp.connect(args.host, args.port)
            check(code == 220 and args.hostname.encode() in banner, f"banner names {args.hostname}: {code} {banner!r}")
            return smtp
        except OSError:
            time.sleep(1)
    check(False, f"connect to {args.host}:{args.port}")
    sys.exit(1)


def accept_mode(args: argparse.Namespace) -> None:
    smtp = connect(args)
    smtp.ehlo("client.test")
    check(("starttls" in smtp.esmtp_features) == args.tls, f"STARTTLS offered is {args.tls}")
    check("auth" not in smtp.esmtp_features, "AUTH is not offered before TLS")
    if args.tls:
        smtp.starttls(context=tls_context())
        version = smtp.sock.version()
        check(version in ("TLSv1.2", "TLSv1.3"), f"TLS session established: {version}")
        smtp.ehlo("client.test")
        check("auth" not in smtp.esmtp_features, "AUTH is not offered after TLS")

    smtp.mail("sender@client.test")
    code, msg = smtp.rcpt("someone@elsewhere.test")
    check(code == 554 and b"Relay access denied" in msg, f"relay to another domain refused: {code} {msg!r}")
    smtp.rset()

    smtp.mail("sender@client.test")
    code, msg = smtp.rcpt(f"{args.user}@sub.{args.domain}")
    check(code == 554 and b"Relay access denied" in msg, f"subdomain of a relay domain refused: {code} {msg!r}")
    smtp.rset()

    smtp.mail("sender@client.test")
    code, msg = rcpt_settled(smtp, f"nobody@{args.domain}")
    check(code == 550, f"unknown recipient refused by verification: {code} {msg!r}")
    smtp.rset()

    token = uuid.uuid4().hex
    smtp.mail("sender@client.test")
    code, msg = rcpt_settled(smtp, f"{args.user}@{args.domain}")
    check(code == 250, f"known recipient accepted: {code} {msg!r}")
    if code == 250:
        body = f"From: sender@client.test\r\nTo: {args.user}@{args.domain}\r\nSubject: smoke {token}\r\n\r\n{token}\r\n"
        code, msg = smtp.data(body)
        check(code == 250, f"message queued: {code} {msg!r}")
    smtp.quit()

    delivered = False
    for _ in range(60):
        if any(token in p.read_text(errors="replace") for p in args.spool.glob("*.eml")):
            delivered = True
            break
        time.sleep(1)
    check(delivered, "message delivered over LMTP to the sink")


def tls_context() -> ssl.SSLContext:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def encrypt_mode(args: argparse.Namespace) -> None:
    smtp = connect(args)
    smtp.ehlo("client.test")
    check("starttls" in smtp.esmtp_features, "STARTTLS offered")
    code, msg = smtp.mail("sender@client.test")
    check(code == 530 and b"STARTTLS" in msg, f"MAIL before STARTTLS refused: {code} {msg!r}")
    smtp.starttls(context=tls_context())
    version = smtp.sock.version()
    check(version in ("TLSv1.2", "TLSv1.3"), f"TLS session established: {version}")
    smtp.ehlo("client.test")
    smtp.mail("sender@client.test")
    code, msg = rcpt_settled(smtp, f"{args.user}@{args.domain}")
    check(code == 250, f"known recipient accepted after STARTTLS: {code} {msg!r}")
    smtp.quit()


def refuse_mode(args: argparse.Namespace) -> None:
    smtp = connect(args)
    smtp.ehlo("client.test")
    smtp.mail("sender@client.test")
    code, msg = smtp.rcpt(f"{args.user}@{args.domain}")
    check(code == 554 and b"Access denied" in msg, f"client outside mynetworks refused: {code} {msg!r}")
    smtp.quit()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["accept", "refuse", "encrypt"])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=25)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--user", default="user")
    parser.add_argument("--spool", type=pathlib.Path, default=pathlib.Path("/spool"))
    parser.add_argument("--tls", choices=["yes", "no"], default="yes")
    args = parser.parse_args()
    args.tls = args.tls == "yes"
    if args.mode == "accept":
        accept_mode(args)
    elif args.mode == "encrypt":
        encrypt_mode(args)
    else:
        refuse_mode(args)
    print(f"smoke_client {args.mode}: {failures} failure(s)", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
