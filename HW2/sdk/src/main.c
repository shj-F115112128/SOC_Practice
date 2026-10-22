/*
 * HW2 - S6 按鈕中斷切換 LED0 固定恆亮 / 2 秒呼吸燈
 * 平台：EGO-XZ7 (Zynq-7000), Xilinx SDK standalone BSP
 *
 * 硬體分工（vivado/create_bd.tcl）：
 *   - S6 (BTNC) = PL pin P16，按下 = 1。按鈕經過 PL：
 *       P16 -> btn_debounce.v（同步 + 20ms 防彈跳）-> axi_gpio_btn（開 interrupt）
 *           -> ip2intc_irpt -> PS7 IRQ_F2P[0] -> GIC（IRQ ID 61）-> CPU IRQ -> S6IntrHandler
 *   - LED0 = PL pin T22，由 PL 的 pwm_breath.v 驅動；呼吸燈 PWM 全部在硬體裡做
 *   - CPU 只透過 M_AXI_GP0 -> axi_gpio_mode 寫 1 bit 的 mode 給 pwm_breath：
 *     0 = 恆亮、1 = 2 秒呼吸
 *
 * 中斷相關設定一律直接讀寫暫存器（Xil_In32 / Xil_Out32）：
 *
 *   項目                 PL：axi_gpio_btn（PG144）           GIC（IRQ ID 61 = ICD*1 bit29）
 *   1. IRQ #：port       GPIO 通道 1 bit0 -> IRQ_F2P[0]       IRQ ID 61（UG585 p.238 Table 7-4）
 *   2. pending：status   IPISR 0x120 bit0                     ICDISPR1 0xF8F01204（p.1523）
 *   3. mask：enable      IPIER 0x128 bit0 + GIER 0x11C bit31  ICDISER1 0xF8F01104（p.1520）
 *
 * 只有「CPU 收到 IRQ 後跳到哪個 C 函式」這段（IRQ exception vector + 讀 ICCIAR / 寫 ICCEOIR
 * 分派）還用 BSP 的 XScuGic_InterruptHandler，其餘開關都在下面自己寫。
 */

#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xstatus.h"

/* ---- 1. IRQ #：port ---- */
#define BTN_IRQ_ID          61u                          /* IRQ_F2P[0] = 61（Table 7-4 PL[2:0] = 63:61） */
#define GIC_IRQ_MASK        (1u << (BTN_IRQ_ID - 32u))   /* ICD*1 管 ID 32~63 -> bit29 */

/* 跟 Vivado 匯出的設定對一次，接錯 IRQ_F2P 的 bit 時編譯就會擋下來 */
#if defined(XPAR_FABRIC_AXI_GPIO_BTN_IP2INTC_IRPT_INTR) && \
    (XPAR_FABRIC_AXI_GPIO_BTN_IP2INTC_IRPT_INTR != BTN_IRQ_ID)
#error "axi_gpio_btn 的 IRQ ID 跟 BTN_IRQ_ID 不一致"
#endif

/* ---- PL 的 AXI GPIO：按鈕輸入（axi_gpio_btn，PG144） ---- */
#define BTN_GPIO_BASE       XPAR_AXI_GPIO_BTN_BASEADDR
#define BTN_GPIO_DATA       (BTN_GPIO_BASE + 0x000u)     /* 讀按鈕電位，1 = 按下 */
#define BTN_GPIO_TRI        (BTN_GPIO_BASE + 0x004u)     /* 1 = 輸入 */
#define BTN_GPIO_GIER       (BTN_GPIO_BASE + 0x11Cu)     /* 3. mask：bit31 = 整顆 IP 的中斷總開關 */
#define BTN_GPIO_IPISR      (BTN_GPIO_BASE + 0x120u)     /* 2. pending：bit0 = 通道 1 有變化，寫 1 翻轉（清除） */
#define BTN_GPIO_IPIER      (BTN_GPIO_BASE + 0x128u)     /* 3. mask：bit0 = 通道 1 中斷 enable */
#define GIER_ENABLE         (1u << 31)
#define CH1_INTR            (1u << 0)

/* ---- PL 的 AXI GPIO：呼吸燈 mode 輸出（axi_gpio_mode） ---- */
#define MODE_GPIO_BASE      XPAR_AXI_GPIO_MODE_BASEADDR
#define MODE_GPIO_DATA      (MODE_GPIO_BASE + 0x0u)
#define MODE_GPIO_TRI       (MODE_GPIO_BASE + 0x4u)      /* 0 = 輸出 */

/* ---- GIC distributor 暫存器（UG585 Appendix B, mpcore） ---- */
#define GIC_DIST_BASE       XPAR_SCUGIC_DIST_BASEADDR    /* 0xF8F01000 */
#define GIC_ICDISER1        (GIC_DIST_BASE + 0x104u)     /* 3. mask：寫 1 = set-enable */
#define GIC_ICDICER1        (GIC_DIST_BASE + 0x184u)     /*          寫 1 = clear-enable */
#define GIC_ICDISPR1        (GIC_DIST_BASE + 0x204u)     /* 2. pending：讀狀態 / 寫 1 set */
#define GIC_ICDICPR1        (GIC_DIST_BASE + 0x284u)     /*             寫 1 clear-pending */
#define GIC_ICDIPR_BYTE(id) (GIC_DIST_BASE + 0x400u + (id))   /* 優先權，每個 ID 1 byte */
#define GIC_ICDIPTR_BYTE(id) (GIC_DIST_BASE + 0x800u + (id))  /* 目標 CPU，每個 ID 1 byte */
#define GIC_ICDICFR3        (GIC_DIST_BASE + 0xC0Cu)     /* ID 48~63 觸發方式，每個 ID 2 bit */
#define GIC_ICFR_SHIFT      ((BTN_IRQ_ID - 48u) * 2u)    /* ID 61 -> bits[27:26] */

#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static XScuGic  GicInst;

static volatile LedMode g_Mode = LED_MODE_FIXED;
static volatile u32     g_IntrCount = 0;

/* S6 按鍵中斷：按下時 toggle 模式，寫給 PL 的 pwm_breath */
static void S6IntrHandler(void *CallBackRef)
{
    (void)CallBackRef;

    /* 2. pending：IPISR bit0 = 這次是不是按鈕通道觸發的 */
    if (Xil_In32(BTN_GPIO_IPISR) & CH1_INTR) {
        /* IPISR 是 toggle-on-write：對已經是 1 的 bit 寫 1 才會清成 0；
         * 不清的話 ip2intc_irpt 一直是 High，ISR 會反覆進來 */
        Xil_Out32(BTN_GPIO_IPISR, CH1_INTR);
        g_IntrCount++;

        /* AXI GPIO 在輸入「變化」時就中斷，按下、放開各一次；
         * 防彈跳已經在 PL 的 btn_debounce 做完，這裡只要挑「按下」那次 */
        if (Xil_In32(BTN_GPIO_DATA) & 0x1u) {
            g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
            Xil_Out32(MODE_GPIO_DATA, (u32)g_Mode);
        }
    }
}

static void SetupModeGpio(void)
{
    /* 1 bit 全輸出，開機固定恆亮 */
    Xil_Out32(MODE_GPIO_TRI, 0x0u);
    Xil_Out32(MODE_GPIO_DATA, LED_MODE_FIXED);
}

static void SetupBtnGpio(void)
{
    u32 Reg;

    /* 先關掉，設定完再開 */
    Xil_Out32(BTN_GPIO_GIER, 0x0u);
    Xil_Out32(BTN_GPIO_IPIER, 0x0u);

    /* 通道 1 設成輸入 */
    Xil_Out32(BTN_GPIO_TRI, 0x1u);

    /* 2. pending：清掉殘留的狀態。toggle-on-write，只能把讀到是 1 的 bit 寫回去，
     * 直接寫 1 到原本是 0 的 bit 反而會把它設成 pending */
    Reg = Xil_In32(BTN_GPIO_IPISR) & CH1_INTR;
    Xil_Out32(BTN_GPIO_IPISR, Reg);

    /* 3. mask：通道 1 enable + IP 中斷總開關 */
    Xil_Out32(BTN_GPIO_IPIER, CH1_INTR);
    Xil_Out32(BTN_GPIO_GIER, GIER_ENABLE);
}

static int SetupInterruptSystem(void)
{
    u32 Reg;
    XScuGic_Config *ConfigPtr = XScuGic_LookupConfig(GIC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        return XST_FAILURE;
    }
    /* 初始化 GIC distributor + CPU interface，並建立 IRQ ID -> handler 的分派表 */
    if (XScuGic_CfgInitialize(&GicInst, ConfigPtr, ConfigPtr->CpuBaseAddress) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                  (Xil_ExceptionHandler)XScuGic_InterruptHandler, &GicInst);

    /* 1. IRQ #：分派表裡 ID 61 對到 S6IntrHandler */
    if (XScuGic_Connect(&GicInst, BTN_IRQ_ID,
                         (Xil_ExceptionHandler)S6IntrHandler, NULL) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 先關掉 ID 61，設定完再開 */
    Xil_Out32(GIC_ICDICER1, GIC_IRQ_MASK);

    /* ip2intc_irpt 在 IPISR 清掉前一直維持 High -> 用 High level（ICDICFR3 bits[27:26] = 01） */
    Reg = Xil_In32(GIC_ICDICFR3);
    Reg &= ~(0x3u << GIC_ICFR_SHIFT);
    Reg |=  (0x1u << GIC_ICFR_SHIFT);
    Xil_Out32(GIC_ICDICFR3, Reg);

    /* 優先權 0xA0、送給 CPU0（bit0） */
    Xil_Out8(GIC_ICDIPR_BYTE(BTN_IRQ_ID), 0xA0u);
    Xil_Out8(GIC_ICDIPTR_BYTE(BTN_IRQ_ID), 0x01u);

    /* 2. pending：清掉 ID 61 殘留的 pending */
    Xil_Out32(GIC_ICDICPR1, GIC_IRQ_MASK);

    /* 3. mask：ICDISER1 寫 1 開啟 bit29 */
    Xil_Out32(GIC_ICDISER1, GIC_IRQ_MASK);

    /* 最後一層：CPU 的 IRQ（CPSR.I 清 0） */
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

int main(void)
{
    SetupModeGpio();
    SetupBtnGpio();
    if (SetupInterruptSystem() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    while (1) {
        /* S6 ISR 切模式、PL 的 pwm_breath 產生呼吸燈波形，主迴圈空轉即可
         * （g_IntrCount 可在 SDK debugger 觀察中斷次數：每次按壓 +2，按下/放開各一次） */
    }

    return XST_SUCCESS;
}
