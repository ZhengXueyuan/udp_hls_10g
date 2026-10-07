#!/usr/bin/env python3
"""stage_scripts.py -- 把本地脚本推到对端机 (绕过 MSYS 对 Windows 路径参数的改写)。

用法: python stage_scripts.py <远端目录> <本地相对路径> [<本地相对路径> ...]
cwd 必须是本仓根 (udp_hls_10g)。
"""
import os
import sys

import paramiko

HOST = "192.168.0.38"


def main():
    remote_dir = sys.argv[1]
    locals_ = sys.argv[2:]
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="a", look_for_keys=True, allow_agent=False)
    sftp = c.open_sftp()
    try:
        sftp.stat(remote_dir)
    except IOError:
        sftp.mkdir(remote_dir)
    for rel in locals_:
        local = os.path.abspath(rel)
        assert os.path.exists(local), local
        remote = remote_dir.rstrip("/") + "/" + os.path.basename(rel)
        sftp.put(local, remote)
        sys.stdout.write("PUT OK %s -> %s\n" % (local, remote))
    sftp.close()
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
