module flash_control #(
    parameter int PAGEBYTES = 256,
    parameter int N = 8,
    parameter SPIFREQ = 10_000000,
    parameter CLKFREQ = 100_000000
)(
    input logic clk, areset, start,

    input logic [1:0] cmd, // READ? PROGRAM? ERASE?
    input logic [23:0] addr,
    input logic [8:0] len,  // number of bytes need to be retrieved during a READ (0-256)
    input logic [PAGEBYTES*8-1:0] wdata,
    output logic [PAGEBYTES*8-1:0] rdata,
    output logic busy, done,

    input logic miso,
    output logic sclk, mosi, cs
);

    logic spi_start, spi_busy, spi_done;
    logic [7:0] spi_in_data, spi_out_data;

    spi_master #(
        .N(N), .SPIFREQ(SPIFREQ), .CLKFREQ(CLKFREQ)
    ) spimaster (
        .clk(clk), .areset(areset), .start(spi_start),
        .miso(miso), .in_data(spi_in_data),
        .sclk(sclk), .busy(spi_busy), .done(spi_done),
        .mosi(mosi), .out_data(spi_out_data)
    );

    typedef enum logic [1:0] {READ = 2'b00, PROG = 2'b01, ERAS = 2'b10} cmd_t;

    typedef enum logic {IDLE, PULSE, WAIT, WEN, DONE} state_t;
    state_t state;

    logic [1:0] cmd_p;

    logic [8:0] total_bytes;
    logic [8:0] byte_idx;
    logic [8:0] data_byte_number;
    logic wen_done;
    assign data_byte_number = byte_idx - 4;

    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            done <= 1'b0;
            rdata <= '0;
            cs <= 1'b1;
            state <= IDLE;
            byte_idx <= 9'b0; total_bytes <= 9'b0;
            spi_start <= 1'b0; spi_in_data <= '0;
            wen_done <= 1'b0;
        end
        else begin
            done <= 1'b0;
            case (state)
                IDLE : begin
                    if (start) begin
                        cmd_p <= cmd;
                        case (cmd)
                            READ : total_bytes <= len + 4;
                            PROG : total_bytes <= len + 4;
                            ERAS : total_bytes <= 4;
                        endcase
                        byte_idx <= 9'd0;
                        cs <= 1'b0;
                        state <= PULSE;
                    end
                end
                PULSE: begin
                    case (cmd_p)
                        READ: begin
                            case (byte_idx)
                                0: spi_in_data <= 8'h03;
                                1: spi_in_data <= addr[23:16];
                                2: spi_in_data <= addr[15:8];
                                3: spi_in_data <= addr[7:0];
                                default: spi_in_data <= 8'h00;   // dummy, drives read clocking
                            endcase
                        end
                        PROG: begin
                            if (!wen_done) state <= WEN;
                            else begin
                                case (byte_idx)
                                    0: spi_in_data <= 8'h02;
                                    1: spi_in_data <= addr[23:16];
                                    2: spi_in_data <= addr[15:8];
                                    3: spi_in_data <= addr[7:0];
                                    default: spi_in_data <= wdata[(byte_idx-4)*8 +: 8]; // MSB/LSB convention, your choice
                                endcase
                            end
                        end
                        ERAS: begin
                            case (byte_idx)
                                0: spi_in_data <= 8'h20;
                                1: spi_in_data <= addr[23:16];
                                2: spi_in_data <= addr[15:8];
                                3: spi_in_data <= addr[7:0];
                            endcase
                        end
                    endcase
                    spi_start <= 1'b1;
                    state <= WAIT;
                end
                WAIT : begin
                    spi_start <= 1'b0;
                    if (spi_done) begin

                        if ((byte_idx > 3) && cmd_p == READ) begin
                            rdata[(data_byte_number)*8 +: 8] <= spi_out_data;      // lsb first filled in rdata
                        end

                        if (byte_idx == total_bytes - 1) state <= DONE;
                        else state <= PULSE;

                        byte_idx <= byte_idx + 1'b1;
                    end
                end
                WEN  : begin
                    spi_in_data <= 8'h06;
                    wen_done <= 1;
                    cs <= 1'b1;
                    state <= IDLE;
                end
                DONE : begin
                    cs <= 1'b1;
                    done <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

    assign busy = (state != IDLE);

endmodule
