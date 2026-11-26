/*
 * btnled.c - HW2 版本二 btn_led_ctrl（AXI4-Lite IP）的 Linux character device driver
 * EGO-XZ7 (Zynq-7000)，kernel 4.9.0-xilinx-v2017.4
 *
 * device tree 節點（compatible = "nkust,btn-led-ctrl-1.0"）提供暫存器位址和 IRQ，
 * platform driver 比對到節點後：
 *   1. inode id    dev_t = (major, minor)，/dev/btnled 的 inode 用它找到這個 driver
 *   2. cdev 註冊   cdev_add() 把 file_operations 掛到 dev_t 上
 *   3. region 申請 alloc_chrdev_region()（或 register_chrdev_region()）跟 kernel 要 major / minor
 *   4. ISR 安裝    devm_request_irq()，S6 的手勢中斷經 IRQ_F2P[0]（GIC ID 61）進來
 *   5. critical section  ISR 和 read() 共用事件佇列，用 spinlock 保護
 * 程式裡依實際執行順序排列，各段標上對應編號。
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/poll.h>
#include <linux/clk.h>
#include <linux/slab.h>
#include "btnled.h"

#define QUEUE_LEN   32          /* 事件佇列大小，2 的冪次 */
#define READ_MAX    16          /* read() 一次最多取幾筆 */

static int major;               /* 0 = 讓 kernel 分配；insmod btnled.ko major=240 可指定 */
module_param(major, int, 0444);
MODULE_PARM_DESC(major, "major number (0 = dynamic)");

struct btnled_dev {
	void __iomem *base;
	int irq;
	struct clk *clk;
	struct cdev cdev;
	struct device *dev;

	/* 5. critical section：下面這些欄位 ISR 和 read()/ioctl() 都會碰，一律在 lock 裡存取 */
	spinlock_t lock;
	struct btnled_event queue[QUEUE_LEN];
	unsigned int head;          /* 下一筆寫入位置（ISR） */
	unsigned int tail;          /* 下一筆讀出位置（read） */
	u32 seq;
	u32 irq_count;
	u32 dropped;

	wait_queue_head_t wq;       /* read() 沒事件時睡在這裡，ISR 叫醒 */
};

static dev_t btnled_devt;       /* 1. inode id：MKDEV(major, minor) */
static struct class *btnled_class;

static unsigned int queued(struct btnled_dev *bd)
{
	return bd->head - bd->tail;
}

/* ---------- 4. ISR ---------- */

static irqreturn_t btnled_isr(int irq, void *dev_id)
{
	struct btnled_dev *bd = dev_id;
	struct btnled_event ev;
	u32 st;

	st = readl(bd->base + BTNLED_INT_STATUS) & readl(bd->base + BTNLED_INT_ENABLE);
	if (!st)
		return IRQ_NONE;

	/* level 中斷：一定要先清 IP 的 pending（W1C），否則 irq 一直是 High，離開 ISR 又馬上進來 */
	writel(st, bd->base + BTNLED_INT_STATUS);

	ev.status = st;
	ev.event_cnt = readl(bd->base + BTNLED_EVENT_CNT);
	ev.hold_ms = readl(bd->base + BTNLED_HOLD_MS);
	ev.data_out = readl(bd->base + BTNLED_DATA_OUT);

	spin_lock(&bd->lock);           /* ISR 裡中斷已關，不用 irqsave */
	bd->irq_count++;
	ev.seq = ++bd->seq;
	if (queued(bd) == QUEUE_LEN) {  /* 滿了丟最舊的一筆 */
		bd->tail++;
		bd->dropped++;
	}
	bd->queue[bd->head++ % QUEUE_LEN] = ev;
	spin_unlock(&bd->lock);

	wake_up_interruptible(&bd->wq);
	return IRQ_HANDLED;
}

/* ---------- file operations ---------- */

static int btnled_open(struct inode *inode, struct file *f)
{
	/* inode->i_rdev 就是 (major, minor)，i_cdev 指回 cdev_add() 註冊的 cdev */
	f->private_data = container_of(inode->i_cdev, struct btnled_dev, cdev);
	return 0;
}

static int btnled_release(struct inode *inode, struct file *f)
{
	return 0;
}

/* read()：取出事件，沒有就睡著等 ISR 叫醒 */
static ssize_t btnled_read(struct file *f, char __user *buf, size_t len, loff_t *ppos)
{
	struct btnled_dev *bd = f->private_data;
	struct btnled_event evs[READ_MAX];
	unsigned long flags;
	unsigned int want, n;

	want = min_t(size_t, len / sizeof(struct btnled_event), READ_MAX);
	if (want == 0)
		return -EINVAL;

	for (;;) {
		spin_lock_irqsave(&bd->lock, flags);
		for (n = 0; n < want && queued(bd); n++)
			evs[n] = bd->queue[bd->tail++ % QUEUE_LEN];
		spin_unlock_irqrestore(&bd->lock, flags);
		if (n)
			break;

		if (f->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible(bd->wq, READ_ONCE(bd->head) != READ_ONCE(bd->tail)))
			return -ERESTARTSYS;    /* 被 Ctrl-C 之類的 signal 打斷 */
	}

	if (copy_to_user(buf, evs, n * sizeof(struct btnled_event)))
		return -EFAULT;
	return n * sizeof(struct btnled_event);
}

/* write()：從目前檔案位置（暫存器 offset）開始，一次寫一個 32-bit */
static ssize_t btnled_write(struct file *f, const char __user *buf, size_t len, loff_t *ppos)
{
	struct btnled_dev *bd = f->private_data;
	u32 val[BTNLED_REG_SPAN / 4];
	size_t i, words;

	if ((*ppos & 3) || (len & 3) || len == 0)
		return -EINVAL;
	if (*ppos >= BTNLED_REG_SPAN)
		return -ENOSPC;
	words = min_t(size_t, len / 4, (BTNLED_REG_SPAN - *ppos) / 4);
	if (copy_from_user(val, buf, words * 4))
		return -EFAULT;

	for (i = 0; i < words; i++) {
		writel(val[i], bd->base + *ppos);
		*ppos += 4;
	}
	return words * 4;
}

/* lseek()：選暫存器，範圍 0 ~ 0x40 */
static loff_t btnled_llseek(struct file *f, loff_t off, int whence)
{
	return fixed_size_llseek(f, off, whence, BTNLED_REG_SPAN);
}

static unsigned int btnled_poll(struct file *f, poll_table *wait)
{
	struct btnled_dev *bd = f->private_data;

	poll_wait(f, &bd->wq, wait);
	if (READ_ONCE(bd->head) != READ_ONCE(bd->tail))
		return POLLIN | POLLRDNORM;
	return 0;
}

static long btnled_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct btnled_dev *bd = f->private_data;
	void __user *uarg = (void __user *)arg;
	struct btnled_reg r;
	struct btnled_stats s;
	unsigned long flags;

	switch (cmd) {
	case BTNLED_IOC_RD_REG:
	case BTNLED_IOC_WR_REG:
		if (copy_from_user(&r, uarg, sizeof(r)))
			return -EFAULT;
		if (r.offset >= BTNLED_REG_SPAN || (r.offset & 3))
			return -EINVAL;
		if (cmd == BTNLED_IOC_WR_REG) {
			writel(r.value, bd->base + r.offset);
			return 0;
		}
		r.value = readl(bd->base + r.offset);
		return copy_to_user(uarg, &r, sizeof(r)) ? -EFAULT : 0;

	case BTNLED_IOC_FLUSH:
		spin_lock_irqsave(&bd->lock, flags);
		bd->tail = bd->head;
		spin_unlock_irqrestore(&bd->lock, flags);
		return 0;

	case BTNLED_IOC_STATS:
		spin_lock_irqsave(&bd->lock, flags);
		s.irq_count = bd->irq_count;
		s.queued = queued(bd);
		s.dropped = bd->dropped;
		spin_unlock_irqrestore(&bd->lock, flags);
		s.major = MAJOR(btnled_devt);
		s.minor = MINOR(btnled_devt);
		return copy_to_user(uarg, &s, sizeof(s)) ? -EFAULT : 0;
	}
	return -ENOTTY;
}

static const struct file_operations btnled_fops = {
	.owner          = THIS_MODULE,
	.open           = btnled_open,
	.release        = btnled_release,
	.read           = btnled_read,
	.write          = btnled_write,
	.llseek         = btnled_llseek,
	.poll           = btnled_poll,
	.unlocked_ioctl = btnled_ioctl,
};

/* ---------- platform driver ---------- */

static int btnled_probe(struct platform_device *pdev)
{
	struct btnled_dev *bd;
	struct resource *res;
	int ret;

	bd = devm_kzalloc(&pdev->dev, sizeof(*bd), GFP_KERNEL);
	if (!bd)
		return -ENOMEM;
	spin_lock_init(&bd->lock);
	init_waitqueue_head(&bd->wq);
	platform_set_drvdata(pdev, bd);

	/* device tree 的 reg = <0x43c00000 0x10000> */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	bd->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(bd->base))
		return PTR_ERR(bd->base);

	/* device tree 的 clocks = <&clkc 15>（FCLK0），PL 沒時脈的話 AXI 存取會卡住 */
	bd->clk = devm_clk_get(&pdev->dev, NULL);
	if (IS_ERR(bd->clk))
		bd->clk = NULL;
	ret = clk_prepare_enable(bd->clk);
	if (ret)
		return ret;

	/* 先關掉 IP 的中斷、清掉開機前留下的 pending，再掛 ISR */
	writel(0, bd->base + BTNLED_INT_ENABLE);
	writel(BTNLED_EV_ALL, bd->base + BTNLED_INT_STATUS);

	/* 4. ISR 安裝：device tree 的 interrupts = <0 29 4>（SPI 29 = GIC ID 61，level high） */
	bd->irq = platform_get_irq(pdev, 0);
	if (bd->irq < 0) {
		ret = bd->irq;
		goto err_clk;
	}
	ret = devm_request_irq(&pdev->dev, bd->irq, btnled_isr, 0, BTNLED_DEV_NAME, bd);
	if (ret)
		goto err_clk;

	/* 2. cdev 註冊：把 file_operations 掛到 dev_t 上，之後 open /dev/btnled 會進 btnled_open */
	cdev_init(&bd->cdev, &btnled_fops);
	bd->cdev.owner = THIS_MODULE;
	ret = cdev_add(&bd->cdev, btnled_devt, 1);
	if (ret)
		goto err_clk;

	/* 在 /sys/class/btnled/btnled 產生 uevent，udev 據此建立 /dev/btnled */
	bd->dev = device_create(btnled_class, &pdev->dev, btnled_devt, bd, BTNLED_DEV_NAME);
	if (IS_ERR(bd->dev)) {
		ret = PTR_ERR(bd->dev);
		goto err_cdev;
	}

	writel(BTNLED_EV_ALL, bd->base + BTNLED_INT_ENABLE);
	dev_info(&pdev->dev, "/dev/%s major %d minor %d, regs %pa, irq %d\n",
		 BTNLED_DEV_NAME, MAJOR(btnled_devt), MINOR(btnled_devt), &res->start, bd->irq);
	return 0;

err_cdev:
	cdev_del(&bd->cdev);
err_clk:
	clk_disable_unprepare(bd->clk);
	return ret;
}

static int btnled_remove(struct platform_device *pdev)
{
	struct btnled_dev *bd = platform_get_drvdata(pdev);

	writel(0, bd->base + BTNLED_INT_ENABLE);
	device_destroy(btnled_class, btnled_devt);
	cdev_del(&bd->cdev);
	clk_disable_unprepare(bd->clk);
	/* ISR 和 ioremap 是 devm_ 申請的，remove 之後 kernel 自動釋放 */
	return 0;
}

static const struct of_device_id btnled_of_match[] = {
	{ .compatible = "nkust,btn-led-ctrl-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, btnled_of_match);

static struct platform_driver btnled_driver = {
	.probe  = btnled_probe,
	.remove = btnled_remove,
	.driver = {
		.name           = BTNLED_DEV_NAME,
		.of_match_table = btnled_of_match,
	},
};

/* ---------- insmod / rmmod ---------- */

static int __init btnled_init(void)
{
	int ret;

	/* 3. region 申請：major=0 時動態分配，否則用指定的 major；minor 從 0 開始要 1 個 */
	if (major) {
		btnled_devt = MKDEV(major, 0);
		ret = register_chrdev_region(btnled_devt, 1, BTNLED_DEV_NAME);
	} else {
		ret = alloc_chrdev_region(&btnled_devt, 0, 1, BTNLED_DEV_NAME);
	}
	if (ret)
		return ret;
	/* 申請成功後 /proc/devices 會出現 "<major> btnled" */

	btnled_class = class_create(THIS_MODULE, BTNLED_DEV_NAME);
	if (IS_ERR(btnled_class)) {
		ret = PTR_ERR(btnled_class);
		goto err_region;
	}

	ret = platform_driver_register(&btnled_driver);
	if (ret)
		goto err_class;

	pr_info("btnled: loaded, major %d minor %d\n", MAJOR(btnled_devt), MINOR(btnled_devt));
	return 0;

err_class:
	class_destroy(btnled_class);
err_region:
	unregister_chrdev_region(btnled_devt, 1);
	return ret;
}

static void __exit btnled_exit(void)
{
	platform_driver_unregister(&btnled_driver);
	class_destroy(btnled_class);
	unregister_chrdev_region(btnled_devt, 1);
	pr_info("btnled: unloaded\n");
}

module_init(btnled_init);
module_exit(btnled_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SOC_Practice HW4");
MODULE_DESCRIPTION("btn_led_ctrl char device driver (EGO-XZ7)");
