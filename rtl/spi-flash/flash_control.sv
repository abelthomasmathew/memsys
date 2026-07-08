module flash_control #(
    parameter int PAGEBYTES = 256,
    parameter int N = 8,
    parameter SPIFREQ = 10_000000,
    parameter CLKFREQ = 100_000000
)(
    input logic clk, areset, start,

    input logic [1:0] cmd,           // READ / PROG / ERAS
    input logic [23:0] addr,
    input logic [8:0] len,           // bytes to read (0-256)
    input logic [PAGEBYTES*8-1:0] wdata,
    output logic [PAGEBYTES*8-1:0] rdata,
    output logic busy, done,

    // for the flash memory
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

    typedef enum logic [1:0] {READ, PROG, ERAS} cmd_t;
    typedef enum logic [1:0] {WEN, MAIN, POLL} phase_t;
    typedef enum logic [2:0] {IDLE, PULSE, WAIT, CSGAP, DONE} state_t;

    state_t state;
    phase_t phase;
    logic [1:0] cmd_p;

    logic [8:0] total_bytes;
    logic [8:0] byte_idx;
    logic [8:0] data_byte_number;
    logic [7:0] status_byte;

    assign data_byte_number = byte_idx - 4;

    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            done        <= 1'b0;
            rdata       <= '0;
            cs          <= 1'b1;
            state       <= IDLE;
            phase       <= WEN;
            byte_idx    <= 9'b0;
            total_bytes <= 9'b0;
            spi_start   <= 1'b0;
            spi_in_data <= '0;
            status_byte <= '0;
        end
        else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        cmd_p <= cmd;
                        byte_idx <= 9'd0;
                        cs <= 1'b0;
                        if (cmd == READ) begin
                            phase <= MAIN;
                            total_bytes <= len + 4;
                        end
                        else begin
                            phase <= WEN;
                            total_bytes <= 9'd1;      // just the 0x06 byte
                        end
                        state <= PULSE;
                    end
                end

                PULSE: begin
                    case (phase)
                        WEN: spi_in_data <= 8'h06;

                        MAIN: begin
                            case (cmd_p)
                                READ: begin
                                    case (byte_idx)
                                        0: spi_in_data <= 8'h03;
                                        1: spi_in_data <= addr[23:16];
                                        2: spi_in_data <= addr[15:8];
                                        3: spi_in_data <= addr[7:0];
                                        default: spi_in_data <= 8'h00; // dummy, drives read clocking
                                    endcase
                                end
                                PROG: begin
                                    case (byte_idx)
                                        0: spi_in_data <= 8'h02;
                                        1: spi_in_data <= addr[23:16];
                                        2: spi_in_data <= addr[15:8];
                                        3: spi_in_data <= addr[7:0];
                                        default: spi_in_data <= wdata[(byte_idx-4)*8 +: 8];
                                    endcase
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
                        end

                        POLL: begin
                            case (byte_idx)
                                0: spi_in_data <= 8'h05;   // Read Status Register opcode
                                default: spi_in_data <= 8'h00; // dummy, clocks out status byte
                            endcase
                        end
                    endcase

                    spi_start <= 1'b1;
                    state <= WAIT;
                end

                WAIT: begin
                    spi_start <= 1'b0;
                    if (spi_done) begin

                        // capture READ data
                        if (phase == MAIN && cmd_p == READ && byte_idx > 3) begin
                            rdata[data_byte_number*8 +: 8] <= spi_out_data;
                        end

                        // capture status byte (2nd byte of POLL, byte_idx==1)
                        if (phase == POLL && byte_idx == 1) begin
                            status_byte <= spi_out_data;
                        end

                        if (byte_idx == total_bytes - 1) begin
                            cs    <= 1'b1;     // deassert CS, this phase's transaction is done
                            state <= CSGAP;
                        end
                        else begin
                            byte_idx <= byte_idx + 1'b1;
                            state    <= PULSE;
                        end
                    end
                end

                CSGAP: begin
                    case (phase)
                        WEN: begin
                            // WEN done -> move into the real command
                            phase <= MAIN;
                            case (cmd_p)
                                PROG: total_bytes <= len + 4;
                                ERAS: total_bytes <= 9'd4;
                            endcase
                            byte_idx <= 9'd0;
                            cs       <= 1'b0;
                            state    <= PULSE;
                        end

                        MAIN: begin
                            if (cmd_p == READ) begin
                                state <= DONE;      // READ needs no polling
                            end
                            else begin
                                phase       <= POLL;
                                total_bytes <= 9'd2; // opcode + dummy
                                byte_idx    <= 9'd0;
                                cs          <= 1'b0;
                                state       <= PULSE;
                            end
                        end

                        POLL: begin
                            if (status_byte[0]) begin
                                // WIP still set -> poll again
                                byte_idx <= 9'd0;
                                cs       <= 1'b0;
                                state    <= PULSE;      // phase stays POLL
                            end
                            else begin
                                state <= DONE;          // chip finished, safe to report done
                            end
                        end
                    endcase
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

            endcase
        end
    end

    assign busy = (state != IDLE);

endmodule
