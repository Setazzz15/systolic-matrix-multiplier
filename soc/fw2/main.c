/* PicoRV32 firmware for matrix_soc, version 2: conv1 of Adv_Attack's CNN, three ways.
 *
 * The PC (fpga_conv1/fpga_link.py) talks to this program over the USB serial port:
 *
 *   'P'                      -> "MXC2"                      are you there?
 *   'S'                      -> one text line               rerun the power-on self-test
 *   'W' + 2400 bytes         -> 'K' + checksum              weights, [filter][term], int8
 *   'I' + 3072 bytes         -> 'K' + checksum              image, [channel][row][col], 0..127
 *   'R' + mode + row + nfp   -> 'D' + mode + row + cycles(4) + 896 results(4 each) + checksum
 *
 * 'R' computes one output row (28 columns x 32 filters) of conv1 in one of three ways:
 *   mode 0  software only: the CPU multiplies and adds everything itself
 *   mode 1  CPU-fed array: the CPU writes every operand to AXIMatrix (how Phase 3 worked)
 *   mode 2  conv1 engine:  the hardware fetches operands from block RAM by itself
 * nfp (1..16) limits modes 0 and 1 to the first nfp filter pairs, because they are slow.
 * "cycles" is the number of system clocks the computation took (the design now runs at 48 MHz).
 */
#include "soc.h"

static unsigned char img[IMG_BYTES];             /* [channel][row][col], index c*1024 + row*32 + col */
static signed char   wgt[N_FILTERS][K_TERMS];    /* [filter][channel*25 + dy*5 + dx] */
static int           res[ROW_RESULTS];           /* last row computed: [filter][col] */

/* rv32i has no multiply instruction. The compiler calls this for the few index
 * calculations such as wgt[f] (f * 75); the convolution arithmetic itself does not use it. */
int __mulsi3(int a, int b) {
    unsigned int x = (unsigned int)a, y = (unsigned int)b, r = 0;
    while (y) { if (y & 1) r += x; x <<= 1; y >>= 1; }
    return (int)r;
}

/* ------------------------------------------------------------------ serial port */
static void uart_putc(unsigned int c) {
    while (UART_STATUS & UART_TX_FULL) { }
    UART_TX = c & 0xff;
}
static void uart_puts(const char *s) { while (*s) uart_putc((unsigned char)*s++); }
static unsigned int uart_getc(void) {
    while (!(UART_STATUS & UART_RX_VALID)) { }
    return UART_RX & 0xff;
}
/* Receive n bytes. Kept tight: at high baud rates a byte arrives every few hundred clocks. */
static unsigned int uart_read(unsigned char *p, unsigned int n) {
    unsigned int sum = 0;
    while (n--) {
        while (!(UART_STATUS & UART_RX_VALID)) { }
        unsigned int b = UART_RX;
        *p++ = (unsigned char)b;
        sum += b;
    }
    return sum & 0xff;
}
static void uart_put32(unsigned int v) {
    uart_putc(v); uart_putc(v >> 8); uart_putc(v >> 16); uart_putc(v >> 24);
}
static void uart_putu(unsigned int v) {          /* decimal, without a divide instruction */
    static const unsigned int pow10[10] = {1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
                                           10000u, 1000u, 100u, 10u, 1u};
    int started = 0;
    for (int i = 0; i < 10; i++) {
        unsigned int d = '0';
        while (v >= pow10[i]) { v -= pow10[i]; d++; }
        if (d != '0' || started || i == 9) { uart_putc(d); started = 1; }
    }
}

/* ------------------------------------------------------------------ loading the engine */
static void engine_load_image(unsigned int first, unsigned int count) {  /* count bytes, multiple of 4 */
    const unsigned char *p = img + first;
    CONV_IMG_ADDR = first;
    for (unsigned int i = 0; i < count; i += 4, p += 4)
        CONV_IMG_DATA = p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned int)p[3] << 24);
}
static void engine_load_weights(int pairs) {
    for (int p = 0; p < pairs; p++) {
        const signed char *w0 = wgt[2 * p], *w1 = wgt[2 * p + 1];
        CONV_WGT_ADDR = (unsigned int)p << 7;
        for (int k = 0; k < K_TERMS; k++)
            CONV_WGT_DATA = (unsigned char)w0[k] | ((unsigned int)(unsigned char)w1[k] << 8);
    }
}

/* ------------------------------------------------------------------ mode 2: conv1 engine */
static unsigned int row_engine(int y) {
    CONV_CYCLES = 0;
    CONV_ROW = (unsigned int)y;
    CONV_CONTROL = 1;                              /* START: 224 jobs run with no CPU involvement */
    while (!(CONV_CONTROL & 2)) { }
    unsigned int cycles = CONV_CYCLES;             /* counted by the hardware itself */
    int *r = res;
    for (int f = 0; f < N_FILTERS; f++) {
        CONV_RES_ADDR = (unsigned int)f << 5;
        for (int x = 0; x < OUT_W; x++) *r++ = (int)CONV_RES_DATA;
    }
    return cycles;
}

/* ------------------------------------------------------------------ mode 1: CPU-fed array */
static unsigned int row_cpufed(int y, int nfp) {
    unsigned int t0 = read_cycle();
    for (int fp = 0; fp < nfp; fp++) {
        const signed char *w0 = wgt[2 * fp], *w1 = wgt[2 * fp + 1];
        int *r0 = res + (2 * fp) * OUT_W, *r1 = r0 + OUT_W;
        for (int x0 = 0; x0 < OUT_W; x0 += 2) {
            MATRIX_K_LEN = K_TERMS;
            MATRIX_TERM_IDX = 0;
            int k = 0;
            for (int c = 0; c < 3; c++)
                for (int dy = 0; dy < 5; dy++) {
                    const unsigned char *p = img + (c << 10) + ((y + dy) << 5) + x0;
                    for (int dx = 0; dx < 5; dx++, k++)   /* one bus write per term */
                        MATRIX_TERM_DATA = p[dx] | (p[dx + 1] << 8)
                                         | ((unsigned int)(unsigned char)w0[k] << 16)
                                         | ((unsigned int)(unsigned char)w1[k] << 24);
                }
            MATRIX_CONTROL = 1;
            while (!(MATRIX_CONTROL & 2)) { }
            r0[x0]     = (int)MATRIX_RESULT(0);   /* patch x0,   filter 2fp   */
            r1[x0]     = (int)MATRIX_RESULT(1);   /* patch x0,   filter 2fp+1 */
            r0[x0 + 1] = (int)MATRIX_RESULT(2);   /* patch x0+1, filter 2fp   */
            r1[x0 + 1] = (int)MATRIX_RESULT(3);   /* patch x0+1, filter 2fp+1 */
        }
    }
    return read_cycle() - t0;
}

/* ------------------------------------------------------------------ mode 0: software only */
/* weight * pixel by shift-and-add. The pixel is 0..127, so at most 7 loop passes. */
static int mul_pixel(int w, unsigned int pixel) {
    int acc = 0;
    while (pixel) { if (pixel & 1) acc += w; w <<= 1; pixel >>= 1; }
    return acc;
}
static unsigned int row_software(int y, int nfp) {
    unsigned int t0 = read_cycle();
    for (int f = 0; f < 2 * nfp; f++) {
        const signed char *w = wgt[f];
        int *r = res + f * OUT_W;
        for (int x = 0; x < OUT_W; x++) {
            int acc = 0, k = 0;
            for (int c = 0; c < 3; c++)
                for (int dy = 0; dy < 5; dy++) {
                    const unsigned char *p = img + (c << 10) + ((y + dy) << 5) + x;
                    for (int dx = 0; dx < 5; dx++, k++) acc += mul_pixel(w[k], p[dx]);
                }
            r[x] = acc;
        }
    }
    return read_cycle() - t0;
}

/* ------------------------------------------------------------------ power-on self-test */
/* Fill the top of the image and the first two filters with a pattern, compute row 0 with the
 * engine and with the CPU-fed array, and check that the 56 results they share agree. */
static void selftest(void) {
    static int engine_res[2 * OUT_W];
    unsigned int v = 3;
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < 5 * 32; i++) { img[(c << 10) + i] = v & 127; v += 7; }
    int s = -60;
    for (int k = 0; k < K_TERMS; k++) { wgt[0][k] = (signed char)s; wgt[1][k] = (signed char)(40 - s); s += 3; }
    for (int c = 0; c < 3; c++) engine_load_image((unsigned int)c << 10, 5 * 32);
    engine_load_weights(1);

    unsigned int engine_cycles = row_engine(0);
    for (int i = 0; i < 2 * OUT_W; i++) engine_res[i] = res[i];
    unsigned int cpufed_cycles = row_cpufed(0, 1);
    int ok = (CONV_ID == 0x434F4E56u);
    for (int i = 0; i < 2 * OUT_W; i++) if (engine_res[i] != res[i]) ok = 0;

    uart_puts(ok ? "SELFTEST PASS" : "SELFTEST FAIL");
    uart_puts(" engine_row_cycles="); uart_putu(engine_cycles);
    uart_puts(" cpufed_cycles_for_1_of_16_filter_pairs="); uart_putu(cpufed_cycles);
    uart_puts(" first="); if (res[0] < 0) { uart_putc('-'); uart_putu(0u - (unsigned int)res[0]); } else uart_putu((unsigned int)res[0]);
    uart_putc('\n');
}

/* ------------------------------------------------------------------ command loop */
int main(void) {
    selftest();
    uart_puts("READY\n");
    for (;;) {
        unsigned int cmd = uart_getc();
        if (cmd == 'P') {
            uart_puts("MXC2");
        } else if (cmd == 'S') {
            selftest();                 /* overwrites part of the image and weights: reload them afterwards */
        } else if (cmd == 'W') {
            unsigned int sum = uart_read((unsigned char *)wgt, N_FILTERS * K_TERMS);
            engine_load_weights(N_FILTERS / 2);
            uart_putc('K'); uart_putc(sum);
        } else if (cmd == 'I') {
            unsigned int sum = uart_read(img, IMG_BYTES);
            engine_load_image(0, IMG_BYTES);
            uart_putc('K'); uart_putc(sum);
        } else if (cmd == 'R') {
            unsigned int mode = uart_getc(), row = uart_getc(), nfp = uart_getc();
            unsigned int cycles;
            if (row >= OUT_W) row = 0;
            if (nfp < 1 || nfp > 16) nfp = 16;
            if (mode == 2) {
                cycles = row_engine((int)row);
            } else {
                for (int i = 0; i < ROW_RESULTS; i++) res[i] = 0;
                cycles = mode == 1 ? row_cpufed((int)row, (int)nfp) : row_software((int)row, (int)nfp);
            }
            uart_putc('D'); uart_putc(mode); uart_putc(row);
            uart_put32(cycles);
            unsigned int sum = 0;
            for (int i = 0; i < ROW_RESULTS; i++) {
                unsigned int v = (unsigned int)res[i];
                uart_put32(v);
                sum += (v & 0xff) + ((v >> 8) & 0xff) + ((v >> 16) & 0xff) + (v >> 24);
            }
            uart_putc(sum);
        }
    }
}
