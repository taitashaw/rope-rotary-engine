// -----------------------------------------------------------------------------
// rope_engine_bp_tb.sv — Backpressure stress testbench for rope_engine.
//
// Drives the same 16 golden vectors as rope_engine_tb, but:
//   * Toggles s_valid with random gaps (input backpressure FROM upstream)
//   * Toggles m_ready randomly (downstream backpressure INTO the engine)
//
// Correctness invariant: the sequence of output beats — each checked bit-for-bit
// against the golden model — must be IDENTICAL to the no-backpressure run,
// regardless of the random stall pattern.
//
// Run (Icarus):
//     iverilog -g2012 -I tb -o sim_rope_bp_tb \
//         rtl/rope_skid_fifo.sv rtl/rope_rotate_pe.sv \
//         rtl/rope_sincos_lut_bank.sv rtl/rope_engine.sv \
//         tb/rope_engine_bp_tb.sv
//     (cd tb/vectors && vvp ../../sim_rope_bp_tb)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

`include "vectors/config.vh"

module rope_engine_bp_tb;
    localparam int DATA_WIDTH      = `CFG_DATA_WIDTH;
    localparam int HEAD_DIM        = `CFG_HEAD_DIM;
    localparam int MAX_SEQ_LEN     = `CFG_MAX_SEQ_LEN;
    localparam int N_TESTS         = `CFG_N_TESTS;
    localparam int POS_WIDTH       = `CFG_POS_WIDTH;
    localparam int PAIRS_PER_CYCLE = 4;
    localparam int N_PAIRS         = HEAD_DIM / 2;
    localparam int BEATS_PER_VEC   = N_PAIRS / PAIRS_PER_CYCLE;

    // ---- Stall profile knobs (tunable per-run) ----
    // P_S_VALID_ACTIVE: probability s_valid is high on any cycle when there's
    //                   still stimulus to drive.
    // P_M_READY_ACTIVE: probability m_ready is high on any cycle.
    // Lower values = more backpressure. Both set to 0.6 for aggressive stalling.
    localparam real P_S_VALID_ACTIVE = 0.6;
    localparam real P_M_READY_ACTIVE = 0.6;
    localparam int  RNG_SEED         = 42;

    // ---- Clock / reset ----
    reg clk = 0;
    always #1.25 clk = ~clk;              // 400 MHz
    reg rst_n = 0;

    // ---- DUT ports ----
    reg                                       s_valid;
    wire                                      s_ready;
    reg  [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]   s_data;
    reg  [POS_WIDTH-1:0]                      s_position;
    reg                                       s_last;

    wire                                      m_valid;
    reg                                       m_ready;
    wire [PAIRS_PER_CYCLE*2*DATA_WIDTH-1:0]   m_data;
    wire                                      m_last;

    rope_engine #(
        .DATA_WIDTH     (DATA_WIDTH),
        .HEAD_DIM       (HEAD_DIM),
        .MAX_SEQ_LEN    (MAX_SEQ_LEN),
        .PAIRS_PER_CYCLE(PAIRS_PER_CYCLE),
        .POS_WIDTH      (POS_WIDTH)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_valid    (s_valid),
        .s_ready    (s_ready),
        .s_data     (s_data),
        .s_position (s_position),
        .s_last     (s_last),
        .m_valid    (m_valid),
        .m_ready    (m_ready),
        .m_data     (m_data),
        .m_last     (m_last)
    );

    // ---- Vector storage ----
    reg [DATA_WIDTH-1:0] stim_mem     [0:N_TESTS*HEAD_DIM-1];
    reg [DATA_WIDTH-1:0] expected_mem [0:N_TESTS*HEAD_DIM-1];
    reg [POS_WIDTH-1:0]  position_mem [0:N_TESTS-1];

    // ---- Scoreboard ----
    integer errors           = 0;
    integer beats_collected  = 0;
    integer tokens_collected = 0;
    integer beats_driven     = 0;
    integer stall_s_cycles   = 0;
    integer stall_m_cycles   = 0;

    // ---- Output monitor: checks each (m_valid && m_ready) beat ----
    always @(posedge clk) begin
        if (m_valid && m_ready) begin
            integer beat_idx_in_vec;
            integer token_idx;
            integer base_elem;
            beat_idx_in_vec = beats_collected % BEATS_PER_VEC;
            token_idx       = beats_collected / BEATS_PER_VEC;
            base_elem       = token_idx * HEAD_DIM
                            + beat_idx_in_vec * PAIRS_PER_CYCLE * 2;

            for (int lane = 0; lane < PAIRS_PER_CYCLE * 2; lane++) begin
                logic signed [DATA_WIDTH-1:0] got;
                logic signed [DATA_WIDTH-1:0] exp;
                got = m_data[lane*DATA_WIDTH +: DATA_WIDTH];
                exp = expected_mem[base_elem + lane];
                if (got !== exp) begin
                    $display("[FAIL] test=%0d lane=%0d got=%0d exp=%0d (h%h vs h%h)",
                             token_idx, lane, got, exp, got, exp);
                    errors = errors + 1;
                end
            end

            beats_collected = beats_collected + 1;
            if (m_last) tokens_collected = tokens_collected + 1;
        end
    end

    // ---- Randomized m_ready toggler ----
    // 16-bit LFSR gives decent Bernoulli trials per cycle without any $urandom
    // seed quirks. Reset to RNG_SEED so runs are reproducible.
    reg [15:0] lfsr_m = 16'hBEEF;
    wire       lfsr_m_bit = lfsr_m[15] ^ lfsr_m[13] ^ lfsr_m[12] ^ lfsr_m[10];
    always_ff @(posedge clk) begin
        if (!rst_n) lfsr_m <= 16'hBEEF;
        else        lfsr_m <= {lfsr_m[14:0], lfsr_m_bit};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            m_ready <= 1'b0;
        end else begin
            // next_ready is high with probability ~P_M_READY_ACTIVE using lfsr
            logic next_ready;
            next_ready = (lfsr_m[7:0] < (P_M_READY_ACTIVE * 256));
            m_ready <= next_ready;
            if (!next_ready && m_valid) stall_m_cycles = stall_m_cycles + 1;
        end
    end

    // Second LFSR for s_valid so the two streams aren't correlated
    reg [15:0] lfsr_s = 16'hCAFE;
    wire       lfsr_s_bit = lfsr_s[15] ^ lfsr_s[13] ^ lfsr_s[12] ^ lfsr_s[10];
    always_ff @(posedge clk) begin
        if (!rst_n) lfsr_s <= 16'hCAFE;
        else        lfsr_s <= {lfsr_s[14:0], lfsr_s_bit};
    end

    // ---- Randomized stimulus driver with s_valid gaps ----
    task automatic drive_all_vectors;
        integer t, b, base_elem, n_total_beats, beat_ptr;
        logic   fire_this_cycle;
        n_total_beats = N_TESTS * BEATS_PER_VEC;
        beat_ptr = 0;

        while (beat_ptr < n_total_beats) begin
            @(posedge clk);
            fire_this_cycle = (lfsr_s[7:0] < (P_S_VALID_ACTIVE * 256));

            if (fire_this_cycle) begin
                t = beat_ptr / BEATS_PER_VEC;
                b = beat_ptr % BEATS_PER_VEC;
                base_elem = t * HEAD_DIM;

                s_valid    <= 1'b1;
                s_position <= position_mem[t];
                s_last     <= (b == BEATS_PER_VEC - 1);
                for (int lane = 0; lane < PAIRS_PER_CYCLE * 2; lane++) begin
                    s_data[lane*DATA_WIDTH +: DATA_WIDTH]
                        <= stim_mem[base_elem + b*PAIRS_PER_CYCLE*2 + lane];
                end

                if (s_ready) begin
                    beats_driven = beats_driven + 1;
                    beat_ptr     = beat_ptr + 1;
                end else begin
                    stall_s_cycles = stall_s_cycles + 1;
                end
            end else begin
                s_valid <= 1'b0;
                s_last  <= 1'b0;
            end
        end
        @(posedge clk);
        s_valid <= 1'b0;
        s_last  <= 1'b0;
    endtask

    // ---- Main ----
    initial begin
        $dumpfile("rope_engine_bp_tb.vcd");
        $dumpvars(0, rope_engine_bp_tb);

        $display("-------------------------------------------------------");
        $display("rope_engine_bp_tb: HEAD_DIM=%0d PAIRS/CYC=%0d TESTS=%0d",
                 HEAD_DIM, PAIRS_PER_CYCLE, N_TESTS);
        $display("Backpressure: P(s_valid)=%.2f  P(m_ready)=%.2f  seed=%0d",
                 P_S_VALID_ACTIVE, P_M_READY_ACTIVE, RNG_SEED);
        $display("-------------------------------------------------------");

        $readmemh("stim.hex",      stim_mem);
        $readmemh("expected.hex",  expected_mem);
        $readmemh("positions.hex", position_mem);

        s_valid = 0; s_last = 0; s_data = '0; s_position = '0;
        m_ready = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        drive_all_vectors();

        // Drain
        repeat (512) @(posedge clk);

        $display("-------------------------------------------------------");
        $display("BEATS_DRIVEN     = %0d / %0d",
                 beats_driven, N_TESTS * BEATS_PER_VEC);
        $display("TOKENS_COLLECTED = %0d / %0d", tokens_collected, N_TESTS);
        $display("STALL_S_CYCLES   = %0d  (upstream wait for s_ready)", stall_s_cycles);
        $display("STALL_M_CYCLES   = %0d  (downstream wait for m_ready)", stall_m_cycles);
        $display("ERRORS           = %0d", errors);
        if (errors == 0 && tokens_collected == N_TESTS)
            $display("RESULT: PASS (%0d/%0d tests, 0 bit-errors, backpressure honored)",
                     N_TESTS, N_TESTS);
        else
            $display("RESULT: FAIL");
        $display("-------------------------------------------------------");

        $finish;
    end

    // Watchdog: under aggressive backpressure, sim may take ~10x longer
    initial begin
        #2000000;
        $display("RESULT: TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
