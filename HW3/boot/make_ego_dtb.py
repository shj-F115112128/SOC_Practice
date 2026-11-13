# Zybo Z7 的 system.dtb -> EGO-XZ7 用的 ego.dtb
#   拿掉 amba_pl（Zybo 板上 PL 的 HDMI、VDMA、MIPI 等周邊，EGO-XZ7 的 bitstream 裡沒有）
#   換成 HW2 版本二的 btn_led_ctrl（generic-uio，Linux 會產生 /dev/uio0）
# 用法：python make_ego_dtb.py prebuilt/system.dtb ../sd/ego.dtb   （需要 pip install fdt）
# 另外輸出 boot/ego.dts 方便閱讀
import os, sys, fdt
src, dst = sys.argv[1], sys.argv[2]
t = fdt.parse_dtb(open(src, 'rb').read())
t.remove_node('amba_pl', '/')
pl = fdt.Node('amba_pl')
pl.append(fdt.PropWords('#address-cells', 1))
pl.append(fdt.PropWords('#size-cells', 1))
pl.append(fdt.PropStrings('compatible', 'simple-bus'))
pl.append(fdt.Property('ranges'))
n = fdt.Node('btn_led_ctrl@43c00000')
n.append(fdt.PropStrings('compatible', 'generic-uio'))
n.append(fdt.PropWords('reg', 0x43C00000, 0x10000))
n.append(fdt.PropWords('interrupt-parent', 4))      # GIC（interrupt-controller@f8f01000）的 phandle
n.append(fdt.PropWords('interrupts', 0, 29, 4))     # SPI 29（= IRQ ID 61 - 32）、4 = level high
n.append(fdt.PropWords('clocks', 1, 15))            # clkc 的 fclk0（50 MHz）
pl.append(n)
t.add_item(pl, '/')
root = t.get_node('/')
root.set_property('model', 'EGO-XZ7 (Zynq XC7Z020)')
open(dst, 'wb').write(t.to_dtb(version=17))
dts = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ego.dts')
open(dts, 'w', newline=chr(10)).write(t.to_dts())
print('ok', dst)
