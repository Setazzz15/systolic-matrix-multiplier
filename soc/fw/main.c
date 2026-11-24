/* PicoRV32 firmware for the matrix_soc design.
 *
 * Runs two jobs on the 2x2 systolic array through AXIMatrix and prints the results on the UART:
 *   SMOKE: the 2x3 by 3x2 example from the button demo, expected [[22, 28], [9, 10]]
 *   CONV1: two image patches x two trained conv1 filters (K = 75) from Adv_Attack's model.pt
 * Each job is also computed in plain software on the CPU, to check the hardware and compare time.
 */
#include "matrix.h"
#include "conv_tile.h"

/* rv32i has no multiply instruction; the compiler calls this for every `*`. */
int __mulsi3(int a, int b) {
    unsigned int x = (unsigned int)a, y = (unsigned int)b, r = 0;
    while (y) { if (y & 1) r += x; x <<= 1; y >>= 1; }
    return (int)r;
}

static void uart_putc(char c) {
    while (UART_STATUS & UART_TX_FULL) { }
    UART_TX = (unsigned char)c;
}
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

/* Decimal printing by repeated subtraction: the CPU has no divide instruction either. */
static void uart_putu(unsigned int v) {
    static const unsigned int pow10[10] = {1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
                                           10000u, 1000u, 100u, 10u, 1u};
    int started = 0;
    for (int i = 0; i < 10; i++) {
        char d = '0';
        while (v >= pow10[i]) { v -= pow10[i]; d++; }
        if (d != '0' || started || i == 9) { uart_putc(d); started = 1; }
    }
}
static void uart_puti(int v) {
    if (v < 0) { uart_putc('-'); uart_putu(0u - (unsigned int)v); } else uart_putu((unsigned int)v);
}

/* One job on the accelerator: C = A (2 x k) times B (k x 2). a0/a1 are the rows of A,
 * b0/b1 the columns of B. Returns the number of clock cycles from loading to results. */
static unsigned int matrix_run(const signed char *a0, const signed char *a1,
                               const signed char *b0, const signed char *b1,
                               int k, int c[4]) {
    unsigned int t0 = read_cycle();
    MATRIX_K_LEN = (unsigned int)k;
    MATRIX_TERM_IDX = 0;
    for (int i = 0; i < k; i++)
        MATRIX_TERM_DATA = ((unsigned int)(unsigned char)a0[i])
                         | ((unsigned int)(unsigned char)a1[i] << 8)
                         | ((unsigned int)(unsigned char)b0[i] << 16)
                         | ((unsigned int)(unsigned char)b1[i] << 24);
    MATRIX_CONTROL = 1;                              /* START */
    while (!(MATRIX_CONTROL & 2)) { }                /* poll DONE */
    for (int i = 0; i < 4; i++) c[i] = (int)MATRIX_RESULT(i);
    return read_cycle() - t0;
}

/* The same four dot products in software, for checking and for timing. */
static unsigned int software_run(const signed char *a0, const signed char *a1,
                                 const signed char *b0, const signed char *b1,
                                 int k, int c[4]) {
    unsigned int t0 = read_cycle();
    int c00 = 0, c01 = 0, c10 = 0, c11 = 0;
    for (int i = 0; i < k; i++) {
        c00 += a0[i] * b0[i]; c01 += a0[i] * b1[i];
        c10 += a1[i] * b0[i]; c11 += a1[i] * b1[i];
    }
    c[0] = c00; c[1] = c01; c[2] = c10; c[3] = c11;
    return read_cycle() - t0;
}

static int run_test(const char *name, const signed char *a0, const signed char *a1,
                    const signed char *b0, const signed char *b1, int k, const int expected[4]) {
    int hw[4], sw[4];
    unsigned int hw_cycles = matrix_run(a0, a1, b0, b1, k, hw);
    unsigned int sw_cycles = software_run(a0, a1, b0, b1, k, sw);
    int pass = 1;
    for (int i = 0; i < 4; i++) if (hw[i] != expected[i] || sw[i] != expected[i]) pass = 0;

    uart_puts(name); uart_puts(" C = [[");
    uart_puti(hw[0]); uart_puts(", "); uart_puti(hw[1]); uart_puts("], [");
    uart_puti(hw[2]); uart_puts(", "); uart_puti(hw[3]); uart_puts("]] ");
    uart_puts(pass ? "PASS" : "FAIL");
    uart_puts(" hw_cycles="); uart_putu(hw_cycles);
    uart_puts(" sw_cycles="); uart_putu(sw_cycles);
    uart_putc('\n');
    return pass;
}

static const signed char SMOKE_A0[3] = {1, 2, 3}, SMOKE_A1[3] = {-1, 0, 2};
static const signed char SMOKE_B0[3] = {1, 3, 5}, SMOKE_B1[3] = {2, 4, 6};
static const int SMOKE_EXPECTED[4] = {22, 28, 9, 10};

int main(void) {
    for (;;) {
        int ok = run_test("SMOKE", SMOKE_A0, SMOKE_A1, SMOKE_B0, SMOKE_B1, 3, SMOKE_EXPECTED);
        ok &= run_test("CONV1", CONV_A0, CONV_A1, CONV_B0, CONV_B1, CONV_K, CONV_EXPECTED);
        uart_puts(ok ? "END ALL PASS\n" : "END FAIL\n");
        /* Repeat about once a second (12 MHz clock) so a listener can attach at any time. */
        unsigned int t0 = read_cycle();
        while (read_cycle() - t0 < 12000000u) { }
    }
}
