/*
 * HW2 - S6 按鈕中斷切換 LED0 恆亮 / 呼吸燈
 * EGO-XZ7 (Zynq-7000), Xilinx SDK standalone，Driver 用 BSP API（xgpio、xscugic）
 * S6 -> btn_debounce -> axi_gpio_btn -> IRQ_F2P[0] -> GIC ID 61 -> S6IntrHandler
 */

#include "xparameters.h"
#include "xgpio.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xstatus.h"

/* 1. IRQ #：IRQ_F2P[0]，UG585 Table 7-4；xparameters.h 由 Vivado 匯出 = 61 */
#define BTN_IRQ_ID          XPAR_FABRIC_AXI_GPIO_BTN_IP2INTC_IRPT_INTR

#define BTN_GPIO_ID         XPAR_AXI_GPIO_BTN_DEVICE_ID
#define MODE_GPIO_ID        XPAR_AXI_GPIO_MODE_DEVICE_ID
#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID

#define GPIO_CH             1u
#define CH1_INTR            XGPIO_IR_CH1_MASK            /* IPISR / IPIER bit0 */

#define BTN_IRQ_PRIORITY    0xA0u
#define GIC_TRIG_LEVEL_HIGH 0x1u                         /* ICDICFR 01 = high level */

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static XScuGic  GicInst;
static XGpio    BtnGpio;
static XGpio    ModeGpio;

static volatile LedMode g_Mode = LED_MODE_FIXED;
static volatile u32     g_IntrCount = 0;
static volatile u32     g_BtnLevel = 0;

static void S6IntrHandler(void *CallBackRef)
{
    XGpio *Gpio = (XGpio *)CallBackRef;

    /* 2. pending：讀 IPISR */
    if (XGpio_InterruptGetStatus(Gpio) & CH1_INTR) {
        /* IPISR 是 toggle-on-write，寫 1 清除；沒清的話會一直重進 ISR */
        XGpio_InterruptClear(Gpio, CH1_INTR);
        g_BtnLevel = XGpio_DiscreteRead(Gpio, GPIO_CH) & 0x1u;
        g_IntrCount++;

        /* 按下、放開都會中斷，只在按下時切換 */
        if (g_BtnLevel) {
            g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
            XGpio_DiscreteWrite(&ModeGpio, GPIO_CH, (u32)g_Mode);
        }
    }
}

static int SetupGpio(void)
{
    if (XGpio_Initialize(&ModeGpio, MODE_GPIO_ID) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    XGpio_SetDataDirection(&ModeGpio, GPIO_CH, 0x0u);    /* GPIO_TRI = 0：輸出 */
    XGpio_DiscreteWrite(&ModeGpio, GPIO_CH, LED_MODE_FIXED);

    if (XGpio_Initialize(&BtnGpio, BTN_GPIO_ID) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    XGpio_SetDataDirection(&BtnGpio, GPIO_CH, 0x1u);     /* GPIO_TRI = 1：輸入 */
    return XST_SUCCESS;
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

    /* ip2intc_irpt 清掉前一直是 High，用 level 觸發；寫 ICDIPR 的優先權、ICDICFR3 bits[27:26] */
    XScuGic_SetPriorityTriggerType(&GicInst, BTN_IRQ_ID, BTN_IRQ_PRIORITY, GIC_TRIG_LEVEL_HIGH);

    /* 把 S6IntrHandler 填進 HandlerTable[61] */
    if (XScuGic_Connect(&GicInst, BTN_IRQ_ID,
                        (Xil_ExceptionHandler)S6IntrHandler, &BtnGpio) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 3. mask：GIC 端寫 ICDISER1 bit29 */
    XScuGic_Enable(&GicInst, BTN_IRQ_ID);

    /* 3. mask：AXI GPIO 端寫 IPIER bit0、GIER bit31；先清掉開機前留下的 pending */
    XGpio_InterruptClear(&BtnGpio, CH1_INTR);
    XGpio_InterruptEnable(&BtnGpio, CH1_INTR);
    XGpio_InterruptGlobalEnable(&BtnGpio);

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler, &GicInst);
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

int main(void)
{
    u32 Shown = 0;

    if (SetupGpio() != XST_SUCCESS || SetupInterruptSystem() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 輸出走 JTAG UART，沒人讀時會卡住，所以不在 ISR 裡印 */
    xil_printf("HW2 ready: LED0 = FIXED, press S6\r\n");

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
