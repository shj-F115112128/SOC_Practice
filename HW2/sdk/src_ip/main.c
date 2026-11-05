/*
 * HW2 IP 封裝版 - S6 手勢中斷控制 LED0
 * EGO-XZ7 (Zynq-7000), Xilinx SDK standalone
 * S6 -> btn_led_ctrl（自製 AXI4-Lite IP）irq -> IRQ_F2P[0] -> GIC ID 61 -> BtnIntrHandler
 * 自製 IP 沒有 BSP driver，暫存器用 Xil_In32 / Xil_Out32 直接讀寫；GIC 一樣用 xscugic
 *
 * IP 用硬體判斷手勢，每種手勢一個中斷 bit；中斷發生時 IP 把資料準備好，ISR 經 AXI 讀回：
 *   單擊：切換恆亮 / 呼吸
 *   雙擊：切換恆亮亮度 31 -> 8 -> 2 -> 31（寫 BRIGHT）
 *   長按：切換呼吸速度 3.75 s -> 1.9 s -> 0.94 s -> 0.47 s（寫 SPEED）
 *   按下 / 放開：只記錄，放開時印出硬體量到的按住時間（HOLD_MS）
 */

#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xstatus.h"

/* btn_led_ctrl 的暫存器（offset 見 ip_repo/btn_led_ctrl_1.0/hdl/btn_led_ctrl_v1_0_S00_AXI.v） */
#define IP_BASE             XPAR_BTN_LED_CTRL_0_S00_AXI_BASEADDR    /* 0x43C00000 */
#define REG_CTRL            (IP_BASE + 0x00u)   /* bit0 mode：0 恆亮、1 呼吸 */
#define REG_STATUS          (IP_BASE + 0x04u)   /* bit0 防彈跳後的按鈕電位（唯讀） */
#define REG_INT_STATUS      (IP_BASE + 0x08u)   /* 2. pending：bit[4:0] 五種中斷，寫 1 清除 */
#define REG_INT_ENABLE      (IP_BASE + 0x0Cu)   /* 3. mask：bit[4:0] 每種中斷的開關 */
#define REG_DATA_IN         (IP_BASE + 0x10u)   /* CPU 寫給 IP 的資料 */
#define REG_DATA_OUT        (IP_BASE + 0x14u)   /* 中斷時 IP 鎖住 DATA_IN + EVENT_CNT（唯讀） */
#define REG_EVENT_CNT       (IP_BASE + 0x18u)   /* 中斷事件次數（唯讀） */
#define REG_HOLD_MS         (IP_BASE + 0x1Cu)   /* 最近一次按住幾 ms（唯讀） */
#define REG_SPEED           (IP_BASE + 0x20u)   /* bit[1:0] 呼吸速度 */
#define REG_BRIGHT          (IP_BASE + 0x24u)   /* bit[4:0] 恆亮亮度 0～31 */

/* INT_STATUS / INT_ENABLE 的 bit */
#define EV_PRESS            0x01u
#define EV_RELEASE          0x02u
#define EV_CLICK            0x04u
#define EV_DOUBLE           0x08u
#define EV_LONG             0x10u
#define EV_ALL              0x1Fu

/* 1. IRQ #：IRQ_F2P[0]，UG585 Table 7-4；xparameters.h 由 Vivado 匯出 = 61 */
#define BTN_IRQ_ID          XPAR_FABRIC_BTN_LED_CTRL_0_IRQ_INTR
#define GIC_DEVICE_ID       XPAR_SCUGIC_SINGLE_DEVICE_ID

#define BTN_IRQ_PRIORITY    0xA0u
#define GIC_TRIG_LEVEL_HIGH 0x1u                /* ICDICFR 01 = high level */
#define DATA_IN_VALUE       1000u

typedef enum {
    LED_MODE_FIXED = 0,
    LED_MODE_BREATH
} LedMode;

static const char *const SpeedText[4] = { "3.75 s", "1.9 s", "0.94 s", "0.47 s" };
static const u32 BrightLevel[3] = { 31u, 8u, 2u };

/* ISR 每次中斷存一筆，main() 再慢慢印；連續很快的事件也不會漏 */
typedef struct {
    u32 Status;     /* 這次讀到的 INT_STATUS */
    u32 DataOut;
    u32 EventCnt;
    u32 HoldMs;
    u32 Mode;
    u32 Speed;
    u32 Bright;
} IntrRecord;

#define LOG_SIZE 16u

static XScuGic GicInst;

static volatile u32 g_Mode = LED_MODE_FIXED;
static volatile u32 g_Speed = 0;
static volatile u32 g_BrightIdx = 0;
static volatile IntrRecord g_Log[LOG_SIZE];
static volatile u32 g_LogHead = 0;      /* ISR 寫到第幾筆 */

static void BtnIntrHandler(void *CallBackRef)
{
    u32 Status;
    volatile IntrRecord *Rec;

    (void)CallBackRef;

    /* 2. pending：讀 INT_STATUS，可能同時有好幾個 bit（例如放開 + 雙擊） */
    Status = Xil_In32(REG_INT_STATUS) & EV_ALL;
    if (Status == 0u) {
        return;
    }
    /* W1C：讀到哪些 bit 就清哪些；irq 是 level，沒清的話會一直重進 ISR */
    Xil_Out32(REG_INT_STATUS, Status);

    /* CPU 經 AXI 寫指令給 IP */
    if (Status & EV_CLICK) {
        g_Mode = (g_Mode == LED_MODE_FIXED) ? LED_MODE_BREATH : LED_MODE_FIXED;
        Xil_Out32(REG_CTRL, g_Mode);
    }
    if (Status & EV_DOUBLE) {
        g_BrightIdx = (g_BrightIdx + 1u) % 3u;
        Xil_Out32(REG_BRIGHT, BrightLevel[g_BrightIdx]);
    }
    if (Status & EV_LONG) {
        g_Speed = (g_Speed + 1u) & 0x3u;
        Xil_Out32(REG_SPEED, g_Speed);
    }

    /* IP 在中斷那一拍準備好的資料，經 AXI 讀回 */
    Rec = &g_Log[g_LogHead % LOG_SIZE];
    Rec->Status   = Status;
    Rec->DataOut  = Xil_In32(REG_DATA_OUT);
    Rec->EventCnt = Xil_In32(REG_EVENT_CNT);
    Rec->HoldMs   = Xil_In32(REG_HOLD_MS);
    Rec->Mode     = g_Mode;
    Rec->Speed    = g_Speed;
    Rec->Bright   = BrightLevel[g_BrightIdx];
    g_LogHead++;
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

static void PrintRecord(u32 No, const volatile IntrRecord *Rec)
{
    xil_printf("IRQ %d #%d:", (int)BTN_IRQ_ID, (int)No);
    if (Rec->Status & EV_PRESS) {
        xil_printf(" PRESS");
    }
    if (Rec->Status & EV_RELEASE) {
        xil_printf(" RELEASE(held %d ms)", (int)Rec->HoldMs);
    }
    if (Rec->Status & EV_CLICK) {
        xil_printf(" CLICK -> mode = %s", (Rec->Mode == LED_MODE_BREATH) ? "BREATH" : "FIXED");
    }
    if (Rec->Status & EV_DOUBLE) {
        xil_printf(" DOUBLE -> bright = %d/31", (int)Rec->Bright);
    }
    if (Rec->Status & EV_LONG) {
        xil_printf(" LONG -> speed = %s", SpeedText[Rec->Speed]);
    }
    xil_printf("  | DATA_OUT = %d (DATA_IN %d + EVENT_CNT %d)\r\n",
               (int)Rec->DataOut, (int)DATA_IN_VALUE, (int)Rec->EventCnt);
}

int main(void)
{
    u32 Shown = 0;

    Xil_Out32(REG_CTRL, LED_MODE_FIXED);
    Xil_Out32(REG_SPEED, 0u);
    Xil_Out32(REG_BRIGHT, BrightLevel[0]);
    Xil_Out32(REG_DATA_IN, DATA_IN_VALUE);      /* CPU 經 AXI 寫資料給 IP */
    Xil_Out32(REG_INT_STATUS, EV_ALL);          /* 先清掉開機前留下的 pending */

    if (SetupInterruptSystem() != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /* 3. mask：IP 端最後才開 INT_ENABLE，五種中斷全開 */
    Xil_Out32(REG_INT_ENABLE, EV_ALL);

    /* 輸出走 JTAG UART，沒人讀時會卡住，所以不在 ISR 裡印 */
    xil_printf("HW2 IP wrapper ready: LED0 = FIXED\r\n");
    xil_printf("S6: click = FIXED/BREATH, double click = brightness, long press (1 s) = breathing speed\r\n");

    while (1) {
        /* 印的速度跟不上時（超過 LOG_SIZE 筆）跳過最舊的 */
        if (g_LogHead - Shown > LOG_SIZE) {
            Shown = g_LogHead - LOG_SIZE;
        }
        if (Shown != g_LogHead) {
            PrintRecord(Shown + 1u, &g_Log[Shown % LOG_SIZE]);
            Shown++;
        }
    }

    return XST_SUCCESS;
}
