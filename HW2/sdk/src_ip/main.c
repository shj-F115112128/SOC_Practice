/*
 * HW2 IP 封裝版 - S6 按鈕中斷切換 LED0 恆亮 / 呼吸燈
 * EGO-XZ7 (Zynq-7000), Xilinx SDK standalone
 * S6 -> btn_led_ctrl（自製 AXI4-Lite IP）irq -> IRQ_F2P[0] -> GIC ID 61 -> BtnIntrHandler
 * 自製 IP 沒有 BSP driver，暫存器用 Xil_In32 / Xil_Out32 直接讀寫；GIC 一樣用 xscugic
 */

#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xstatus.h"

/* btn_led_ctrl 的暫存器（offset 見 ip_repo/btn_led_ctrl_1.0/hdl/btn_led_ctrl_v1_0_S00_AXI.v） */
#define IP_BASE             XPAR_BTN_LED_CTRL_0_S00_AXI_BASEADDR    /* 0x43C00000 */
#define REG_CTRL            (IP_BASE + 0x0u)    /* bit0 mode：0 恆亮、1 呼吸 */
#define REG_STATUS          (IP_BASE + 0x4u)    /* bit0 防彈跳後的按鈕電位（唯讀） */
#define REG_INT_STATUS      (IP_BASE + 0x8u)    /* 2. pending：bit0 按鈕有變化，寫 1 清除 */
#define REG_INT_ENABLE      (IP_BASE + 0xCu)    /* 3. mask：bit0 中斷 enable */

/* 1. IRQ #：IRQ_F2P[0]，UG585 Table 7-4；xparameters.h 由 Vivado 匯出 = 61 */
#define BTN_IRQ_ID          XPAR_FABRIC_BTN_LED_CTRL_0_IRQ_INTR
#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID

#define BTN_INTR            0x1u
#define BTN_IRQ_PRIORITY    0xA0u
#define GIC_TRIG_LEVEL_HIGH 0x1u                /* ICDICFR 01 = high level */

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static XScuGic GicInst;

static volatile LedMode g_Mode = LED_MODE_FIXED;
static volatile u32     g_IntrCount = 0;
static volatile u32     g_BtnLevel = 0;

static void BtnIntrHandler(void *CallBackRef)
{
    (void)CallBackRef;

    /* 2. pending：讀 INT_STATUS */
    if (Xil_In32(REG_INT_STATUS) & BTN_INTR) {
        /* W1C；irq 是 level，沒清的話會一直重進 ISR */
        Xil_Out32(REG_INT_STATUS, BTN_INTR);
        g_BtnLevel = Xil_In32(REG_STATUS) & 0x1u;
        g_IntrCount++;

        /* 按下、放開都會中斷，只在按下時切換；CPU 經 AXI 寫 CTRL 下指令給 IP */
        if (g_BtnLevel) {
            g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
            Xil_Out32(REG_CTRL, (u32)g_Mode);
        }
    }
}

static int SetupInterruptSystem(void)
{
    XScuGic_Config *ConfigPtr = XScuGic_LookupConfig(GIC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        return XST_FAILURE;
    }
    if (XScuGic_CfgInitialize(&GicInst, ConfigPtr, ConfigPtr->CpuBaseAddress) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* irq 在 INT_STATUS 清掉前一直是 High，用 level 觸發；寫 ICDIPR 的優先權、ICDICFR3 bits[27:26] */
    XScuGic_SetPriorityTriggerType(&GicInst, BTN_IRQ_ID, BTN_IRQ_PRIORITY, GIC_TRIG_LEVEL_HIGH);

    /* 把 BtnIntrHandler 填進 HandlerTable[61] */
    if (XScuGic_Connect(&GicInst, BTN_IRQ_ID,
                        (Xil_ExceptionHandler)BtnIntrHandler, NULL) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 3. mask：GIC 端寫 ICDISER1 bit29 */
    XScuGic_Enable(&GicInst, BTN_IRQ_ID);

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler, &GicInst);
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

int main(void)
{
    u32 Shown = 0;

    Xil_Out32(REG_CTRL, LED_MODE_FIXED);
    Xil_Out32(REG_INT_STATUS, BTN_INTR);        /* 先清掉開機前留下的 pending */

    if (SetupInterruptSystem() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 3. mask：IP 端最後才開 INT_ENABLE */
    Xil_Out32(REG_INT_ENABLE, BTN_INTR);

    /* 輸出走 JTAG UART，沒人讀時會卡住，所以不在 ISR 裡印 */
    xil_printf("HW2 IP wrapper ready: LED0 = FIXED, press S6\r\n");

    while (1) {
        if (g_IntrCount != Shown) {
            Shown = g_IntrCount;
            xil_printf("IRQ %d #%d: S6 %s, mode = %s\r\n", (int)BTN_IRQ_ID, (int)Shown,
                       g_BtnLevel ? "pressed " : "released",
                       (g_Mode == LED_MODE_BREATH) ? "BREATH" : "FIXED");
        }
    }

    return XST_SUCCESS;
}
