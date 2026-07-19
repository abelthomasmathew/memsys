// N-way (parametrized). LRU replacement is used.
module cache #(
    parameter int WAYS = 4,         // no of ways
    parameter int LINES = 256,      // no of lines
    parameter int WORDS = 4,        // words per line each of DATAWIDTH size
    parameter int ADDRWIDTH = 32,
    parameter int DATAWIDTH = 32
)(
    input logic clk, areset,
    
    // CPU to Cache
    input logic req_valid,
    input logic pwrite,
    input logic [ADDRWIDTH-1:0] paddr,
    input logic [DATAWIDTH-1:0] pwdata,
    output logic req_ready,

    output logic resp_valid,
    output logic [DATAWIDTH-1:0] prdata,
    output logic hit,                   // hit = 1, miss = 0
    output logic [31:0] hit_count,
    output logic [31:0] miss_count,

    // AXI to mem
    output logic [ADDRWIDTH-1:0] awaddr, output logic [7:0] awlen, output logic [2:0] awsize,
    output logic [1:0] awburst, output logic awvalid,
    input logic awready,

    output logic [DATAWIDTH-1:0] wdata, output logic [3:0] wstrb, output logic wlast, output logic wvalid,
    input logic wready,

    input logic [1:0] bresp, input logic bvalid,
    output logic bready,
    
    output logic [ADDRWIDTH-1:0] araddr, output logic [7:0] arlen, output logic [2:0] arsize,
    output logic [1:0] arburst, output logic arvalid,
    input logic arready,

    input logic [DATAWIDTH-1:0] rdata, input logic [1:0] rresp, input logic rlast, input logic rvalid,
    output logic rready
);
    // AXI internal ports
    logic start, write, busy, done;
    logic [ADDRWIDTH-1:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic cwvalid, cwready;
    logic [DATAWIDTH-1:0] cwdata;
    logic [DATAWIDTH/8-1:0] cwstrb;
    logic crready, crvalid;
    logic [DATAWIDTH-1:0] crdata;
    logic [1:0] resp;

    axi_master #(
        .ADDRWIDTH(ADDRWIDTH), .DATAWIDTH(DATAWIDTH)
    ) mem_axi (
        .clk(clk), .areset(areset),
        .start(start), .write(write), .addr(addr), .len(len), .size(size),
        .cwvalid(cwvalid), .cwdata(cwdata), .strb(cwstrb), .cwready(cwready),
        .crvalid(crvalid), .crdata(crdata), .crready(crready),
        .busy(busy), .done(done), .resp(resp),
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    localparam int SETS = LINES/WAYS;
    localparam int WAYSELECT = $clog2(WAYS);
    localparam int WORDSELECT = $clog2(WORDS);
    localparam int BYTESELECT = $clog2(DATAWIDTH/8);
    localparam int OFFSET = WORDSELECT + BYTESELECT;
    localparam int INDEX = $clog2(SETS);
    localparam int TAG = ADDRWIDTH - (OFFSET + INDEX);

    // storage arrays
    logic [TAG-1:0] tag_mem [0:SETS-1][0:WAYS-1]; 
    // CPU asks for an address, it is split into tag/index/offset, go to that index's set, and compare the incoming tag against all 
    // WAYS stored tags in that set. If one matches (and is valid), that's your hit — and it tells you which way holds the right data.
    logic valid_mem [0:SETS-1][0:WAYS-1]; // is this way meaningful or garbage?
    logic dirty_mem [0:SETS-1][0:WAYS-1]; // has the CPU written to this cache line? is cache's copy newer than main memory?
    logic [WAYSELECT-1:0] lru_mem [0:SETS-1][0:WAYS-1]; // during a miss (if there are no vacant line) we need to evict LRU way. Ranks every line.
    logic [DATAWIDTH-1:0] data_mem [0:SETS-1][0:WAYS-1][0:WORDS-1];

    // Address breakdown
    logic [BYTESELECT-1:0] bytebits;
    logic [WORDSELECT-1:0] offsetbits;
    logic [INDEX-1:0] setbits;
    logic [TAG-1:0] tagbits;
    assign bytebits = paddr[BYTESELECT-1:0];
    assign offsetbits = paddr[BYTESELECT +: WORDSELECT];
    assign setbits = paddr[OFFSET +: INDEX];
    assign tagbits = paddr[OFFSET+INDEX +: TAG];

    task automatic update_lru(input [INDEX-1:0] set, input [WAYSELECT-1:0] used_way);
        logic [WAYSELECT-1:0] old_rank;
        old_rank = lru_mem[set][used_way];
        for (int w=0; w<WAYS; w++) begin
            if (w == used_way) lru_mem[set][w] <= WAYS-1;
            else if (lru_mem[set][w] > old_rank) lru_mem[set][w] <= lru_mem[set][w] - 1'b1;
        end
    endtask

    // latched request
    logic l_write;
    logic [DATAWIDTH-1:0] l_wdata;
    logic [BYTESELECT-1:0] l_byte;
    logic [WORDSELECT-1:0] l_offset;
    logic [INDEX-1:0] l_set;
    logic [TAG-1:0] l_tag;
    logic [WAYSELECT-1:0] l_way; // hit_way or victim_way ???

    typedef enum logic [2:0] {IDLE, LOOKUP, HIT, WB_ISSUE, WB_STREAM, FILL_ISSUE, FILL_STREAM, MISS} state_t;
    state_t state;

    logic [WORDSELECT-1:0] word_count;

    always_ff @(posedge clk or posedge areset) begin
        if (areset) begin
            state <= IDLE;
            resp_valid <= 1'b0;
            hit <= 1'b0;
            hit_count <= 32'b0;
            miss_count <= 32'b0;
            start <= 1'b0;
            word_count <= '0;
            for (int s=0; s<SETS; s++) begin
                for (int w=0; w<WAYS; w++) begin
                    valid_mem[s][w] <= 1'b0;
                    dirty_mem[s][w] <= 1'b0;
                    lru_mem[s][w] <= w; 
                end
            end
        end
        else begin
            resp_valid <= 1'b0;
            start <= 1'b0;
            hit <= 1'b0;
            case (state)
                IDLE : begin
                    if (req_valid) begin
                        l_write <= pwrite;
                        l_wdata <= pwdata;
                        l_byte <= bytebits;
                        l_offset <= offsetbits;
                        l_set <= setbits;
                        l_tag <= tagbits;
                        state <= LOOKUP;
                    end
                end
                LOOKUP : begin
                    if (any_hit) begin          // if the address requested by cpu is already present in cache (same tag)
                        l_way <= hit_way;
                        state <= HIT;
                    end
                    else begin                  // if the tag of the set already in cache is different from the tag requested by cpu
                        l_way <= victim_way;    // find a way in the set that is either invalid on LRU

                        // If the way selected is LRU (it already has a valid data in it that needs to be replaced for read/write)
                        // and the data in cache is newer than the one in main mem, then main mem needs to updated before the way is cleared
                        if (valid_mem[l_set][victim_way] && dirty_mem[l_set][victim_way]) begin
                            state <= WB_ISSUE;
                        end
                        // if the way is empty (invalid) or if it requires no main mem updation (not dirty - main mem upto date)
                        else state <= FILL_ISSUE;
                    end                    
                end
                HIT : begin
                    if (l_write) begin
                        data_mem[l_set][l_way][l_offset] <= l_wdata;
                        dirty_mem[l_set][l_way] <= 1'b1;               // currently cache has new data that is not updated to Main memory 
                    end
                    else prdata <= data_mem[l_set][l_way][l_offset];

                    resp_valid <= 1'b1;
                    hit <= 1'b1;
                    hit_count <= hit_count + 1'b1;
                    update_lru(l_set, l_way);
                    state <= IDLE;
                end
                WB_ISSUE : begin // evict the value in cache to main mem using axi
                    write <= 1'b1;
                    addr <= {tag_mem[l_set][l_way],l_set,{OFFSET{1'b0}}};
                    len <= WORDS - 1;
                    size <= 3'b010;
                    cwstrb <= {DATAWIDTH/8{1'b1}};
                    start <= 1'b1;
                    word_count <= '0;
                    state <= WB_STREAM;
                end
                WB_STREAM : begin
                    if (cwready && cwvalid) word_count <= word_count + 1'b1;
                    if (done) state <= FILL_ISSUE;
                end
                // fetch data of new tag from main mem 
                FILL_ISSUE : begin
                    write <= 1'b0;
                    addr <= {l_tag, l_set, {OFFSET{1'b0}}};
                    len <= WORDS-1;
                    size <= 3'b010; // 4 bytes = 32 bits = 1 word
                    start <= 1'b1;
                    word_count <= '0;
                    state <= FILL_STREAM;
                end
                FILL_STREAM : begin
                    if (crready && crvalid) begin
                        word_count <= word_count + 1'b1;
                        data_mem[l_set][l_way][word_count] <= crdata;
                    end
                    if (done) begin
                        valid_mem[l_set][l_way] <= 1'b1;
                        tag_mem[l_set][l_way] <= l_tag;
                        dirty_mem[l_set][l_way] <= 1'b0;
                        state <= MISS;
                    end
                end
                MISS : begin
                    if (l_write) begin
                        data_mem[l_set][l_way][l_offset] <= l_wdata;
                        dirty_mem[l_set][l_way] <= 1'b1;               // currently cache has new data that is not updated to Main memory 
                    end
                    else prdata <= data_mem[l_set][l_way][l_offset];

                    resp_valid <= 1'b1;
                    hit <= 1'b0;
                    miss_count <= miss_count + 1'b1;
                    update_lru(l_set, l_way);
                    state <= IDLE;
                end
                default : state <= IDLE;
            endcase
        end
    end

    // is there a hit?
    logic [WAYS-1:0] hit_vector; // usually one-hot, for a well formed cache atmost 1 way will match with the incoming tag.
    logic any_hit;
    logic [WAYSELECT-1:0] hit_way;
    always_comb begin
        hit_way = '0;
        for (int w=0; w<WAYS; w++) begin
            hit_vector[w] = (valid_mem[l_set][w] && (tag_mem[l_set][w] == l_tag));
            if (hit_vector[w]) hit_way = w;
        end
        any_hit = | (hit_vector);
    end

    // victim selection : which line/way should be updated next?
    // invalid way has highest priority (has not been written yet) else LRU way
    logic [WAYSELECT-1:0] victim_way;
    logic has_invalid;
    always_comb begin
        victim_way = '0;
        has_invalid = 1'b0;
        for (int w=0; w<WAYS; w++) begin
            if (!valid_mem[l_set][w] && !has_invalid) begin
                victim_way = w;             // first empty way gets chosen
                has_invalid = 1'b1;
            end
        end
        if (!has_invalid) begin // least ranked way becomes the victim
            for (int w=0; w<WAYS; w++) begin
                if (lru_mem[l_set][w] == '0) victim_way = w;
            end
        end
    end

    // stream data to AXI to be stored main mem
    assign cwvalid = (state == WB_STREAM) && (word_count < WORDS);
    assign cwdata = data_mem[l_set][l_way][word_count];
    
    // accept data from main mem from AXI
    assign crready = (state == FILL_STREAM);
    assign req_ready = (state == IDLE);

endmodule
