"""EGO-XZ7 SD 開機測試：開 COM4，攔下 U-Boot 自動開機，在 console 選 kernel / device tree，登入 Linux 後跑檢查指令。
用法：python boot_test.py [COM4] [boot_ego|boot_zimage|boot_zybo|attach]
      attach = Linux 已經開好，直接登入跑檢查指令
需要 pip install pyserial。全部輸出寫到 boot_log.txt（同時印在螢幕上）。
"""
import sys, time, serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

port = sys.argv[1] if len(sys.argv) > 1 else "COM4"
boot = sys.argv[2] if len(sys.argv) > 2 else "boot_ego"
log = open("boot_log_attach.txt" if boot == "attach" else "boot_log.txt", "w", encoding="utf-8", newline="")
ser = serial.Serial(port, 115200, timeout=0.2)
buf = ""


def pump():
    global buf
    data = ser.read(4096).decode("utf-8", errors="replace")
    if data:
        buf += data
        log.write(data); log.flush()
        sys.stdout.write(data); sys.stdout.flush()


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


def send(line, wait=1.0):
    ser.write((line + "\n").encode())
    end = time.time() + wait
    while time.time() < end:
        pump()


def note(msg):
    log.write(f"\n##### {msg}\n"); log.flush()
    print(f"\n##### {msg}")


def uboot_console():
    note(f"等待開機訊息（{port}），請打開板子電源")
    if not expect("Hit any key to stop autoboot", 300):
        note("FAIL: 5 分鐘內沒看到 U-Boot 的 autoboot 提示"); sys.exit(1)
    send("", 0.5)
    if not expect("Zynq>", 10):
        note("WARN: 沒看到 U-Boot prompt，繼續嘗試")
    note("已進入 U-Boot console")
    send("version", 1)
    send("mmc info", 2)
    send("fatls mmc 0", 2)
    send(f"printenv {boot}", 1)
    note(f"run {boot}")
    send(f"run {boot}", 0)
    end = time.time() + 240
    while time.time() < end and "login:" not in buf and ":~# " not in buf:
        pump()
    if "login:" not in buf and ":~# " not in buf:
        note("FAIL: 4 分鐘內沒看到 Linux login / shell 提示"); sys.exit(1)


if boot == "attach":
    note("attach：Linux 已在執行")
    send("", 2)
    if "login:" in buf or expect("login:", 5):
        send("root", 2)
        if expect("assword", 3):
            send("root", 3)
    else:
        note("沒看到 login:，可能已經登入，直接執行指令")
else:
    uboot_console()
    if "login:" in buf:          # 這個 rootfs 預設 autologin，直接進 shell 就不用登入
        send("root", 2)
        if expect("assword", 3):
            send("root", 3)
note("已登入 Linux，執行檢查指令")
for cmd in ["uname -a", "cat /proc/device-tree/model; echo", "cat /proc/cmdline",
            "head -2 /proc/meminfo", "df -h", "mount", "ls -l /dev/uio* /sys/class/uio/",
            "cat /sys/class/uio/uio0/name /sys/class/uio/uio0/maps/map0/addr 2>/dev/null",
            "grep -iE 'uio|btn' /proc/interrupts"]:
    send(cmd, 2)
note("DONE")
