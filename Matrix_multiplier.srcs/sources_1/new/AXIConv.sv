`timescale 1ns / 1ps

// AXI4-Lite registers in front of conv1_engine, so the PicoRV32 can load an image and the
// weights, start one output row, and read the results. All addresses are byte offsets.
//
// 00 CONTROL   write bit 0: START the row in ROW.   read bit 0: BUSY, bit 1: DONE (until next START)
// 04 ROW       output row to compute, 0..27
// 08 IMG_ADDR  index of the next pixel to load: channel*1024 + row*32 + col
// 0C IMG_DATA  write 4 pixels (0..127), lowest byte first. They are stored at IMG_ADDR..IMG_ADDR+3
//              over the next 4 clocks and IMG_ADDR advances by 4.
// 10 WGT_ADDR  index of the next weight word: filter_pair*128 + term
// 14 WGT_DATA  write {weight of filter 2p+1, weight of filter 2p} in bits 15:0. WGT_ADDR advances by 1.
// 18 RES_ADDR  index of the next result to read: filter*32 + col
// 1C RES_DATA  read one signed 32-bit result. RES_ADDR advances by 1.
// 20 CYCLES    clocks the engine has been busy since this register was last written
// 24 ID        reads 0x434F4E56 ("CONV")
module AXIConv (
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
    localparam logic [11:0] CONTROL = 'h00, ROW = 'h04, IMG_ADDR = 'h08, IMG_DATA = 'h0C,
                            WGT_ADDR = 'h10, WGT_DATA = 'h14, RES_ADDR = 'h18, RES_DATA = 'h1C,
                            CYCLES = 'h20, ID = 'h24;
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    wire clk = s_axi_aclk;
    wire rst = !s_axi_aresetn;

    logic [4:0]  row_reg;
    logic [11:0] img_addr;
    logic [10:0] wgt_addr;
    logic [9:0]  res_addr;
    logic [31:0] cycles;
    logic        start_pulse, busy, done, done_sticky;

    // A 32-bit IMG_DATA write is unpacked into 4 single-byte RAM writes.
    logic [31:0] img_shift;
    logic [2:0]  img_left;
    logic        wgt_we;
    logic [15:0] wgt_wdata;
    logic signed [31:0] res_rdata;

    conv1_engine engine (
        .clk(clk), .rst(rst),
        .img_we(img_left != 0), .img_waddr(img_addr), .img_wdata(img_shift[7:0]),
        .wgt_we(wgt_we), .wgt_waddr(wgt_addr), .wgt_wdata(wgt_wdata),
        .start(start_pulse), .row(row_reg), .busy(busy), .done(done),
        .res_raddr(res_addr), .res_rdata(res_rdata)
    );

    // AXI can deliver the write address and the write data in either order (as in AXICounter):
    // capture each when it arrives, then act once both are here.
    logic aw_pending, w_pending;
    logic [11:0] awaddr_reg;
    logic [31:0] wdata_reg;
    assign s_axi_awready = s_axi_aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = s_axi_aresetn && !w_pending  && !s_axi_bvalid;
    assign s_axi_arready = s_axi_aresetn && !s_axi_rvalid;

    wire read_fire = s_axi_arvalid && s_axi_arready;
    wire job_active = start_pulse || busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_pending <= 1'b0;  w_pending <= 1'b0;
            s_axi_bvalid <= 1'b0;  s_axi_bresp <= OKAY;
            s_axi_rvalid <= 1'b0;  s_axi_rdata <= '0;  s_axi_rresp <= OKAY;
            row_reg <= '0;  img_addr <= '0;  wgt_addr <= '0;  res_addr <= '0;  cycles <= '0;
            start_pulse <= 1'b0;  done_sticky <= 1'b0;  img_left <= '0;  wgt_we <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (done) done_sticky <= 1'b1;
            if (busy) cycles <= cycles + 1'b1;

            // Finish a weight write: the address moves on after the RAM has taken the word.
            if (wgt_we) begin wgt_we <= 1'b0; wgt_addr <= wgt_addr + 1'b1; end

            // Unpack one pixel per clock.
            if (img_left != 0) begin
                img_shift <= {8'b0, img_shift[31:8]};
                img_addr  <= img_addr + 1'b1;
                img_left  <= img_left - 1'b1;
            end

            // ---------------- writes
            if (s_axi_bready) s_axi_bvalid <= 1'b0;
            if (s_axi_awready && s_axi_awvalid) begin awaddr_reg <= s_axi_awaddr; aw_pending <= 1'b1; end
            if (s_axi_wready  && s_axi_wvalid)  begin wdata_reg  <= s_axi_wdata;  w_pending  <= 1'b1; end

            if (aw_pending && w_pending) begin
                aw_pending <= 1'b0;  w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;  s_axi_bresp <= OKAY;
                case (awaddr_reg)
                    CONTROL: if (wdata_reg[0]) begin
                        if (job_active) s_axi_bresp <= SLVERR;
                        else begin start_pulse <= 1'b1; done_sticky <= 1'b0; end
                    end
                    ROW:      row_reg  <= wdata_reg[4:0];
                    IMG_ADDR: img_addr <= wdata_reg[11:0];
                    IMG_DATA: begin
                        if (job_active || img_left != 0) s_axi_bresp <= SLVERR;
                        else begin img_shift <= wdata_reg; img_left <= 3'd4; end
                    end
                    WGT_ADDR: wgt_addr <= wdata_reg[10:0];
                    WGT_DATA: begin
                        if (job_active) s_axi_bresp <= SLVERR;
                        else begin wgt_wdata <= wdata_reg[15:0]; wgt_we <= 1'b1; end
                    end
                    RES_ADDR: res_addr <= wdata_reg[9:0];
                    CYCLES:   cycles   <= '0;
                    default:  s_axi_bresp <= SLVERR;
                endcase
            end

            // ---------------- reads
            // The result RAM always shows the word at RES_ADDR (one clock after the address
            // changes), so a RES_DATA read can take it straight away and then step the address.
            if (read_fire) begin
                s_axi_rvalid <= 1'b1;  s_axi_rresp <= OKAY;
                case (s_axi_araddr)
                    CONTROL:  s_axi_rdata <= {30'b0, done_sticky || done, job_active};
                    ROW:      s_axi_rdata <= 32'(row_reg);
                    IMG_ADDR: s_axi_rdata <= 32'(img_addr);
                    WGT_ADDR: s_axi_rdata <= 32'(wgt_addr);
                    RES_ADDR: s_axi_rdata <= 32'(res_addr);
                    RES_DATA: begin s_axi_rdata <= res_rdata; res_addr <= res_addr + 1'b1; end
                    CYCLES:   s_axi_rdata <= cycles;
                    ID:       s_axi_rdata <= 32'h434F4E56;
                    default:  begin s_axi_rdata <= '0; s_axi_rresp <= SLVERR; end
                endcase
            end else if (s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
