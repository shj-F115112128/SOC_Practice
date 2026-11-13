"""不拔 SD 卡更新 BOOT.BIN：JTAG 載入 U-Boot -> 攔下 autoboot -> JTAG 把 sd/BOOT.BIN 下載到 DDR -> U-Boot fatwrite 寫回 SD 卡。
用法（在 HW3/tools/ 目錄下）：python update_bootbin.py [COM4]
需要 pip install pyserial；序列埠不能同時被其他終端機程式佔用
"""
import os, subprocess, sys, time, serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
XSCT = r"C:\Xilinx\SDK\2018.2\bin\xsct.bat"
here = os.path.dirname(os.path.abspath(__file__))
bootbin = os.path.abspath(os.path.join(here, "..", "sd", "BOOT.BIN"))
size = os.path.getsize(bootbin)
ADDR = 0x08000000

ser = serial.Serial(port, 115200, timeout=0.2)
buf = ""


def pump():
    global buf
    d = ser.read(4096).decode("utf-8", errors="replace")
    if d:
        buf += d
        sys.stdout.write(d); sys.stdout.flush()


def expect(p, t):
    global buf
    end = time.time() + t
    while time.time() < end:
        pump()
        i = buf.find(p)
        if i >= 0:
            buf = buf[i + len(p):]
            return True
    return False


def send(line, wait=1.0):
    ser.write((line + "\n").encode())
    end = time.time() + wait
    while time.time() < end:
        pump()


xsct = subprocess.Popen(["cmd", "/c", XSCT, "jtag_uboot.tcl"], cwd=here,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if not expect("Hit any key to stop autoboot", 120):
    sys.exit("FAIL: 沒看到 U-Boot autoboot 提示")
send("", 0.5)
if not expect("Zynq>", 5):
    sys.exit("FAIL: 沒進到 U-Boot console")
xsct.wait()

tcl = os.path.join(here, "dow_bootbin.tcl")
open(tcl, "w").write(
    "connect\ntargets -set -filter {name =~ \"*#0\"}\ncatch {stop}\n"
    f"dow -data {{{bootbin}}} 0x{ADDR:08X}\ncon\n")
r = subprocess.run(["cmd", "/c", XSCT, tcl], cwd=here, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("FAIL: JTAG 下載 BOOT.BIN 失敗\n" + r.stdout[-2000:] + r.stderr[-2000:])

send("", 1)
send(f"fatwrite mmc 0 0x{ADDR:08X} BOOT.BIN 0x{size:X}", 8)
send("fatls mmc 0", 2)
print(f"\n##### BOOT.BIN（{size} bytes）已寫入 SD 卡")
