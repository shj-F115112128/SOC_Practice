"""HW4 上板測試：透過 COM4 在板子的 Linux shell 依序執行 insmod / lsmod / ls /dev / app / rmmod，輸出存成 log。

用法：python hw4_test.py [--port COM4] [--reboot] [--watch N] [--log ../log/hw4_test.txt]
  --reboot   先 reboot，等 U-Boot 用 boot_hw4（hw4.dtb）開回 Linux shell
  --watch N  app 等 N 筆按鈕事件（要有人按 S6），0 = 不測按鈕
檔案（btnled.ko、btnled_app）放在 SD 卡根目錄，板子上是 /run/media/mmcblk0p1
"""
import argparse
import sys
import time

import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ap = argparse.ArgumentParser()
ap.add_argument("--port", default="COM4")
ap.add_argument("--reboot", action="store_true")
ap.add_argument("--watch", type=int, default=0)
ap.add_argument("--log", default="hw4_test.txt")
a = ap.parse_args()

ser = serial.Serial(a.port, 115200, timeout=0.1)
log = open(a.log, "w", encoding="utf-8", newline="\n")
buf = ""


def pump():
    global buf
    d = ser.read(4096).decode("utf-8", errors="replace").replace("\r", "").replace("\0", "")
    if d:
        buf += d
        log.write(d); log.flush()
        sys.stdout.write(d); sys.stdout.flush()


def expect(pattern, timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        pump()
        i = buf.find(pattern)
        if i >= 0:
            buf = buf[i + len(pattern):]
            return True
    return False


def sh(cmd, timeout=10):
    """執行一行指令，等到 shell 提示字元"""
    global buf
    buf = ""
    ser.write((cmd + "\n").encode())
    if not expect(":~# " if cmd.startswith("cd ~") else "# ", timeout):
        print(f"\n##### 等不到提示字元：{cmd}")


def note(msg):
    log.write(f"\n##### {msg}\n"); log.flush()
    print(f"\n##### {msg}")


ser.write(b"\x03\n")
expect("# ", 5)

if a.reboot:
    note("reboot，U-Boot 預設跑 boot_hw4（uImage + uramdisk.image.gz + hw4.dtb）")
    ser.write(b"reboot\n")
    if not expect("Hit any key to stop autoboot", 120):
        sys.exit("沒看到 U-Boot")
    if not expect("[boot_hw4]", 30):
        note("WARN: 沒看到 [boot_hw4]")
    if not expect("login:", 240) and ":~# " not in buf:
        pass
    time.sleep(3)
    ser.write(b"\n")
    expect("# ", 10)

D = "/run/media/mmcblk0p1"
steps = [
    ("開機確認：kernel、device tree 節點", [
        "uname -r",
        "cat /proc/device-tree/amba_pl/btn_led_ctrl@43c00000/compatible; echo",
        "ls /dev/uio* /dev/btnled",
        f"cd {D}; ls -l btnled.ko btnled_app",
    ]),
    ("③ insmod -> lsmod -> ls /dev -> ./btnled_app", [
        "insmod btnled.ko",
        "lsmod",
        "grep btnled /proc/devices",
        "ls -l /dev/btnled",
        "dmesg | grep -i btnled",
        "grep btnled /proc/interrupts",
        "./btnled_app info",
        "./btnled_app bright 8; ./btnled_app mode 0; ./btnled_app info | grep -E 'CTRL|BRIGHT'",
        "./btnled_app bright 31",
    ]),
]
for title, cmds in steps:
    note(title)
    for c in cmds:
        sh(c)

if a.watch > 0:
    note(f"./btnled_app watch {a.watch}：請按 S6（單擊 / 雙擊 / 長按）")
    sh(f"./btnled_app watch {a.watch}", 600)
    sh("grep btnled /proc/interrupts")
    sh("./btnled_app info | head -1")

note("③ rmmod -> lsmod -> ./btnled_app（driver 移除後 open 失敗）")
for c in ["rmmod btnled", "lsmod", "grep btnled /proc/devices; ls -l /dev/btnled",
          "./btnled_app info; echo exit=$?", "dmesg | grep -i btnled | tail -2"]:
    sh(c)
note("DONE")
