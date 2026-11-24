`timescale 1ns / 1ps

// One 2xK by Kx2 tile per START, K = 1..75. All addresses are byte offsets.
// 00 write bit 0: START; read bit 0: BUSY, bit 1: DONE (until next START).
// 04 K_LEN, 08 TERM_INDEX: read/write low byte. Reset defaults: 75 and 0.
// 0C TERM_DATA: write bytes [low..high] = A[0][k], A[1][k], B[k][0], B[k][1].
// Each nonempty TERM_DATA write increments TERM_INDEX. Write all used operands
// before START. Operand storage is retained between jobs and is uninitialized at reset.
// 10, 14, 18, 1C: read the four signed 32-bit results in row order after DONE.
module AXIMatrix (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  logic        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST",
       X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  logic        s_axi_aresetn,

    input  logic [11:0] s_axi_awaddr,
    input  logic [2:0]  s_axi_awprot,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [11:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready
);
    localparam int K_MAX = 75;
    localparam int K_WIDTH = $clog2(K_MAX + 1);
    localparam logic [11:0] CONTROL = 'h00, K_LEN = 'h04, TERM_INDEX = 'h08,
                            TERM_DATA = 'h0C, C00 = 'h10, C01 = 'h14,
                            C10 = 'h18, C11 = 'h1C;
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    logic signed [7:0] a_tile [0:1][0:K_MAX-1];
    logic signed [7:0] b_tile [0:K_MAX-1][0:1];
    logic signed [31:0] result [0:1][0:1];
    logic [K_WIDTH-1:0] k_len, term_index;
    logic start_pulse, busy, done, done_sticky;
    wire job_active = start_pulse || busy;

    systolic_controller #(.N(2), .K_MAX(K_MAX)) controller (
        .clk(s_axi_aclk), .rst(!s_axi_aresetn), .start(start_pulse),
        .k_len(k_len), .A(a_tile), .B(b_tile),
        .busy(busy), .done(done), .C(result)
    );

    // As in AXICounter, AXI can deliver AW and W in either order.
    // Capture each independently, then execute the write exactly once.
    logic aw_pending, w_pending;
    logic [11:0] awaddr_reg;
    logic [31:0] wdata_reg;
    logic [3:0] wstrb_reg;
    assign s_axi_awready = s_axi_aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = s_axi_aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = s_axi_aresetn && !s_axi_rvalid;

    // Only the addressed byte lanes change. This storage needs no reset.
    always_ff @(posedge s_axi_aclk) begin
        if (s_axi_aresetn && aw_pending && w_pending &&
            awaddr_reg == TERM_DATA && term_index < K_MAX) begin
            if (wstrb_reg[0]) a_tile[0][term_index] <= wdata_reg[7:0];
            if (wstrb_reg[1]) a_tile[1][term_index] <= wdata_reg[15:8];
            if (wstrb_reg[2]) b_tile[term_index][0] <= wdata_reg[23:16];
            if (wstrb_reg[3]) b_tile[term_index][1] <= wdata_reg[31:24];
        end
    end

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= OKAY;
            k_len <= K_MAX;
            term_index <= '0;
            start_pulse <= 1'b0;
            done_sticky <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (done) done_sticky <= 1'b1;
            if (s_axi_bready) s_axi_bvalid <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_reg <= s_axi_awaddr;
                aw_pending <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_reg <= s_axi_wdata;
                wstrb_reg <= s_axi_wstrb;
                w_pending <= 1'b1;
            end

            if (aw_pending && w_pending) begin
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= OKAY;
                case (awaddr_reg)
                    CONTROL: if (wstrb_reg[0] && wdata_reg[0]) begin
                        if (job_active) s_axi_bresp <= SLVERR;
                        else begin
                            start_pulse <= 1'b1;
                            done_sticky <= 1'b0;
                        end
                    end
                    K_LEN: if (wstrb_reg[0]) begin
                        if (wdata_reg[7:0] >= 1 && wdata_reg[7:0] <= K_MAX)
                            k_len <= wdata_reg[K_WIDTH-1:0];
                        else s_axi_bresp <= SLVERR;
                    end
                    TERM_INDEX: if (wstrb_reg[0]) begin
                        if (wdata_reg[7:0] < K_MAX)
                            term_index <= wdata_reg[K_WIDTH-1:0];
                        else s_axi_bresp <= SLVERR;
                    end
                    TERM_DATA: if (|wstrb_reg) begin
                        if (term_index < K_MAX) term_index <= term_index + 1'b1;
                        else s_axi_bresp <= SLVERR;
                    end
                    default: s_axi_bresp <= SLVERR;
                endcase
            end
        end
    end

    // Latch the read value at the address handshake. Keep it stable until RREADY.
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
            s_axi_rresp <= OKAY;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rresp <= OKAY;
            case (s_axi_araddr)
                CONTROL:    s_axi_rdata <= {30'b0, done_sticky || done, job_active};
                K_LEN:      s_axi_rdata <= 32'(k_len);
                TERM_INDEX: s_axi_rdata <= 32'(term_index);
                C00:        s_axi_rdata <= result[0][0];
                C01:        s_axi_rdata <= result[0][1];
                C10:        s_axi_rdata <= result[1][0];
                C11:        s_axi_rdata <= result[1][1];
                default: begin
                    s_axi_rdata <= '0;
                    s_axi_rresp <= SLVERR;
                end
            endcase
        end else if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
endmodule
