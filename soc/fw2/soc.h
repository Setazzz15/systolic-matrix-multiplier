#ifndef SOC_H
#define SOC_H
/* Memory map of matrix_soc, as placed in the Vivado Address Editor. */
#define REG(addr)        (*(volatile unsigned int *)(addr))

/* AXIMatrix: the CPU-fed 2x2 array (see AXIMatrix.sv). */
#define MATRIX_BASE      0x10000000u
#define MATRIX_CONTROL   REG(MATRIX_BASE + 0x00)  /* write 1: START. read bit0 BUSY, bit1 DONE */
#define MATRIX_K_LEN     REG(MATRIX_BASE + 0x04)
#define MATRIX_TERM_IDX  REG(MATRIX_BASE + 0x08)
#define MATRIX_TERM_DATA REG(MATRIX_BASE + 0x0C)  /* bytes low..high: A[0][k], A[1][k], B[k][0], B[k][1] */
#define MATRIX_RESULT(i) REG(MATRIX_BASE + 0x10 + 4 * (i))  /* C00, C01, C10, C11 */

/* AXI UART Lite. */
#define UART_BASE        0x20000000u
#define UART_RX          REG(UART_BASE + 0x00)
#define UART_TX          REG(UART_BASE + 0x04)
#define UART_STATUS      REG(UART_BASE + 0x08)
#define UART_RX_VALID    0x01u
#define UART_TX_FULL     0x08u

/* AXIConv: the conv1 engine, which feeds the array from block RAM (see AXIConv.sv). */
#define CONV_BASE        0x30000000u
#define CONV_CONTROL     REG(CONV_BASE + 0x00)    /* write 1: START row. read bit0 BUSY, bit1 DONE */
#define CONV_ROW         REG(CONV_BASE + 0x04)
#define CONV_IMG_ADDR    REG(CONV_BASE + 0x08)
#define CONV_IMG_DATA    REG(CONV_BASE + 0x0C)    /* 4 pixels per write */
#define CONV_WGT_ADDR    REG(CONV_BASE + 0x10)    /* filter_pair*128 + term */
#define CONV_WGT_DATA    REG(CONV_BASE + 0x14)    /* {odd filter, even filter} */
#define CONV_RES_ADDR    REG(CONV_BASE + 0x18)    /* filter*32 + col */
#define CONV_RES_DATA    REG(CONV_BASE + 0x1C)
#define CONV_CYCLES      REG(CONV_BASE + 0x20)
#define CONV_ID          REG(CONV_BASE + 0x24)

/* Shape of Adv_Attack's conv1: 3x32x32 input, 32 filters of 5x5, 28x28 output. */
#define IMG_BYTES   3072
#define N_FILTERS   32
#define K_TERMS     75
#define OUT_W       28
#define ROW_RESULTS (N_FILTERS * OUT_W)

unsigned int read_cycle(void);
#endif
