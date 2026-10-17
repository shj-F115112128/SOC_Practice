/*
 * HW2 - S4 按鈕中斷切換 LED0 固定恆亮 / 2 秒呼吸燈
 * 平台：EGO-XZ7 (Zynq-7000), Xilinx SDK standalone BSP
 *
 * 硬體假設（Vivado block design 定案前的暫定值，之後依實際 xparameters.h / XDC 調整）：
 *   - S4  = PS MIO_51，按下為 low（active-low，外部/內部上拉），接成 falling-edge 中斷
 *   - LED0 = PL pin T22，透過 PS7 的 EMIO 拉出一條 GPIO 給它；Zynq-7000 MIO 共 54 根
 *     (0~53)，XGpioPs 把 MIO/EMIO 當同一段連續編號，所以 EMIO 第 0 bit = pin 54
 *   - GPIO_INTR_ID / TTC_INTR_ID 用 xparameters.h 產生的值，這裡先放常見值註記待確認
 */

#include "xparameters.h"
#include "xgpiops.h"
#include "xscugic.h"
#include "xttcps.h"
#include "xil_exception.h"
#include "xstatus.h"

/* ---- 硬體腳位 / 裝置 ID（待 Vivado 硬體匯出後確認） ---- */
#define GPIO_DEVICE_ID      XPAR_XGPIOPS_0_DEVICE_ID
#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID
#define TTC_DEVICE_ID       XPAR_XTTCPS_0_DEVICE_ID
#define GPIO_INTR_ID        XPAR_XGPIOPS_0_INTR      /* PS GPIO 共用中斷，固定為 SPI ID 52（UG585） */
#define TTC_INTR_ID         XPAR_XTTCPS_0_INTR       /* TTC0 counter0 中斷，固定為 SPI ID 42（UG585） */

#define S4_MIO_PIN          51u                       /* PS MIO_51 */
#define LED0_PIN            54u                       /* EMIO[0]，接 LED0 (T22) */

/* ---- 呼吸燈 / 軟體 PWM 參數 ---- */
#define PWM_RES             100u                      /* PWM 解析度：100 階亮度 */
#define TTC_FREQ_HZ          10000u                   /* TTC tick = 10kHz (100us/次) */
                                                       /* => PWM 頻率 = 10kHz/100 = 100Hz，不閃爍 */
#define BREATH_STEPS         (2u * PWM_RES)            /* 200 步：100 步漸亮 + 100 步漸暗 */
                                                       /* 每步耗時 = 一個 PWM 全週期 = 10ms */
                                                       /* => 呼吸週期 T = 200 * 10ms = 2000ms = 2s */
#define DEBOUNCE_TICKS        2000u                    /* 200ms 防彈跳（以 TTC 100us tick 計） */

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static XGpioPs  GpioInst;
static XScuGic  GicInst;
static XTtcPs   TtcInst;

static volatile LedMode g_Mode       = LED_MODE_FIXED;
static volatile u32     g_TickCount  = 0;
static volatile u32     g_LastPressTick = 0;
static volatile u32     g_PwmCounter = 0;
static volatile u32     g_BreathStep = 0;

/* 三角波：0..PWM_RES-1 漸亮，PWM_RES..2*PWM_RES-1 漸暗 */
static u32 ComputeBrightness(u32 step)
{
    if (step < PWM_RES) {
        return step;
    }
    return (2u * PWM_RES - 1u - step);
}

/* TTC 週期性中斷：軟體 PWM 的載波，同時推進呼吸燈進度 */
static void TtcIntrHandler(void *CallBackRef)
{
    XTtcPs *TtcPtr = (XTtcPs *)CallBackRef;
    u32 Status = XTtcPs_GetInterruptStatus(TtcPtr);
    XTtcPs_ClearInterruptStatus(TtcPtr, Status);

    g_TickCount++;

    if (g_Mode == LED_MODE_FIXED) {
        XGpioPs_WritePin(&GpioInst, LED0_PIN, 1);
        g_PwmCounter = 0;
        g_BreathStep = 0;
        return;
    }

    u32 brightness = ComputeBrightness(g_BreathStep);
    XGpioPs_WritePin(&GpioInst, LED0_PIN, (g_PwmCounter < brightness) ? 1 : 0);

    g_PwmCounter++;
    if (g_PwmCounter >= PWM_RES) {
        g_PwmCounter = 0;
        g_BreathStep = (g_BreathStep + 1u) % BREATH_STEPS;
    }
}

/* S4 按鍵中斷：只負責 toggle 模式旗標，不碰 PWM 細節 */
static void S4IntrHandler(void *CallBackRef)
{
    XGpioPs *GpioPtr = (XGpioPs *)CallBackRef;

    if (XGpioPs_IntrGetStatusPin(GpioPtr, S4_MIO_PIN)) {
        XGpioPs_IntrClearPin(GpioPtr, S4_MIO_PIN);

        if ((g_TickCount - g_LastPressTick) >= DEBOUNCE_TICKS) {
            g_LastPressTick = g_TickCount;
            g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
        }
    }
}

static int SetupGpio(void)
{
    XGpioPs_Config *ConfigPtr = XGpioPs_LookupConfig(GPIO_DEVICE_ID);
    if (ConfigPtr == NULL) {
        return XST_FAILURE;
    }
    if (XGpioPs_CfgInitialize(&GpioInst, ConfigPtr, ConfigPtr->BaseAddr) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* LED0：輸出，開機固定恆亮 */
    XGpioPs_SetDirectionPin(&GpioInst, LED0_PIN, 1);
    XGpioPs_SetOutputEnablePin(&GpioInst, LED0_PIN, 1);
    XGpioPs_WritePin(&GpioInst, LED0_PIN, 1);

    /* S4：輸入，falling edge 中斷 */
    XGpioPs_SetDirectionPin(&GpioInst, S4_MIO_PIN, 0);
    XGpioPs_SetIntrTypePin(&GpioInst, S4_MIO_PIN, XGPIOPS_IRQ_TYPE_EDGE_FALLING);
    XGpioPs_IntrClearPin(&GpioInst, S4_MIO_PIN);
    XGpioPs_IntrEnablePin(&GpioInst, S4_MIO_PIN);

    return XST_SUCCESS;
}

static int SetupTtc(void)
{
    XTtcPs_Config *ConfigPtr = XTtcPs_LookupConfig(TTC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        return XST_FAILURE;
    }
    if (XTtcPs_CfgInitialize(&TtcInst, ConfigPtr, ConfigPtr->BaseAddress) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XTtcPs_SetOptions(&TtcInst, XTTCPS_OPTION_INTERVAL_MODE | XTTCPS_OPTION_WAVE_DISABLE);

    u16 Interval, Prescaler;
    XTtcPs_CalcIntervalFromFreq(&TtcInst, TTC_FREQ_HZ, &Interval, &Prescaler);
    XTtcPs_SetInterval(&TtcInst, Interval);
    XTtcPs_SetPrescaler(&TtcInst, Prescaler);

    XTtcPs_EnableInterrupts(&TtcInst, XTTCPS_IXR_INTERVAL_MASK);

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

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                  (Xil_ExceptionHandler)XScuGic_InterruptHandler, &GicInst);

    if (XScuGic_Connect(&GicInst, GPIO_INTR_ID,
                         (Xil_ExceptionHandler)S4IntrHandler, &GpioInst) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (XScuGic_Connect(&GicInst, TTC_INTR_ID,
                         (Xil_ExceptionHandler)TtcIntrHandler, &TtcInst) != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XScuGic_Enable(&GicInst, GPIO_INTR_ID);
    XScuGic_Enable(&GicInst, TTC_INTR_ID);

    Xil_ExceptionEnable();

    return XST_SUCCESS;
}

int main(void)
{
    if (SetupGpio() != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (SetupInterruptSystem() != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (SetupTtc() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XTtcPs_Start(&TtcInst);

    while (1) {
        /* 所有邏輯都在中斷裡（S4 ISR 切模式、TTC ISR 跑 PWM），主迴圈空轉即可 */
    }

    return XST_SUCCESS;
}
