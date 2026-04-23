`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// rope_engine.sv — Top-level RoPE Rotary Engine.
//
// Streams a Query or Key vector through a bank of PAIRS_PER_CYCLE parallel
// rotation PEs, applying Rotary Position Embedding (Su et al., 2021) per the
// interleaved-pair convention:
//
//     pair i = (x[2i], x[2i+1]),  i in [0, HEAD_DIM/2)
//     x'[2i]   = x[2i] * cos(m*theta_i) - x[2i+1] * sin(m*theta_i)
//     x'[2i+1] = x[2i] * sin(m*theta_i) + x[2i+1] * cos(m*theta_i)
//
// Interface: AXI4-Stream in/out at PAIRS_PER_CYCLE * 2 lanes of DATA_WIDTH bits
// per beat. `position` is latched from the TUSER field on the first beat of a
// vector (the beat with `pair_first` set internally).
//
// Pipeline: fixed 5-cycle PE latency. Input and output both have 32-deep
// elastic FIFOs (rope_skid_fifo) implementing full AXI4-Stream backpressure:
//   * `s_ready` deasserts when the input FIFO is full.
//   * `m_valid` stays high as long as the output FIFO is non-empty.
//   * Core is throttled by output-FIFO free-space so no data is ever dropped.
// Peak throughput is 1 beat/cycle when both sides are unblocked.
//
// Target: Zynq UltraScale+ (xczu7ev). Conservative timing target 400 MHz.
// -----------------------------------------------------------------------------
`default_nettype none

module rope_engine #(
    parameter int DATA_WIDTH       = 16,     // Q1.15 signed
    parameter int HEAD_DIM         = 128,    // head dimension (must be even)
    parameter int MAX_SEQ_LEN      = 2048,   // max supported position
    parameter int PAIRS_PER_CYCLE  = 4,      // parallel rotation PEs
    parameter int POS_WIDTH        = 16      // bits of position index
) (
    input  wire                                          clk,
    input  wire                                          rst_n,

    // AXI4-Stream slave (input tokens)
    input  wire                                          s_valid,
    output wire                                          s_ready,
    input  wire [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]       s_data,
    input  wire [POS_WIDTH-1:0]                          s_position, // latched on pair_first
    input  wire                                          s_last,     // high on final beat of vector

    // AXI4-Stream master (rotated tokens)
    output wire                                          m_valid,
    input  wire                                          m_ready,
    output wire [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]       m_data,
    output wire                                          m_last
);

    // ---- Derived parameters ----------------------------------------------------
    localparam int N_PAIRS       = HEAD_DIM / 2;
    localparam int BEATS_PER_VEC = N_PAIRS / PAIRS_PER_CYCLE;
    localparam int LOCAL_PAIRS   = N_PAIRS / PAIRS_PER_CYCLE;   // entries per bank per position
    localparam int LUT_ADDR_W    = $clog2(MAX_SEQ_LEN * LOCAL_PAIRS);
    localparam int BEAT_CNT_W    = $clog2(BEATS_PER_VEC + 1);

    // Synthesis-time sanity
    initial begin
        if (HEAD_DIM % 2 != 0)
            $fatal(1, "HEAD_DIM must be even");
        if (N_PAIRS % PAIRS_PER_CYCLE != 0)
            $fatal(1, "N_PAIRS must be divisible by PAIRS_PER_CYCLE");
    end

    // ---- Input elastic FIFO (absorbs upstream bursts / stalls) -----------------
    // External AXI-Stream slave handshakes with this FIFO. The core datapath
    // reads from the FIFO via sp_* signals and is unconditionally ready when
    // the PE bank isn't stalled (which, internally, it never is).
    localparam int IN_FIFO_WIDTH = (PAIRS_PER_CYCLE*2*DATA_WIDTH) + POS_WIDTH + 1;
    localparam int IN_FIFO_DEPTH = 32;

    wire                                      sp_valid;
    wire                                      sp_ready;
    wire [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]   sp_data;
    wire [POS_WIDTH-1:0]                      sp_position;
    wire                                      sp_last;

    wire [IN_FIFO_WIDTH-1:0] in_fifo_din  = {s_last, s_position, s_data};
    wire [IN_FIFO_WIDTH-1:0] in_fifo_dout;

    rope_skid_fifo #(
        .WIDTH(IN_FIFO_WIDTH),
        .DEPTH(IN_FIFO_DEPTH)
    ) u_in_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_valid (s_valid),
        .i_ready (s_ready),
        .i_data  (in_fifo_din),
        .o_valid (sp_valid),
        .o_ready (sp_ready),
        .o_data  (in_fifo_dout),
        .full    (),
        .empty   ()
    );

    assign sp_data     = in_fifo_dout[PAIRS_PER_CYCLE*2*DATA_WIDTH-1 : 0];
    assign sp_position = in_fifo_dout[IN_FIFO_WIDTH-2 -: POS_WIDTH];
    assign sp_last     = in_fifo_dout[IN_FIFO_WIDTH-1];

    // ---- Input-side beat counter (tracks pair index within a vector) ----------
    reg [BEAT_CNT_W-1:0]  beat_cnt;
    reg [POS_WIDTH-1:0]   cur_position;
    wire                  pair_first = (beat_cnt == '0);

    // The core pipeline is always ready to consume from the input FIFO, provided
    // the downstream output FIFO has room (checked below via `out_fifo_ready`).
    wire out_fifo_ready;
    assign sp_ready = out_fifo_ready;

    wire s_fire = sp_valid & sp_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beat_cnt     <= '0;
            cur_position <= '0;
        end else if (s_fire) begin
            if (pair_first)
                cur_position <= sp_position;
            if (beat_cnt == BEATS_PER_VEC - 1 || sp_last)
                beat_cnt <= '0;
            else
                beat_cnt <= beat_cnt + 1'b1;
        end
    end

    // ---- Effective position for the CURRENT beat ------------------------------
    // On the first beat of a vector, `cur_position` still holds the *previous*
    // vector's value (it updates on the clock edge at end of this beat). So we
    // must bypass to `sp_position` combinationally on pair_first.
    wire [POS_WIDTH-1:0] eff_position =
        (s_fire && pair_first) ? sp_position : cur_position;

    // ---- LUT address issue (eff_position * N_PAIRS + pair_base) ---------------
    // We issue PAIRS_PER_CYCLE consecutive addresses by giving each PE its own
    // tiny LUT instance sliced by pair offset. Simplest: one LUT per PE.
    wire signed [DATA_WIDTH-1:0] cos_arr [0:PAIRS_PER_CYCLE-1];
    wire signed [DATA_WIDTH-1:0] sin_arr [0:PAIRS_PER_CYCLE-1];

    genvar g;
    generate
        for (g = 0; g < PAIRS_PER_CYCLE; g++) begin : g_lut
            // Bank g holds entries only for pair indices {g, g+PPC, g+2*PPC, ...}
            // so the per-PE address is local:
            //     addr = eff_position * LOCAL_PAIRS + beat_cnt
            wire [LUT_ADDR_W-1:0] lut_addr =
                (eff_position * LOCAL_PAIRS) + beat_cnt;

            // Bank-specific hex file names (Vivado requires parameter-string
            // $readmemh paths, not runtime-composed). The hex files are emitted
            // by python/rope_golden.py --gen-vectors and must sit in the
            // simulator/synthesis runtime cwd.
            if (g == 0) begin : b0
                rope_sincos_lut_bank #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .MAX_SEQ_LEN(MAX_SEQ_LEN),
                    .LOCAL_PAIRS(LOCAL_PAIRS),
                    .ADDR_WIDTH (LUT_ADDR_W),
                    .COS_PATH   ("cos_lut_bank0.hex"),
                    .SIN_PATH   ("sin_lut_bank0.hex")
                ) u_lut (.clk(clk), .rd_en(s_fire), .rd_addr(lut_addr),
                         .cos_out(cos_arr[g]), .sin_out(sin_arr[g]));
            end
            else if (g == 1) begin : b1
                rope_sincos_lut_bank #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .MAX_SEQ_LEN(MAX_SEQ_LEN),
                    .LOCAL_PAIRS(LOCAL_PAIRS),
                    .ADDR_WIDTH (LUT_ADDR_W),
                    .COS_PATH   ("cos_lut_bank1.hex"),
                    .SIN_PATH   ("sin_lut_bank1.hex")
                ) u_lut (.clk(clk), .rd_en(s_fire), .rd_addr(lut_addr),
                         .cos_out(cos_arr[g]), .sin_out(sin_arr[g]));
            end
            else if (g == 2) begin : b2
                rope_sincos_lut_bank #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .MAX_SEQ_LEN(MAX_SEQ_LEN),
                    .LOCAL_PAIRS(LOCAL_PAIRS),
                    .ADDR_WIDTH (LUT_ADDR_W),
                    .COS_PATH   ("cos_lut_bank2.hex"),
                    .SIN_PATH   ("sin_lut_bank2.hex")
                ) u_lut (.clk(clk), .rd_en(s_fire), .rd_addr(lut_addr),
                         .cos_out(cos_arr[g]), .sin_out(sin_arr[g]));
            end
            else begin : b3
                rope_sincos_lut_bank #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .MAX_SEQ_LEN(MAX_SEQ_LEN),
                    .LOCAL_PAIRS(LOCAL_PAIRS),
                    .ADDR_WIDTH (LUT_ADDR_W),
                    .COS_PATH   ("cos_lut_bank3.hex"),
                    .SIN_PATH   ("sin_lut_bank3.hex")
                ) u_lut (.clk(clk), .rd_en(s_fire), .rd_addr(lut_addr),
                         .cos_out(cos_arr[g]), .sin_out(sin_arr[g]));
            end
        end
    endgenerate

    // ---- Pipeline delay registers to align LUT output with PE input -----------
    // s_data arrives at T0; LUT read latency = 1 cycle (registered output).
    // We delay s_data and valid by 1 cycle so they align with cos/sin at PE input.
    reg                                             s1_valid;
    reg [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]          s1_data;
    reg                                             s1_last;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_last  <= 1'b0;
        end else begin
            s1_valid <= s_fire;
            s1_data  <= sp_data;
            s1_last  <= sp_last & s_fire;
        end
    end

    // ---- Rotation PE bank ------------------------------------------------------
    wire                                             pe_valid_out [0:PAIRS_PER_CYCLE-1];
    wire signed [DATA_WIDTH-1:0]                     pe_even_out  [0:PAIRS_PER_CYCLE-1];
    wire signed [DATA_WIDTH-1:0]                     pe_odd_out   [0:PAIRS_PER_CYCLE-1];

    generate
        for (g = 0; g < PAIRS_PER_CYCLE; g++) begin : g_pe
            wire signed [DATA_WIDTH-1:0] xe =
                s1_data[(2*g)  *DATA_WIDTH +: DATA_WIDTH];
            wire signed [DATA_WIDTH-1:0] xo =
                s1_data[(2*g+1)*DATA_WIDTH +: DATA_WIDTH];

            rope_rotate_pe #(.DATA_WIDTH(DATA_WIDTH)) u_pe (
                .clk        (clk),
                .rst_n      (rst_n),
                .valid_in   (s1_valid),
                .x_even_in  (xe),
                .x_odd_in   (xo),
                .cos_in     (cos_arr[g]),
                .sin_in     (sin_arr[g]),
                .valid_out  (pe_valid_out[g]),
                .x_even_out (pe_even_out[g]),
                .x_odd_out  (pe_odd_out[g])
            );
        end
    endgenerate

    // ---- Output packing --------------------------------------------------------
    // PE is 4-stage: 1 input + 1 mul + 1 add + 1 out reg = 4 cycles after s1.
    // `s1_last` must be delayed by 4 cycles to align with PE output.
    localparam int PE_LATENCY = 4;
    reg [PE_LATENCY-1:0] last_shift;
    always_ff @(posedge clk) begin
        if (!rst_n) last_shift <= '0;
        else        last_shift <= {last_shift[PE_LATENCY-2:0], s1_last};
    end

    wire [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0] m_data_packed;
    generate
        for (g = 0; g < PAIRS_PER_CYCLE; g++) begin : g_pack
            assign m_data_packed[(2*g)  *DATA_WIDTH +: DATA_WIDTH] = pe_even_out[g];
            assign m_data_packed[(2*g+1)*DATA_WIDTH +: DATA_WIDTH] = pe_odd_out[g];
        end
    endgenerate

    // ---- Output elastic FIFO + credit-based throttle --------------------------
    // The PE bank is fully pipelined; once a beat enters at s1_valid, it WILL
    // appear at pe_valid_out exactly PE_LATENCY cycles later — it cannot stall.
    // So before accepting a new input beat, we must be sure the output FIFO
    // has reserved space for that beat PE_LATENCY cycles from now.
    //
    // Track `fifo_free` = free slots in the output FIFO.
    // Track `in_flight` = beats currently traversing the PE pipeline.
    // Accept input iff fifo_free > in_flight (strict inequality: the new beat
    // itself will be in-flight after we accept it).
    localparam int OUT_FIFO_WIDTH = (PAIRS_PER_CYCLE*2*DATA_WIDTH) + 1;
    localparam int OUT_FIFO_DEPTH = 32;
    localparam int FREE_W         = $clog2(OUT_FIFO_DEPTH + 1);
    localparam int IF_W           = $clog2(PE_LATENCY + 2);

    reg [FREE_W-1:0] fifo_free;
    reg [IF_W-1:0]   in_flight;

    wire             out_fifo_i_valid;
    wire             out_fifo_i_ready;
    wire [OUT_FIFO_WIDTH-1:0] out_fifo_din;
    wire [OUT_FIFO_WIDTH-1:0] out_fifo_dout;
    wire             out_fifo_o_valid;
    wire             pop_fire  = out_fifo_o_valid & m_ready;
    wire             push_fire = out_fifo_i_valid & out_fifo_i_ready;

    // Accept-input condition: enough FIFO space for this beat + all in-flight.
    assign out_fifo_ready = (fifo_free > {{(FREE_W-IF_W){1'b0}}, in_flight});

    // Maintain `fifo_free` = OUT_FIFO_DEPTH - outstanding count.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_free <= OUT_FIFO_DEPTH[FREE_W-1:0];
        end else begin
            case ({push_fire, pop_fire})
                2'b10:   fifo_free <= fifo_free - 1'b1;  // pushed, not popped
                2'b01:   fifo_free <= fifo_free + 1'b1;  // popped, not pushed
                default: fifo_free <= fifo_free;         // 00 or 11
            endcase
        end
    end

    // Maintain `in_flight` = beats currently inside the PE pipeline.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            in_flight <= '0;
        end else begin
            case ({s_fire, push_fire})
                2'b10:   in_flight <= in_flight + 1'b1;
                2'b01:   in_flight <= in_flight - 1'b1;
                default: in_flight <= in_flight;
            endcase
        end
    end

    assign out_fifo_i_valid = pe_valid_out[0];
    assign out_fifo_din     = {last_shift[PE_LATENCY-1], m_data_packed};

    rope_skid_fifo #(
        .WIDTH(OUT_FIFO_WIDTH),
        .DEPTH(OUT_FIFO_DEPTH)
    ) u_out_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_valid (out_fifo_i_valid),
        .i_ready (out_fifo_i_ready),
        .i_data  (out_fifo_din),
        .o_valid (out_fifo_o_valid),
        .o_ready (m_ready),
        .o_data  (out_fifo_dout),
        .full    (),
        .empty   ()
    );

    assign m_valid = out_fifo_o_valid;
    assign m_data  = out_fifo_dout[PAIRS_PER_CYCLE*2*DATA_WIDTH-1 : 0];
    assign m_last  = out_fifo_dout[OUT_FIFO_WIDTH-1];

endmodule

`default_nettype wire
