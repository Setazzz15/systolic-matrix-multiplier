`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// conv1_engine, N x N version (N = 8 by default: 64 processing elements)
//
// Computes one output row of a 5x5, 3-channel, 32-filter convolution (the first layer of
// Adv_Attack's Net) on an N x N systolic array, with no processor in the data path.
//
// One "job" now covers N image positions x N filters:
//       A lane i = patch at column x0 + i        (x0 = N * xg, xg = column group)
//       B lane j = filter f0 + j                 (f0 = N * fg, fg = filter group)
// With N = 8 a row is 4 column groups x 4 filter groups = 16 jobs (it was 224 with N = 2).
// The last column group reaches columns 28..31, which do not exist in the 28-wide output.
// Those lanes compute garbage that is stored but never read.
//
// What had to change from the 2 x 2 engine, and why
//   1. Pixels: N lanes need N different pixels in the same clock, but one block RAM has only
//      2 read ports. So the image is kept in N/2 identical RAMs. A load writes all of them.
//   2. Weights: one RAM per pair of filters, read together, so all N weights of a term arrive
//      in one clock.
//   3. Stagger: lane i must run i terms behind lane 0 (same rule as k = counter - i in
//      systolic_controller). The window counters and the weights go through i delay registers.
//   4. A job is K + 2N - 1 clocks: K terms, then 2(N-1) more for the last product to travel
//      to the bottom-right PE, then the capture clock. For N = 8 that is 90.
//   5. N*N sums are captured at once and written to the result RAM one per clock, by shifting,
//      while the next job is already being fed.
//////////////////////////////////////////////////////////////////////////////////
module conv1_engine #(
    parameter int N = 8                // lanes each way: 4, 8 or 16
) (
    input  logic clk,
    input  logic rst,

    // Loading, done by the CPU while the engine is idle (same interface as the 2 x 2 engine).
    input  logic        img_we,
    input  logic [11:0] img_waddr,   // {channel[1:0], row[4:0], col[4:0]}
    input  logic [7:0]  img_wdata,   // pixel, 0..127
    input  logic        wgt_we,
    input  logic [10:0] wgt_waddr,   // {filter_pair[3:0], term[6:0]}
    input  logic [15:0] wgt_wdata,   // {weight of filter 2p+1, weight of filter 2p}

    // Run one output row.
    input  logic        start,
    input  logic [4:0]  row,         // output row, 0..27
    output logic        busy,
    output logic        done,        // one-clock pulse when the row's results are stored

    // Results of the last row: address {filter[4:0], col[4:0]}.
    input  logic [9:0]  res_raddr,
    output logic signed [31:0] res_rdata
);
    localparam int K       = 75;               // terms per dot product: 3 channels * 5 * 5
    localparam int LAST_S  = K + 2 * N - 2;    // last cycle of a job
    localparam int GROUPS  = 32 / N;           // filter groups, and column groups (32 >= 28 columns)
    localparam int GW      = $clog2(GROUPS);   // bits in a group number
    localparam int LW      = $clog2(N);        // bits in a lane number
    localparam int PAIRS   = N / 2;            // filter pairs per group = image RAM copies

    // ------------------------------------------------------------------ job position
    logic        running;
    logic [7:0]  s;                    // cycle within the current job
    logic [GW-1:0] fg, xg;             // filter group and column group of the current job
    logic [4:0]  row_r;

    // Window position of lane 0's term: {channel[1:0], dy[2:0], dx[2:0]}. Lane i uses the same
    // values i clocks later, which makes it run i terms behind.
    logic [7:0]  coord0;
    logic [7:0]  coord_d [1:N-1];
    logic        rd_d    [1:N-1];
    wire         rd0 = running && (s < K);     // lane 0 issues a real read in this clock
    wire  [7:0]  coord [0:N-1];
    wire         rd    [0:N-1];
    logic        vld   [0:N-1];                // lane i's RAM output is a real term in this clock
    for (genvar i = 0; i < N; i++) begin : lane_view
        if (i == 0) begin : first
            assign coord[i] = coord0;
            assign rd[i]    = rd0;
        end else begin : later
            assign coord[i] = coord_d[i];
            assign rd[i]    = rd_d[i];
        end
    end
    wire  [1:0]  c0  = coord0[7:6];
    wire  [2:0]  dy0 = coord0[5:3];
    wire  [2:0]  dx0 = coord0[2:0];

    // ------------------------------------------------------------------ image RAMs
    logic [11:0] img_raddr [0:N-1];
    logic [7:0]  pix       [0:N-1];
    for (genvar i = 0; i < N; i++) begin : pixel_addr
        // image[channel][row_r + dy][N*xg + i + dx]; the image is 32 x 32, so no multiplier is needed.
        assign img_raddr[i] = {coord[i][7:6],
                               row_r + 5'(coord[i][5:3]),
                               5'(xg) * 5'(N) + 5'(i) + 5'(coord[i][2:0])};
    end
    for (genvar m = 0; m < PAIRS; m++) begin : image_copy
        conv1_img_ram ram (
            .clk(clk),
            .we(img_we), .waddr(img_waddr), .wdata(img_wdata),
            .raddr_a(img_raddr[2*m]),   .q_a(pix[2*m]),
            .raddr_b(img_raddr[2*m+1]), .q_b(pix[2*m+1])
        );
    end

    // ------------------------------------------------------------------ weight RAMs
    // RAM q holds filters 2q and 2q+1 of every group. Address {group, term}.
    logic [15:0] wq [0:PAIRS-1];
    for (genvar q = 0; q < PAIRS; q++) begin : weight_pair
        // wgt_waddr[10:7] is the filter pair 0..15: its upper bits are the group, its lower bits pick the RAM.
        wire we_q = wgt_we && (wgt_waddr[7 +: $clog2(PAIRS)] == q);
        conv1_wgt_ram #(.AW(GW + 7)) ram (
            .clk(clk),
            .we(we_q), .waddr({wgt_waddr[10 -: GW], wgt_waddr[6:0]}), .wdata(wgt_wdata),
            .raddr({fg, s[6:0]}), .q(wq[q])
        );
    end
    // Lane j's weight goes through j delay registers so it lines up with lane j's pixel.
    logic signed [7:0] a_lane [0:N-1];
    logic signed [7:0] b_lane [0:N-1];
    for (genvar j = 0; j < N; j++) begin : weight_delay
        wire [7:0] w_now = wq[j/2][8*(j%2) +: 8];
        wire [7:0] w_late;
        conv1_delay #(.W(8), .D(j)) line (.clk(clk), .d(w_now), .q(w_late));
        assign b_lane[j] = w_late;
        assign a_lane[j] = pix[j];
    end

    // ------------------------------------------------------------------ the systolic array
    logic cap;                         // capture cycle: sums are final, read them and clear the PEs
    logic signed [31:0] C [0:N-1][0:N-1];
    Systolic_NxN #(.N(N)) array (
        .clk     (clk),
        .rst     (rst || cap),
        .a_in    (a_lane),
        .valid_a (vld),
        .b_in    (b_lane),
        .valid_b (vld),
        .PE      (C)
    );

    // ------------------------------------------------------------------ result RAM
    // C[i][j] pairs patch lane i with filter lane j. After a capture the N*N sums sit in a
    // shift register and leave one per clock: entry n = i*N + j.
    (* ram_style = "block" *) logic signed [31:0] res_mem [0:1023];
    logic signed [31:0] resq [0:N*N-1];
    logic [GW-1:0]   cap_fg, cap_xg;
    logic [2*LW:0]   wr_left;          // result words still to store
    logic [2*LW-1:0] wr_idx;           // {i, j} of the word at the head of the shift register
    logic            finishing;

    // filter = N*cap_fg + j, column = N*cap_xg + i
    wire [9:0] res_waddr = {5'({cap_fg, wr_idx[LW-1:0]}), 5'({cap_xg, wr_idx[2*LW-1:LW]})};
    always_ff @(posedge clk) begin
        if (wr_left != 0) res_mem[res_waddr] <= resq[0];
        res_rdata <= res_mem[res_raddr];
    end

    // ------------------------------------------------------------------ control
    always_ff @(posedge clk) begin
        // Lane i repeats what lane i-1 did one clock earlier.
        for (int i = 1; i < N; i++) begin
            coord_d[i] <= coord[i-1];
            rd_d[i]    <= rst ? 1'b0 : rd[i-1];
        end
        for (int i = 0; i < N; i++) vld[i] <= rst ? 1'b0 : rd[i];

        if (rst) begin
            running <= 1'b0;  busy <= 1'b0;  done <= 1'b0;  finishing <= 1'b0;  cap <= 1'b0;
            wr_left <= '0;  wr_idx <= '0;  s <= '0;  coord0 <= '0;  fg <= '0;  xg <= '0;
        end else begin
            done <= 1'b0;
            cap  <= 1'b0;

            if (start && !busy) begin
                busy <= 1'b1;  running <= 1'b1;  row_r <= row;
                s <= '0;  coord0 <= '0;  fg <= '0;  xg <= '0;
            end else if (running) begin
                if (s == LAST_S) begin
                    // Job done feeding and draining: capture next clock, move to the next job.
                    cap <= 1'b1;  cap_fg <= fg;  cap_xg <= xg;
                    s <= '0;  coord0 <= '0;
                    if (xg == GW'(GROUPS - 1)) begin
                        xg <= '0;
                        if (fg == GW'(GROUPS - 1)) begin running <= 1'b0; finishing <= 1'b1; end
                        else fg <= fg + 1'b1;
                    end else xg <= xg + 1'b1;
                end else begin
                    s <= s + 1'b1;
                    // Step through the window: dx fastest, then dy, then channel.
                    if (dx0 == 3'd4) begin
                        if (dy0 == 3'd4) coord0 <= {c0 + 1'b1, 3'd0, 3'd0};
                        else             coord0 <= {c0, dy0 + 1'b1, 3'd0};
                    end else             coord0 <= {c0, dy0, dx0 + 1'b1};
                end
            end

            if (cap) begin
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++) resq[i*N + j] <= C[i][j];
                wr_left <= (2*LW+1)'(N * N);
                wr_idx  <= '0;
            end else if (wr_left != 0) begin
                for (int n = 0; n < N*N - 1; n++) resq[n] <= resq[n+1];
                wr_left <= wr_left - 1'b1;
                wr_idx  <= wr_idx + 1'b1;
            end else if (finishing) begin
                finishing <= 1'b0;  busy <= 1'b0;  done <= 1'b1;
            end
        end
    end
endmodule

// One copy of the image: a true dual-port block RAM. Port A is shared between loading and
// reading; port B only reads. Two lanes read from each copy.
module conv1_img_ram (
    input  logic clk,
    input  logic we,
    input  logic [11:0] waddr,
    input  logic [7:0]  wdata,
    input  logic [11:0] raddr_a, raddr_b,
    output logic [7:0]  q_a, q_b
);
    (* ram_style = "block" *) logic [7:0] mem [0:4095];
    wire [11:0] addr_a = we ? waddr : raddr_a;
    always_ff @(posedge clk) begin
        if (we) mem[addr_a] <= wdata;
        q_a <= mem[addr_a];
    end
    always_ff @(posedge clk) q_b <= mem[raddr_b];
endmodule

// Weights of two neighbouring filters: {odd filter, even filter} per word.
module conv1_wgt_ram #(parameter int AW = 9) (
    input  logic clk,
    input  logic we,
    input  logic [AW-1:0] waddr, raddr,
    input  logic [15:0] wdata,
    output logic [15:0] q
);
    (* ram_style = "block" *) logic [15:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        q <= mem[raddr];
    end
endmodule

// d delayed by D clocks (D = 0 is a plain wire).
module conv1_delay #(parameter int W = 8, parameter int D = 1) (
    input  logic clk,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
    if (D == 0) begin : none
        assign q = d;
    end else begin : some
        logic [W-1:0] sr [0:D-1];
        always_ff @(posedge clk) begin
            sr[0] <= d;
            for (int n = 1; n < D; n++) sr[n] <= sr[n-1];
        end
        assign q = sr[D-1];
    end
endmodule
