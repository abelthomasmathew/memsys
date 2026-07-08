`timescale 1ns/1ps

module tb_flash;

    localparam int PAGEBYTES = 256;

    logic clk, areset, start;
    logic [1:0] cmd;
    logic [23:0] addr;
    logic [8:0] len;
    logic [PAGEBYTES*8-1:0] wdata;
    logic [PAGEBYTES*8-1:0] rdata;
    logic busy, done;

    logic sclk, mosi, miso, cs;

    initial clk = 0;
    always #5 clk = ~clk;
    
    flash_control #(
        .PAGEBYTES(PAGEBYTES), .N(8),
        .SPIFREQ(10_000000), .CLKFREQ(100_000000)
    ) Controller (
        .clk(clk), .areset(areset), .start(start),
        .cmd(cmd), .addr(addr), .len(len),
        .wdata(wdata), .rdata(rdata),
        .busy(busy), .done(done),

        .miso(miso), .sclk(sclk), .mosi(mosi), .cs(cs)
    );

    flash_model #(
        .MEMSIZE(4096), .POLLS(3), .SECTORSIZE(1024)
    ) Flash (
        .sclk(sclk), .mosi(mosi), .cs(cs),
        .miso(miso)
    );

    int errors = 0;

    task automatic do_op(input [1:0] c, input [23:0] a, input [8:0] l, input [PAGEBYTES*8-1:0] wd);
        begin
            @(posedge clk);
            cmd   = c;
            addr  = a;
            len   = l;
            wdata = wd;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            @(posedge done);
            @(posedge clk); // settle
        end
    endtask

    localparam READ = 2'b00;
    localparam PROG = 2'b01;
    localparam ERAS = 2'b10;

    logic [31:0] pattern;
    logic [PAGEBYTES*8-1:0] prog_data;

    initial begin
        areset = 1'b1;
        start = 1'b0;
        cmd = '0;
        addr = '0;
        len = '0;
        wdata = '0;

        pattern   = 32'hDDCCBBAA; // byte0=AA, byte1=BB, byte2=CC, byte3=DD
        prog_data = '0;

        repeat (4) @(posedge clk);
        areset = 1'b0;
        repeat (4) @(posedge clk);

        // ---- Test 1: ERASE sector at address 0 ----
        $display("[%0t] TEST 1: SECTOR ERASE at addr 0x000000", $time);
        do_op(ERAS, 24'h000000, 9'd0, '0);
        $display("[%0t] ERASE done", $time);

        // ---- Test 2: PROGRAM 4 bytes at address 0 ----
        prog_data[31:0] = pattern;

        $display("[%0t] TEST 2: PAGE PROGRAM 4 bytes at addr 0x000000 (AA BB CC DD)", $time);
        do_op(PROG, 24'h000000, 9'd4, prog_data);
        $display("[%0t] PROGRAM done", $time);

        // ---- Test 3: READ back 4 bytes and check ----
        $display("[%0t] TEST 3: READ 4 bytes from addr 0x000000", $time);
        do_op(READ, 24'h000000, 9'd4, '0);
        $display("[%0t] READ done, rdata[31:0] = 0x%08h", $time, rdata[31:0]);

        if (rdata[31:0] !== pattern) begin
            $display("FAIL: expected 0x%08h, got 0x%08h", pattern, rdata[31:0]);
            errors++;
        end else begin
            $display("PASS: read-back matches programmed data");
        end

        // ---- Test 4: verify ERASE actually reset bytes to 0xFF beyond what we programmed ----
        do_op(READ, 24'h000010, 9'd4, '0); // untouched region within the erased sector
        if (rdata[31:0] !== 32'hFFFFFFFF) begin
            $display("FAIL: expected erased region to read 0xFFFFFFFF, got 0x%08h", rdata[31:0]);
            errors++;
        end else begin
            $display("PASS: untouched erased region reads 0xFFFFFFFF");
        end

        if (errors == 0)
            $display("\n*** ALL TESTS PASSED ***\n");
        else
            $display("\n*** %0d TEST(S) FAILED ***\n", errors);

        $finish;

    end

endmodule
