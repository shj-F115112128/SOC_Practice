"""從 zImage 取出 kernel 編譯時的 .config 和版本字串（kernel 有開 CONFIG_IKCONFIG 才有）。

zImage = 解壓程式 + gzip 壓縮的 kernel；kernel 裡的 config 也是 gzip，前面有 "IKCFG_ST" 標記。
用法：python extract_config.py ../../HW3/sd/zImage config-4.9.0-xilinx-v2017.4
"""
import sys
import zlib

src, dst = sys.argv[1], sys.argv[2]
img = open(src, 'rb').read()

pos = 0
while True:
    pos = img.find(b'\x1f\x8b\x08', pos)
    if pos < 0:
        sys.exit('找不到 gzip 壓縮的 kernel')
    try:
        kernel = zlib.decompressobj(31).decompress(img[pos:])
        break
    except zlib.error:
        pos += 1

ver = kernel.find(b'Linux version ')
print(kernel[ver:kernel.index(b'\n', ver)].decode())

mark = kernel.find(b'IKCFG_ST')
if mark < 0:
    sys.exit('kernel 沒有內嵌 config（CONFIG_IKCONFIG 沒開）')
config = zlib.decompressobj(31).decompress(kernel[mark + 8:])
open(dst, 'wb').write(config)
print('config ->', dst, len(config.splitlines()), 'lines')
