# HW3 的 ego.dtb -> HW4 用的 hw4.dtb
#   btn_led_ctrl@43c00000 的 compatible 從 "generic-uio" 改成 "nkust,btn-led-ctrl-1.0"
#   generic-uio 編在 kernel 裡，開機就會搶走節點；改掉之後節點留給 btnled.ko，insmod 時才比對 probe
#   reg、interrupts、clocks 不變
# 用法：python make_hw4_dtb.py ../../HW3/sd/ego.dtb ../sd/hw4.dtb   （需要 pip install fdt）
# 另外輸出 dts/hw4.dts 方便閱讀
import os
import sys
import fdt

src, dst = sys.argv[1], sys.argv[2]
t = fdt.parse_dtb(open(src, 'rb').read())
node = t.get_node('/amba_pl/btn_led_ctrl@43c00000')
node.set_property('compatible', 'nkust,btn-led-ctrl-1.0')
open(dst, 'wb').write(t.to_dtb(version=17))
dts = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hw4.dts')
open(dts, 'w', newline=chr(10)).write(t.to_dts())
print('ok', dst)
print(node)
