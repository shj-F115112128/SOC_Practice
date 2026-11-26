# HW4：driver（btnled.c -> btnled.ko）+ application（btnled_app.c -> btnled_app）
#
#   make            兩個都編
#   make module     只編 driver
#   make app        只編 application
#   make clean
#
# KDIR 指到已經 make modules_prepare 的 kernel 原始碼（build_kernel.sh 產生），要和板子上的 kernel 同版本、同 config

ifneq ($(KERNELRELEASE),)
# 被 kernel 的 Kbuild 讀進來時只看這行
obj-m := btnled.o
# gcc 9 搭配 4.9 的 module.h，module_init / module_exit 會出現 -Wmissing-attributes 警告（新版 kernel 已修），關掉
ccflags-y := -Wno-missing-attributes

else

KDIR          ?= $(HOME)/hw4/linux
ARCH          := arm
CROSS_COMPILE ?= arm-linux-gnueabihf-
PWD           := $(shell pwd)

# 板子 rootfs 的 glibc 比編譯機舊，application 用靜態連結
APP_CFLAGS    := -O2 -Wall -static -s

.PHONY: all module app clean

all: module app

module:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

app: btnled_app

btnled_app: btnled_app.c btnled.h
	$(CROSS_COMPILE)gcc $(APP_CFLAGS) -o $@ btnled_app.c

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
	rm -f btnled_app

endif
