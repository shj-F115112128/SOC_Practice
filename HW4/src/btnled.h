/*
 * btnled.h - driver（btnled.c）和 application（btnled_app.c）共用的定義
 *
 * /dev/btnled 的用法：
 *   read()   取出 ISR 收到的按鈕事件，每筆是一個 struct btnled_event；沒有事件就睡著等（O_NONBLOCK 則回 -EAGAIN）
 *   write()  把 32-bit 值寫進 IP 暫存器，寫到哪一個由檔案位置決定（lseek 設 offset），寫完位置往後移 4
 *   lseek()  選暫存器 offset（0x00～0x3C，4 的倍數）
 *   ioctl()  單一暫存器讀寫、清空事件佇列、查詢統計
 */
#ifndef BTNLED_H
#define BTNLED_H

#ifdef __KERNEL__
#include <linux/ioctl.h>
#include <linux/types.h>
#else
#include <sys/ioctl.h>
#include <stdint.h>
typedef uint32_t __u32;
#endif

#define BTNLED_DEV_NAME     "btnled"
#define BTNLED_REG_SPAN     0x40        /* 16 個 32-bit 暫存器 */

/* btn_led_ctrl 暫存器 offset（同 HW2 版本二） */
#define BTNLED_CTRL         0x00        /* bit0 mode：0 恆亮、1 呼吸 */
#define BTNLED_STATUS       0x04        /* bit0 防彈跳後的按鈕電位（唯讀） */
#define BTNLED_INT_STATUS   0x08        /* bit[4:0] pending，寫 1 清除 */
#define BTNLED_INT_ENABLE   0x0C        /* bit[4:0] 各中斷開關 */
#define BTNLED_DATA_IN      0x10        /* CPU 寫給 IP 的資料 */
#define BTNLED_DATA_OUT     0x14        /* 中斷時鎖住 DATA_IN + EVENT_CNT（唯讀） */
#define BTNLED_EVENT_CNT    0x18        /* 中斷事件次數（唯讀） */
#define BTNLED_HOLD_MS      0x1C        /* 最近一次按住幾 ms（唯讀） */
#define BTNLED_SPEED        0x20        /* bit[1:0] 呼吸速度 */
#define BTNLED_BRIGHT       0x24        /* bit[4:0] 恆亮亮度 0～31 */

/* INT_STATUS / INT_ENABLE 的 bit */
#define BTNLED_EV_PRESS     0x01
#define BTNLED_EV_RELEASE   0x02
#define BTNLED_EV_CLICK     0x04
#define BTNLED_EV_DOUBLE    0x08
#define BTNLED_EV_LONG      0x10
#define BTNLED_EV_ALL       0x1F

/* read() 一次讀出的一筆事件 */
struct btnled_event {
	__u32 seq;          /* driver 給的流水號，從 1 開始 */
	__u32 status;       /* ISR 讀到的 INT_STATUS & INT_ENABLE */
	__u32 event_cnt;    /* EVENT_CNT */
	__u32 hold_ms;      /* HOLD_MS */
	__u32 data_out;     /* DATA_OUT */
};

/* ioctl 的參數 */
struct btnled_reg {
	__u32 offset;
	__u32 value;
};

struct btnled_stats {
	__u32 irq_count;    /* ISR 被呼叫的次數 */
	__u32 queued;       /* 佇列裡還沒被 read() 取走的事件數 */
	__u32 dropped;      /* 佇列滿了被丟掉的事件數 */
	__u32 major;
	__u32 minor;
};

#define BTNLED_IOC_MAGIC    'b'
#define BTNLED_IOC_RD_REG   _IOWR(BTNLED_IOC_MAGIC, 1, struct btnled_reg)
#define BTNLED_IOC_WR_REG   _IOW(BTNLED_IOC_MAGIC, 2, struct btnled_reg)
#define BTNLED_IOC_FLUSH    _IO(BTNLED_IOC_MAGIC, 3)
#define BTNLED_IOC_STATS    _IOR(BTNLED_IOC_MAGIC, 4, struct btnled_stats)

#endif
