#ifndef MATRIX_H
#define MATRIX_H
/* Register map of AXIMatrix (see AXIMatrix.sv) and AXI UART Lite, as placed in the Address Editor. */
#define REG(addr)        (*(volatile unsigned int *)(addr))
#define MATRIX_BASE      0x10000000u
#define MATRIX_CONTROL   REG(MATRIX_BASE + 0x00)  /* write 1: START. read bit0 BUSY, bit1 DONE */
#define MATRIX_K_LEN     REG(MATRIX_BASE + 0x04)  /* products per PE, 1..75 */
#define MATRIX_TERM_IDX  REG(MATRIX_BASE + 0x08)  /* which term the next TERM_DATA write fills */
#define MATRIX_TERM_DATA REG(MATRIX_BASE + 0x0C)  /* bytes low..high: A[0][k], A[1][k], B[k][0], B[k][1] */
#define MATRIX_RESULT(i) REG(MATRIX_BASE + 0x10 + 4 * (i))  /* C00, C01, C10, C11 */
#define MATRIX_K_MAX     75

#define UART_BASE        0x20000000u
#define UART_TX          REG(UART_BASE + 0x04)
#define UART_STATUS      REG(UART_BASE + 0x08)
#define UART_TX_FULL     0x08u

unsigned int read_cycle(void);
#endif
