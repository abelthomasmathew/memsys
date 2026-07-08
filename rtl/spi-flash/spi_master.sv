module spi_master#(
    parameter N = 8,
    parameter SPIFREQ = 10_000000,
    parameter CLKFREQ = 100_000000
)(
    input logic clk, areset, start, miso,
    input logic [N-1:0] in_data,
    output logic sclk, mosi, busy, done,
    output logic [N-1:0] out_data
);

    localparam int RATE = CLKFREQ/(2*SPIFREQ);
    localparam int BITS = $clog2(RATE);
    logic [BITS-1:0] tickcount;
    logic tick;
    
    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            tick <= 1'b0;
            tickcount <= '0;
        end
        else if (tickcount == (RATE-1)) begin
            tick <= 1'b1;
            tickcount <= '0;
        end
        else begin
            tick <= 1'b0;
            tickcount <= tickcount + 1'b1;
        end
    end

    typedef enum logic {IDLE,SEND} state_t;
    state_t state;

    localparam int EDGE = $clog2(2*N + 1);
    logic [EDGE-1:0] edge_count;
    logic [N-1:0] tx_reg, rx_reg;                   // tx for MOSI and rx for MISO

    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            state <= IDLE;
            sclk <= 1'b0;                           // CPOL = 0
            tx_reg <= '0;
            rx_reg <= '0;
            edge_count <= '0;
            out_data <= '0;
            done <= 1'b0;
        end
        else begin
            done <= 1'b0;
            case (state)
                IDLE   : begin
                    sclk <= 1'b0;
                    if (start) begin
                        tx_reg <= in_data;          // loading data to send
                        rx_reg <= '0;
                        edge_count <= '0;
                        state <= SEND;
                    end
                end

                SEND   : begin
                    if (tick) begin
                        if (~sclk) begin                          
                            sclk <= 1'b1;                           // sampling on positive edge
                            rx_reg <= {rx_reg[N-2:0], miso};
                        end
                        else begin
                            sclk <= 1'b0;                           // shift out MOSI on neg edge
                            tx_reg <= {tx_reg[N-2:0], 1'b0}; 
                        end

                        if (edge_count == 2*N-1) begin
                            out_data <= rx_reg;
                            state <= IDLE;
                            done <= 1'b1;
                        end
                        else edge_count <= edge_count + 1'b1;
                    end
                end

                default : state <= IDLE;
            endcase 
        end
    end

    assign busy = (state == SEND);
    assign mosi = busy ? tx_reg[N-1] : 1'b0;

endmodule
