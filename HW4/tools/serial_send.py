"""透過 COM4（板子的 Linux console）把檔案傳到板子上，不用網路、不用拔 SD 卡。

板子要已經開到 Linux shell（root 自動登入）。做法：
  電腦端 gzip 壓縮 -> uuencode 文字，一行一行打進板子的 heredoc；
  板子端用 perl 的 unpack("u") 解回 binary -> gunzip -> 檔案
  （板子的 busybox 沒有 base64 / uudecode，perl 是精簡版，unpack("m") 不能用，"u" 可以）
傳完用 md5sum 比對。

用法：python serial_send.py [--port COM4] 本機檔案 板子路徑 [本機檔案 板子路徑 ...]
例：  python serial_send.py ../src/btnled.ko /home/root/btnled.ko ../src/btnled_app /home/root/btnled_app
"""
import argparse
import binascii
import gzip
import hashlib
import os
import sys
import time

import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PROMPT = "# "


class Console:
    def __init__(self, port):
        self.ser = serial.Serial(port, 115200, timeout=0.05)
        self.buf = ""

    def pump(self):
        self.buf += self.ser.read(4096).decode("utf-8", errors="replace")

    def expect(self, pattern, timeout):
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            i = self.buf.find(pattern)
            if i >= 0:
                before = self.buf[:i]
                self.buf = self.buf[i + len(pattern):]
                return before
        raise TimeoutError(f"等不到 {pattern!r}，最後收到：{self.buf[-300:]!r}")

    def run(self, cmd, timeout=10):
        """執行一行指令，回傳輸出。結束標記寫成 $((1+1))，回顯的指令裡不會出現展開後的字串"""
        self.buf = ""
        self.ser.write((cmd + "; echo __E$((1+1))ND__\n").encode())
        out = self.expect("__E2ND__", timeout)
        self.expect(PROMPT, 5)
        lines = out.replace("\r", "").split("\n")
        return "\n".join(lines[1:]).strip()     # 第一行是回顯的指令

    def write(self, data):
        self.ser.write(data)
        n = self.ser.in_waiting                 # 只收已經到的回顯，不等 timeout
        if n:
            self.buf += self.ser.read(n).decode("utf-8", errors="replace")


DECODER = "perl -ne 'print unpack(\"u\", $_)'"


def send(con, data, dst):
    z = gzip.compress(data, 9)
    lines = [binascii.b2a_uu(z[i:i + 45], backtick=True).decode().rstrip("\n")
             for i in range(0, len(z), 45)]
    con.buf = ""
    con.write(f"{DECODER} << 'XEOF' | gunzip > {dst}\n".encode())
    t0 = time.time()
    for n, line in enumerate(lines, 1):
        con.write((line + "\n").encode())
        if n % 32 == 0 or n == len(lines):  # 等回顯追上再送，避免板子 tty 緩衝區滿掉資料
            con.expect(line, 10)
            rate = n * 45 / (time.time() - t0) / 1024
            print(f"\r  {n * 100 // len(lines):3d}%  {rate:5.1f} KB/s", end="", flush=True)
    con.write(b"XEOF\n")
    con.expect(PROMPT, 30)
    print(f"  {time.time() - t0:.0f} s（gzip 後 {len(z)} bytes）")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM4")
    ap.add_argument("pairs", nargs="+", help="本機檔案 板子路徑 ...")
    a = ap.parse_args()
    if len(a.pairs) % 2:
        sys.exit("參數要成對：本機檔案 板子路徑")

    con = Console(a.port)
    con.write(b"\x03\n")
    con.expect(PROMPT, 5)
    ok = True
    for src, dst in zip(a.pairs[0::2], a.pairs[1::2]):
        data = open(src, "rb").read()
        md5 = hashlib.md5(data).hexdigest()
        print(f"{src} -> {dst}（{len(data)} bytes）")
        send(con, data, dst)
        got = con.run(f"md5sum {dst}").split()
        if got and got[0] == md5:
            print(f"  md5 一致 {md5}")
            if "." not in os.path.basename(dst):     # 沒有副檔名的當執行檔
                con.run(f"chmod +x {dst}")
        else:
            print(f"  md5 不一致！本機 {md5}，板子 {got}")
            ok = False
    con.run("sync", 30)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
