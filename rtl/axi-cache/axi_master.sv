module axi_master #(
    parameter int ADDRWIDTH = 32,
    parameter int DATAWIDTH = 32
)(
    input logic clk, areset,

    // AXI ports

    output logic [ADDRWIDTH-1:0] araddr,    // base address of read
    output logic [1:0] arburst,             // incrementing burst = 01
    output logic [7:0] arlen,               // how many chunks? (how many ever - 1) is stored in arelen
    output logic [2:0] arsize,              // how many BYTES is each chunk = 2^arsize
    output logic arvalid,                   // is the signal being sent a valid one?
    input logic arready,                    // when slave is ready

    input logic [DATAWIDTH-1 : 0] rdata,
    input logic [1:0] rresp,
    input logic rlast,
    input logic rvalid,
    output logic rready,

    output logic [ADDRWIDTH-1:0] awaddr,
    output logic [1:0] awburst,
    output logic [7:0] awlen,
    output logic [2:0] awsize,
    output logic awvalid,
    input logic awready,

    output logic [DATAWIDTH-1:0] wdata,
    output logic [DATAWIDTH/8-1:0] wstrb,
    output logic wlast,
    output logic wvalid,
    input logic wready,

    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready,

    // Client Side

    input logic start,                  // pulse to know that Cache is issue-ing a command
    input logic write,                  // is it write?
    input logic [ADDRWIDTH-1:0] addr,
    input logic [7:0] len,
    input logic [2:0] size,

    input logic [DATAWIDTH-1:0] cwdata,
    input logic [DATAWIDTH/8-1:0] strb,
    input logic cwvalid,
    output logic cwready,

    output logic [DATAWIDTH-1:0] crdata,
    output logic crvalid,
    input logic crready,

    output logic busy,
    output logic done,        // 1-cycle pulse: burst (and BRESP, if write) complete
    output logic [1:0] resp   // BRESP (write) or OR of RRESP across beats (read)

);

    typedef enum logic [2:0] {IDLE, AR, R, AW, W, B} state_t;
    state_t state;

    logic [7:0] totalbursts;    // len latched
    logic [7:0] burstcount;
    logic [1:0] resp_latch;

    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            state <= IDLE;
            arvalid <= 1'b0;
            awvalid <= 1'b0;
            bready <= 1'b0;
            done <= 1'b0;
            burstcount <= '0;
            resp_latch <= 2'b00;
        end
        else begin
            done <= 1'b0;
            case (state)
            
                IDLE : begin
                    if (start) begin
                        totalbursts <= len;
                        burstcount <= '0;
                        if (write) begin
                            state <= AW;
                            awaddr <= addr;
                            awburst <= 2'b01;
                            awlen <= len;
                            awsize <= size;
                            awvalid <= 1'b1;
                        end
                        else begin
                            state <= AR;
                            araddr <= addr;
                            arburst <= 2'b01;
                            arlen <= len;
                            arsize <= size;
                            arvalid <= 1'b1;
                        end
                    end 
                end

                AW : begin
                    if (awvalid && awready) begin
                        awvalid <= 1'b0;
                        state <= W;
                    end
                end

                W : begin
                    if (wvalid && wready) begin
                        if (wlast) begin
                            bready <= 1'b1;
                            state <= B;
                        end
                        else burstcount <= burstcount + 1'b1;
                    end
                end

                B : begin
                    if (bready && bvalid) begin
                        bready <= 1'b0;
                        resp_latch <= bresp;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end

                AR : begin
                    if (arvalid && arready) begin
                        arvalid <= 1'b0;
                        state <= R;
                    end
                end

                R : begin
                    if (rvalid && rready) begin
                        if (rresp != 2'b00) resp_latch <= rresp; // latch the first error
                        if (rlast) begin
                            done <= 1'b1;
                            state <= IDLE;
                        end
                        else burstcount <= burstcount + 1'b1;
                    end
                end

                default : state <= IDLE;
            endcase
        end
    end

    // Write signals combinationally driven to match client side realtime
    assign wvalid = (state == W) && cwvalid;
    assign cwready = (state == W) && wready;
    assign wdata = cwdata;
    assign wstrb = strb;
    assign wlast = (burstcount == totalbursts);

    assign rready = (state == R) && crready;
    assign crvalid = (state == R) && rvalid;
    assign crdata = rdata;

    assign busy = (state != IDLE);
    assign resp = resp_latch;


endmodule
