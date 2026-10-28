/*
 * HW2 - S6 按鈕中斷切換 LED0 恆亮 / 呼吸燈
 * EGO-XZ7 (Zynq-7000), Xilinx SDK standalone
 * S6 -> btn_debounce -> axi_gpio_btn -> IRQ_F2P[0] -> GIC ID 61 -> S6IntrHandler
 */

#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xstatus.h"

/* 1. IRQ # */
#define BTN_IRQ_ID          61u                          /* IRQ_F2P[0]，UG585 Table 7-4 */
#define GIC_IRQ_MASK        (1u << (BTN_IRQ_ID - 32u))   /* ICD*1 管 ID 32~63，bit29 */

/* axi_gpio_btn（PG144） */
#define BTN_GPIO_BASE       XPAR_AXI_GPIO_BTN_BASEADDR
#define BTN_GPIO_DATA       (BTN_GPIO_BASE + 0x000u)
#define BTN_GPIO_TRI        (BTN_GPIO_BASE + 0x004u)
#define BTN_GPIO_GIER       (BTN_GPIO_BASE + 0x11Cu)     /* 3. mask：bit31 總開關 */
#define BTN_GPIO_IPISR      (BTN_GPIO_BASE + 0x120u)     /* 2. pending */
#define BTN_GPIO_IPIER      (BTN_GPIO_BASE + 0x128u)     /* 3. mask：bit0 通道 1 */
#define GIER_ENABLE         (1u << 31)
#define CH1_INTR            (1u << 0)

/* axi_gpio_mode */
#define MODE_GPIO_BASE      XPAR_AXI_GPIO_MODE_BASEADDR
#define MODE_GPIO_DATA      (MODE_GPIO_BASE + 0x0u)
#define MODE_GPIO_TRI       (MODE_GPIO_BASE + 0x4u)

/* GIC distributor（UG585 附錄 B） */
#define GIC_DIST_BASE       XPAR_SCUGIC_DIST_BASEADDR    /* 0xF8F01000 */
#define GIC_ICDISER1        (GIC_DIST_BASE + 0x104u)     /* 3. mask：set-enable */
#define GIC_ICDICER1        (GIC_DIST_BASE + 0x184u)     /* clear-enable */
#define GIC_ICDISPR1        (GIC_DIST_BASE + 0x204u)     /* 2. pending：set-pending */
#define GIC_ICDICPR1        (GIC_DIST_BASE + 0x284u)     /* clear-pending */
#define GIC_ICDIPR_BYTE(id) (GIC_DIST_BASE + 0x400u + (id))
#define GIC_ICDIPTR_BYTE(id) (GIC_DIST_BASE + 0x800u + (id))
#define GIC_ICDICFR3        (GIC_DIST_BASE + 0xC0Cu)     /* ID 48~63 觸發方式 */
#define GIC_ICFR_SHIFT      ((BTN_IRQ_ID - 48u) * 2u)    /* bits[27:26] */

#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static XScuGic  GicInst;

static volatile LedMode g_Mode = LED_MODE_FIXED;
static volatile u32     g_IntrCount = 0;

static void S6IntrHandler(void *CallBackRef)
{
    (void)CallBackRef;

    if (Xil_In32(BTN_GPIO_IPISR) & CH1_INTR) {
        /* toggle-on-write，寫 1 清除；沒清的話會一直重進 ISR */
        Xil_Out32(BTN_GPIO_IPISR, CH1_INTR);
        g_IntrCount++;

        /* 按下、放開都會中斷，只在按下時切換 */
        if (Xil_In32(BTN_GPIO_DATA) & 0x1u) {
            g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
            Xil_Out32(MODE_GPIO_DATA, (u32)g_Mode);
        }
    }
}

static void SetupModeGpio(void)
{
    Xil_Out32(MODE_GPIO_TRI, 0x0u);
    Xil_Out32(MODE_GPIO_DATA, LED_MODE_FIXED);
}

static void SetupBtnGpio(void)
{
    u32 Reg;

    Xil_Out32(BTN_GPIO_GIER, 0x0u);
    Xil_Out32(BTN_GPIO_IPIER, 0x0u);

    Xil_Out32(BTN_GPIO_TRI, 0x1u);

    /* 只寫回讀到是 1 的 bit，寫到 0 的 bit 會變成 pending */
    Reg = Xil_In32(BTN_GPIO_IPISR) & CH1_INTR;
    Xil_Out32(BTN_GPIO_IPISR, Reg);

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
    if (XScuGic_CfgInitialize(&GicInst, ConfigPtr, ConfigPtr->CpuBaseAddress) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                  (Xil_ExceptionHandler)XScuGic_InterruptHandler, &GicInst);

    if (XScuGic_Connect(&GicInst, BTN_IRQ_ID,
                         (Xil_ExceptionHandler)S6IntrHandler, NULL) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Xil_Out32(GIC_ICDICER1, GIC_IRQ_MASK);

    /* ip2intc_irpt 清掉前一直是 High，用 level 觸發（01） */
    Reg = Xil_In32(GIC_ICDICFR3);
    Reg &= ~(0x3u << GIC_ICFR_SHIFT);
    Reg |=  (0x1u << GIC_ICFR_SHIFT);
    Xil_Out32(GIC_ICDICFR3, Reg);

    Xil_Out8(GIC_ICDIPR_BYTE(BTN_IRQ_ID), 0xA0u);
    Xil_Out8(GIC_ICDIPTR_BYTE(BTN_IRQ_ID), 0x01u);   /* CPU0 */

    Xil_Out32(GIC_ICDICPR1, GIC_IRQ_MASK);
    Xil_Out32(GIC_ICDISER1, GIC_IRQ_MASK);

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
    }

    return XST_SUCCESS;
}
