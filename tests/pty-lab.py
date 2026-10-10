#!/usr/bin/env python3
"""pty-lab.py — interactive lab for the ob-sync marathon suite.

Two independent subcommands:

  serve   A fake GitHub: git smart-HTTP (git http-backend CGI) behind a
          Basic-auth gate. A request without valid credentials receives
          401 + WWW-Authenticate: Basic — exactly what makes git print
          "Username for 'https://...':" on /dev/tty. Optional TLS with a
          self-signed certificate so https:// remotes (and ob-sync's
          https-only code paths, e.g. ensure_credential_helper) can be
          exercised locally.

  drive   Spawn a command under a REAL pty and answer a scripted list of
          prompts. Every step is expect-gated (regex matched against the
          output produced since the previous step), so the driver never
          races the child: it sends only after the expected text has
          actually appeared. Full transcript is written to a file for
          post-mortem assertions (prompt counts, ordering, markers).

Both subcommands are stdlib-only (python3 >= 3.8).
"""

import argparse
import base64
import json
import os
import pty
import re
import select
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time

# ═══════════════════════════════════════════════════════════════════════
# serve — fake GitHub over (optional TLS) HTTP with Basic auth
# ═══════════════════════════════════════════════════════════════════════

def find_http_backend():
    for cand in (
        "/usr/lib/git-core/git-http-backend",
        "/usr/libexec/git-core/git-http-backend",
        shutil.which("git-http-backend") or "",
    ):
        if cand and os.path.exists(cand):
            return cand
    return None


def build_server(args):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    backend = find_http_backend()
    if not backend:
        sys.stderr.write("pty-lab serve: git http-backend not found\n")
        sys.exit(3)

    root = os.path.abspath(args.root)
    realm = "Fake GitHub"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *a):  # silence per-request noise
            pass

        def _auth_ok(self):
            header = self.headers.get("Authorization", "")
            if not header.startswith("Basic "):
                return False
            try:
                raw = base64.b64decode(header[6:].strip()).decode("utf-8")
                user, _, pw = raw.partition(":")
            except Exception:
                return False
            return user == args.user and pw == args.password

        def _deny(self):
            body = b"401 Unauthorized\n"
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="%s"' % realm)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _run_backend(self, body):
            parsed = self.path.split("?", 1)
            path = parsed[0]
            query = parsed[1] if len(parsed) > 1 else ""
            m = re.match(r"^/([^/]+\.git)(/.*)?$", path)
            if not m:
                self._deny()
                return
            repo, rest = m.group(1), m.group(2) or "/"
            env = os.environ.copy()
            env.update({
                "GIT_PROJECT_ROOT": root,
                "GIT_HTTP_EXPORT_ALL": "1",
                # http-backend derives the repository from PATH_INFO
                # (relative to GIT_PROJECT_ROOT); SCRIPT_NAME is only a
                # URL-generation prefix and must not repeat the repo.
                "PATH_INFO": "/%s%s" % (repo, rest),
                "REQUEST_METHOD": self.command,
                "QUERY_STRING": query,
                "REMOTE_USER": args.user,
                "REMOTE_ADDR": self.client_address[0],
                "GATEWAY_INTERFACE": "CGI/1.1",
                "SERVER_PROTOCOL": "HTTP/1.1",
            })
            if self.headers.get("Content-Type"):
                env["CONTENT_TYPE"] = self.headers["Content-Type"]
            env["CONTENT_LENGTH"] = str(len(body) if body else 0)

            proc = subprocess.Popen(
                [backend], env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            out, err = proc.communicate(body or b"")
            if err:
                try:
                    with open(args.log, "ab") as fh:
                        fh.write(err)
                except Exception:
                    pass

            # Split CGI headers from the body (CRLF or bare LF).
            head, body_out = b"", out or b""
            for sep in (b"\r\n\r\n", b"\n\n"):
                if sep in out:
                    head, body_out = out.split(sep, 1)
                    break
            status, ctype = 200, "application/octet-stream"
            for line in head.splitlines():
                text = line.decode("utf-8", "replace").strip()
                low = text.lower()
                if low.startswith("status:"):
                    try:
                        status = int(text.split(":", 1)[1].strip().split(" ")[0])
                    except Exception:
                        status = 500
                elif low.startswith("content-type:"):
                    ctype = text.split(":", 1)[1].strip()

            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body_out)))
            self.end_headers()
            self.wfile.write(body_out)

        def _dispatch(self):
            if not self._auth_ok():
                self._deny()
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else b""
            self._run_backend(body)

        def do_GET(self):
            self._dispatch()

        def do_POST(self):
            self._dispatch()

        def do_PROPFIND(self):  # never reached: remote is plain http(s)
            self._deny()

    httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    if args.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    actual_port = httpd.server_address[1]
    with open(args.ready, "w") as fh:
        fh.write(str(actual_port))
    sys.stderr.write("pty-lab serve: listening on %s port %d (root=%s)\n"
                     % ("https" if args.tls_cert else "http", actual_port, root))
    sys.stderr.flush()
    httpd.serve_forever()


# ═══════════════════════════════════════════════════════════════════════
# drive — real-pty prompt driver
# ═══════════════════════════════════════════════════════════════════════

def load_steps(path):
    """TSV: name <TAB> expect-regex <TAB> send ('<NL>' → newline, '-' → none)."""
    steps = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise SystemExit("pty-lab drive: bad step line %d: %r" % (lineno, line))
            name = parts[0]
            expect = parts[1]
            send = parts[2] if len(parts) > 2 else "-"
            send = "" if send == "-" else send.replace("<NL>", "\n")
            steps.append({"name": name, "expect": expect, "send": send})
    return steps


def drive(args):
    spec = json.load(open(args.spec, "r", encoding="utf-8")) if args.spec else {}
    argv = spec.get("argv") or args.argv
    if not argv:
        sys.exit("pty-lab drive: no argv")
    steps = load_steps(args.steps) if args.steps else spec.get("steps", [])
    env = spec.get("env", {})
    max_time = float(spec.get("max_time", args.max_time))
    step_timeout = float(spec.get("step_timeout", args.step_timeout))
    close_after_steps = bool(spec.get("close_after_steps", args.close_after_steps))
    transcript_path = args.transcript or spec.get("transcript") or (args.spec and os.path.join(
        os.path.dirname(os.path.abspath(args.spec)), "transcript.txt")) or "/tmp/pty-lab-transcript.txt"

    pid, master = pty.fork()
    if pid == 0:  # child: fresh session on the slave pty
        try:
            os.chdir(spec.get("cwd") or os.getcwd())
        except Exception:
            pass
        child_env = os.environ.copy()
        child_env.update({k: str(v) for k, v in env.items()})
        try:
            os.execvpe(argv[0], argv, child_env)
        except Exception:
            os._exit(127)

    buf = ""
    raw_parts = []
    anchor = 0            # per-step search window start
    idx = 0
    step_deadline = time.time() + step_timeout
    session_deadline = time.time() + max_time
    results = []
    closed = False

    def send_text(text):
        # Real people do not paste instantaneously; a naive single write()
        # right after the prompt's first bytes arrive can race the slave
        # line discipline and drop the leading character(s). Feed the
        # payload like a human: a short beat, then per-char with tiny
        # gaps, newline last.
        time.sleep(0.05)
        for ch in text:
            try:
                os.write(master, ch.encode("utf-8"))
            except OSError:
                return
            if ch != "\n":
                time.sleep(0.004)

    def finish(rc=None):
        if rc is None:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except Exception:
                pass
        try:
            _, status = os.waitpid(pid, 0)
            code = os.waitstatus_to_exitcode(status)
        except Exception:
            code = -1
        with open(transcript_path, "w", encoding="utf-8") as fh:
            fh.write(buf)
        doc = {
            "rc": code,
            "steps": results,
            "pending": [s["name"] for s in steps[idx:]],
            "transcript": transcript_path,
            "bytes": len(buf),
        }
        print(json.dumps(doc))
        return 0

    while True:
        try:
            r, _, _ = select.select([master], [], [], 0.1)
        except (OSError, ValueError):
            break
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break  # child closed the pty → exited
            text = chunk.decode("utf-8", "replace")
            raw_parts.append(text)
            buf += text
        else:
            # idle tick: evaluate pending step against the window
            pass

        if idx < len(steps):
            step = steps[idx]
            window = buf[anchor:]
            m = re.search(step["expect"], window)
            if m:
                results.append({"name": step["name"], "ok": True})
                if step["send"]:
                    payload = step["send"]
                    if payload == "<EOF>":
                        # Ctrl-D in canonical mode: read() returns 0 —
                        # the same EOF a closing terminal delivers.
                        time.sleep(0.05)
                        try:
                            os.write(master, b"\x04")
                        except OSError:
                            pass
                    else:
                        send_text(payload)
                # Advance the window to where the match ENDED: later
                # matches must be NEW occurrences (no re-matching the same
                # text), yet text printed after the match in the SAME
                # atomic chunk — a menu header followed by its prompt —
                # stays visible to the next step. (Advancing to len(buf)
                # deadlocked those cases; advancing to start() would
                # re-match the same occurrence forever.)
                anchor += m.end()
                idx += 1
                step_deadline = time.time() + step_timeout
                if idx >= len(steps) and close_after_steps and not closed:
                    closed = True
                    try:
                        os.close(master)
                    except OSError:
                        pass
                    continue
        else:
            if not close_after_steps:
                # All prompts answered; wait for a natural exit (EOF).
                step_deadline = min(step_deadline, session_deadline)

        if time.time() > step_deadline or time.time() > session_deadline:
            results.extend({"name": s["name"], "ok": False, "timed_out": True}
                           for s in steps[idx:])
            buf += "\n[[pty-lab: TIMEOUT while waiting for %s]]\n" % (
                steps[idx]["expect"] if idx < len(steps) else "exit")
            return finish()

    # EOF from the child
    results.extend({"name": s["name"], "ok": False, "missed": True}
                   for s in steps[idx:])
    return finish()


# ═══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="pty lab for ob-sync tests")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="fake GitHub (git smart http + basic auth)")
    s.add_argument("--root", required=True, help="GIT_PROJECT_ROOT")
    s.add_argument("--user", required=True)
    s.add_argument("--password", required=True)
    s.add_argument("--bind", default="127.0.0.1")
    s.add_argument("--port", type=int, default=0)
    s.add_argument("--tls-cert", default="")
    s.add_argument("--tls-key", default="")
    s.add_argument("--ready", required=True, help="file to write the bound port to")
    s.add_argument("--log", default="/tmp/pty-lab-serve.log")
    s.set_defaults(func=lambda a: build_server(a) or 0)

    d = sub.add_parser("drive", help="run a command under a real pty, answer prompts")
    d.add_argument("--spec", help="JSON spec file (argv/env/steps/…)")
    d.add_argument("--steps", help="TSV step file (name\\texpect\\tsend)")
    d.add_argument("--transcript", default="")
    d.add_argument("--step-timeout", type=float, default=60.0)
    d.add_argument("--max-time", type=float, default=420.0)
    d.add_argument("--close-after-steps", action="store_true")
    d.add_argument("argv", nargs="*")
    d.set_defaults(func=drive)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
