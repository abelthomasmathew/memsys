module flash_model #(
    parameter MEMSIZE = 4096 
)(
    input logic sclk, mosi, cs,
    output logic miso
);

    logic [7:0] flash [0:MEMSIZE-1];

    initial begin
        for (int i=0; i<MEMSIZE; i++) begin
            flash[i] = 8'hff;
        end
    end

    int bitcount;       // 0..7, bit position within current byte
    int bytecount;       // byte number
    logic [7:0] rxshift;
    logic [7:0] rxbyte;        // full byte value being completed this cycle
    logic [7:0] opcode;
    logic [23:0] addr_reg;
    logic [7:0] txshift;
    logic wen_done;   // is wen done??
    logic wip;        // write-in-progress
    int wip_countdown;
    int sector_base;
    
    always @(negedge cs) begin
        bitcount <= 0;
        bytecount <= 0;
        rxshift <= 8'h00;
    end

    always @(posedge sclk) begin
        if (!cs) begin
            rxbyte = {rxshift[6:0], mosi};

            if (bitcount == 7) begin
                case (bytecount)
                    0: opcode <= rxbyte;
                    1: addr_reg[23:16] <= rxbyte;
                    2: addr_reg[15:8] <= rxbyte;
                    3: addr_reg[7:0] <= rxbyte; 
                    default: begin
                        if (opcode == 8'h02 && wen_done && !wip) begin
                            flash[(addr_reg + (bytecount-4))%MEMSIZE] <= rxbyte;         // if is PAGE PROGRAM, then write once bytecount > 3
                        end
                    end
                endcase

                if (bytecount == 0 && rxbyte == 8'h06) begin
                    wen_done <= 1'b1;                         // if its the 0th byte and wen opcode is recieved
                end

                bitcount <= 0;
                bytecount <= bytecount + 1;
            end
            else begin
                rxshift <= rxbyte;
                bitcount <= bitcount + 1;
            end
        end
    end

    always_comb begin
        txshift = 8'h00;
        case (opcode)
            8'h03: if (bytecount >= 4) txshift = flash[(addr_reg + (bytecount-4))%MEMSIZE];  // READ
            8'h05: if (bytecount >= 1) txshift = {7'b0, wip};  // POLL - if wip = 1, another POLL happens until wip = 0
            default: txshift = 8'h00;
        endcase
    end
    assign miso = txshift[7-bitcount];

endmodule
