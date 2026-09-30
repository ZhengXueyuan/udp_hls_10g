#!/usr/bin/env python3
"""peer_ssh.py -- non-interactive access to the peer Linux box (192.168.0.38).

WHY: this is the single shared entry point so that concurrent agents do not each
     invent their own ssh hack.  It adds two things plain `ssh` does not give you:
     a uniform `--sudo` that feeds the password on stdin, and sftp put/get.

AUTH: user `a` with the existing `~/.ssh/id_ed25519` key (no password needed).
      `PEER_PW` (env, never persisted -- project rule "密码不落盘") is used ONLY
      for `--sudo`, not for login.

USAGE
    python tools/peer_ssh.py "ethtool -S enp1s0f1np1 | head -40"
    PEER_PW=... python tools/peer_ssh.py --sudo "dmesg | tail -20"
    python tools/peer_ssh.py --put local.bin /tmp/local.bin
    python tools/peer_ssh.py --get /tmp/out.log ./out.log
    python tools/peer_ssh.py --timeout 120 "sleep 90; echo done"

Exit status = the remote command's exit status (0 on success).  255 = transport error.
stdout/stderr are forwarded as-is (utf-8, errors=replace) so that callers can grep them.
"""

import argparse
import os
import sys

import paramiko

HOST_DEFAULT = "192.168.0.38"
USER_DEFAULT = "a"


def _client(args):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        hostname=args.host,
        username=args.user,
        timeout=args.connect_timeout,
        banner_timeout=60,
        auth_timeout=60,
        look_for_keys=True,
        allow_agent=False,
    )
    return c


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("command", nargs="?", help="remote shell command")
    ap.add_argument("-H", "--host", default=HOST_DEFAULT)
    ap.add_argument("-u", "--user", default=USER_DEFAULT)
    ap.add_argument("--sudo", action="store_true",
                    help="wrap the command in `sudo -S -p ''` (password fed on stdin)")
    ap.add_argument("--put", nargs=2, metavar=("LOCAL", "REMOTE"))
    ap.add_argument("--get", nargs=2, metavar=("REMOTE", "LOCAL"))
    ap.add_argument("--timeout", type=float, default=300.0,
                    help="remote command timeout in seconds (default 300)")
    ap.add_argument("--connect-timeout", type=float, default=15.0)
    args = ap.parse_args()

    if not args.command and not args.put and not args.get:
        ap.error("nothing to do: give a command, --put or --get")

    c = _client(args)
    try:
        if args.put:
            sftp = c.open_sftp()
            sftp.put(args.put[0], args.put[1])
            sftp.close()
            sys.stdout.write("PUT OK %s -> %s\n" % (args.put[0], args.put[1]))
            return 0

        if args.get:
            sftp = c.open_sftp()
            sftp.get(args.get[0], args.get[1])
            sftp.close()
            sys.stdout.write("GET OK %s -> %s\n" % (args.get[0], args.get[1]))
            return 0

        cmd = args.command
        if args.sudo:
            # -S reads the password from stdin; -p '' suppresses the prompt text
            cmd = "sudo -S -p '' bash -lc %s" % _shq(cmd)
            stdin, stdout, stderr = c.exec_command(cmd, timeout=args.timeout,
                                                   get_pty=False)
            stdin.write(os.environ["PEER_PW"] + "\n")
            stdin.flush()
        else:
            stdin, stdout, stderr = c.exec_command(cmd, timeout=args.timeout)

        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        rc = stdout.channel.recv_exit_status()
        sys.stdout.write(out)
        if err:
            sys.stderr.write(err)
        return rc
    finally:
        c.close()


def _shq(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # transport-level failure
        sys.stderr.write("peer_ssh: %s: %s\n" % (type(exc).__name__, exc))
        sys.exit(255)
