/*
 * btnled_app.c - /dev/btnled 的 user program
 *
 * 用法：
 *   ./btnled_app                 等按鈕事件（同 HW2 版本二：單擊切換模式、雙擊換亮度、長按換呼吸速度），Ctrl-C 結束
 *   ./btnled_app watch <N>       同上，收到 N 筆事件後結束
 *   ./btnled_app info            印出 major / minor、統計、全部暫存器
 *   ./btnled_app mode <0|1>      0 恆亮、1 呼吸
 *   ./btnled_app speed <0~3>     呼吸速度
 *   ./btnled_app bright <0~31>   恆亮亮度
 *
 * open → read / write / lseek / ioctl → close
 * driver 沒載入時 /dev/btnled 不存在，open 會失敗。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include "btnled.h"

#define DEV_PATH        "/dev/" BTNLED_DEV_NAME
#define DATA_IN_VALUE   1000u

static const char *const speed_text[4] = { "3.75 s", "1.9 s", "0.94 s", "0.47 s" };
static const unsigned int bright_level[3] = { 31, 8, 2 };

static volatile sig_atomic_t stop;

static void on_sigint(int sig)
{
	(void)sig;
	stop = 1;
}

/* write()：lseek 到暫存器 offset，再寫 4 bytes */
static int reg_write(int fd, unsigned int off, unsigned int val)
{
	if (lseek(fd, off, SEEK_SET) < 0 || write(fd, &val, 4) != 4) {
		perror("write");
		return -1;
	}
	return 0;
}

/* 讀暫存器用 ioctl（read() 拿來取事件） */
static unsigned int reg_read(int fd, unsigned int off)
{
	struct btnled_reg r = { off, 0 };

	if (ioctl(fd, BTNLED_IOC_RD_REG, &r) < 0)
		perror("ioctl RD_REG");
	return r.value;
}

static void show_info(int fd)
{
	static const char *const names[10] = {
		"CTRL", "STATUS", "INT_STATUS", "INT_ENABLE", "DATA_IN",
		"DATA_OUT", "EVENT_CNT", "HOLD_MS", "SPEED", "BRIGHT"
	};
	struct btnled_stats s;
	unsigned int i;

	if (ioctl(fd, BTNLED_IOC_STATS, &s) == 0)
		printf("%s  major %u  minor %u  irq %u  queued %u  dropped %u\n",
		       DEV_PATH, s.major, s.minor, s.irq_count, s.queued, s.dropped);
	for (i = 0; i < 10; i++)
		printf("  0x%02X %-10s = 0x%08X\n", i * 4, names[i], reg_read(fd, i * 4));
}

static void ev_names(unsigned int st, char *out)
{
	out[0] = '\0';
	if (st & BTNLED_EV_PRESS)   strcat(out, " PRESS");
	if (st & BTNLED_EV_RELEASE) strcat(out, " RELEASE");
	if (st & BTNLED_EV_CLICK)   strcat(out, " CLICK");
	if (st & BTNLED_EV_DOUBLE)  strcat(out, " DOUBLE");
	if (st & BTNLED_EV_LONG)    strcat(out, " LONG");
}

static int watch(int fd, int limit)
{
	struct btnled_event ev[8];
	unsigned int mode, speed, bidx = 0;
	int total = 0;

	reg_write(fd, BTNLED_DATA_IN, DATA_IN_VALUE);
	ioctl(fd, BTNLED_IOC_FLUSH);
	mode = reg_read(fd, BTNLED_CTRL) & 1;
	speed = reg_read(fd, BTNLED_SPEED) & 3;
	printf("DATA_IN = %u, mode %s, speed %s；按 S6（單擊 / 雙擊 / 長按），Ctrl-C 結束\n",
	       DATA_IN_VALUE, mode ? "BREATH" : "FIXED", speed_text[speed]);

	while (!stop && (limit <= 0 || total < limit)) {
		ssize_t n = read(fd, ev, sizeof(ev));   /* 沒事件時睡在 driver 裡，ISR 叫醒 */
		int i, cnt;

		if (n < 0) {
			if (errno == EINTR)
				break;
			perror("read");
			return -1;
		}
		cnt = n / sizeof(ev[0]);
		for (i = 0; i < cnt; i++) {
			char names[64];

			ev_names(ev[i].status, names);
			printf("#%-3u INT_STATUS 0x%02X%-14s EVENT_CNT %-4u DATA_OUT %-5u",
			       ev[i].seq, ev[i].status, names, ev[i].event_cnt, ev[i].data_out);
			if (ev[i].status & BTNLED_EV_RELEASE)
				printf(" hold %u ms", ev[i].hold_ms);

			if (ev[i].status & BTNLED_EV_CLICK) {
				mode ^= 1;
				reg_write(fd, BTNLED_CTRL, mode);
				printf(" -> mode %s", mode ? "BREATH" : "FIXED");
			}
			if (ev[i].status & BTNLED_EV_DOUBLE) {
				bidx = (bidx + 1) % 3;
				reg_write(fd, BTNLED_BRIGHT, bright_level[bidx]);
				printf(" -> bright %u", bright_level[bidx]);
			}
			if (ev[i].status & BTNLED_EV_LONG) {
				speed = (speed + 1) & 3;
				reg_write(fd, BTNLED_SPEED, speed);
				printf(" -> speed %s", speed_text[speed]);
			}
			printf("\n");
			total++;
		}
		fflush(stdout);
	}
	printf("收到 %d 筆事件\n", total);
	return 0;
}

int main(int argc, char *argv[])
{
	const char *cmd = argc > 1 ? argv[1] : "watch";
	int fd, ret = 0;

	fd = open(DEV_PATH, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s（driver 載入了嗎？insmod btnled.ko）\n", DEV_PATH, strerror(errno));
		return 1;
	}
	signal(SIGINT, on_sigint);

	if (strcmp(cmd, "watch") == 0) {
		ret = watch(fd, argc > 2 ? atoi(argv[2]) : 0);
	} else if (strcmp(cmd, "info") == 0) {
		show_info(fd);
	} else if (argc > 2 && strcmp(cmd, "mode") == 0) {
		ret = reg_write(fd, BTNLED_CTRL, strtoul(argv[2], NULL, 0) & 1);
	} else if (argc > 2 && strcmp(cmd, "speed") == 0) {
		ret = reg_write(fd, BTNLED_SPEED, strtoul(argv[2], NULL, 0) & 3);
	} else if (argc > 2 && strcmp(cmd, "bright") == 0) {
		ret = reg_write(fd, BTNLED_BRIGHT, strtoul(argv[2], NULL, 0) & 31);
	} else {
		fprintf(stderr, "usage: %s [watch [N] | info | mode 0|1 | speed 0-3 | bright 0-31]\n", argv[0]);
		ret = 2;
	}

	close(fd);
	return ret ? 1 : 0;
}
