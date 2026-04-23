`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// rope_rotate_pe.sv — Single-pair rotation PE for the RoPE Rotary Engine.
//
// Applies one 2x2 rotation matrix to an (x_even, x_odd) pair:
//
//     [ x_even' ]   [ cos  -sin ] [ x_even ]
//     [ x_odd'  ] = [ sin   cos ] [ x_odd  ]
//
// Datapath (Q1.15 signed):
//     Stage 1 : latch inputs
//     Stage 2 : four signed multiplies (2 DSPs/pair reused across 2 cycles or
//               4 DSPs/pair in parallel — we instantiate 4 so the pipeline is
//               truly 1 pair/cycle)
//     Stage 3 : subtract / add in 32-bit signed accumulator
//     Stage 4 : arithmetic right-shift by 15, saturate to 16-bit signed
//
// Inputs are Q1.15; outputs are Q1.15 with saturation. The product p = a*b is
// Q2.30 in a 32-bit signed register; (p_even - p_odd) remains representable in
// 32-bit signed. The final `>>> 15` brings the result back to Q1.15.
//
// Bit-accurate against python/rope_golden.py::rotate_pair.
// -----------------------------------------------------------------------------
`default_nettype none

module rope_rotate_pe #(
    parameter int DATA_WIDTH = 16      // Q1.15 signed
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         valid_in,
    input  wire signed [DATA_WIDTH-1:0] x_even_in,
    input  wire signed [DATA_WIDTH-1:0] x_odd_in,
    input  wire signed [DATA_WIDTH-1:0] cos_in,
    input  wire signed [DATA_WIDTH-1:0] sin_in,
    output reg                          valid_out,
    output reg  signed [DATA_WIDTH-1:0] x_even_out,
    output reg  signed [DATA_WIDTH-1:0] x_odd_out
);

    localparam int PROD_W = 2 * DATA_WIDTH;   // 32 bits for Q1.15 x Q1.15
    localparam int ACC_W  = PROD_W + 1;       // 33 bits headroom after sum/diff

    // ---------------- Stage 1: register inputs ----------------
    reg                         s1_valid;
    reg signed [DATA_WIDTH-1:0] s1_xe, s1_xo, s1_cos, s1_sin;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid <= valid_in;
            s1_xe    <= x_even_in;
            s1_xo    <= x_odd_in;
            s1_cos   <= cos_in;
            s1_sin   <= sin_in;
        end
    end

    // ---------------- Stage 2: four parallel multiplies ----------------
    // Inference of DSP48E2 (UltraScale+): signed * signed, registered.
    reg                    s2_valid;
    reg signed [PROD_W-1:0] s2_p_ec, s2_p_os, s2_p_es, s2_p_oc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else begin
            s2_valid <= s1_valid;
            s2_p_ec  <= s1_xe * s1_cos;   // x_even * cos
            s2_p_os  <= s1_xo * s1_sin;   // x_odd  * sin
            s2_p_es  <= s1_xe * s1_sin;   // x_even * sin
            s2_p_oc  <= s1_xo * s1_cos;   // x_odd  * cos
        end
    end

    // ---------------- Stage 3: add / subtract ----------------
    reg                   s3_valid;
    reg signed [ACC_W-1:0] s3_even_acc, s3_odd_acc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid    <= s2_valid;
            s3_even_acc <= $signed({s2_p_ec[PROD_W-1], s2_p_ec})
                         - $signed({s2_p_os[PROD_W-1], s2_p_os});
            s3_odd_acc  <= $signed({s2_p_es[PROD_W-1], s2_p_es})
                         + $signed({s2_p_oc[PROD_W-1], s2_p_oc});
        end
    end

    // ---------------- Stage 4: arithmetic shift + saturate ----------------
    // Shift the Q2.30-ish accumulator by 15 bits -> Q1.15 in a wider signed
    // value; then saturate to 16-bit signed.
    wire signed [ACC_W-1-15:0] s3_even_shift = s3_even_acc >>> 15;
    wire signed [ACC_W-1-15:0] s3_odd_shift  = s3_odd_acc  >>> 15;

    function automatic signed [DATA_WIDTH-1:0] sat16(input signed [ACC_W-1-15:0] v);
        localparam signed [DATA_WIDTH-1:0] POS_MAX = {1'b0, {(DATA_WIDTH-1){1'b1}}};
        localparam signed [DATA_WIDTH-1:0] NEG_MIN = {1'b1, {(DATA_WIDTH-1){1'b0}}};
        if      (v >  $signed(POS_MAX)) sat16 = POS_MAX;
        else if (v <  $signed(NEG_MIN)) sat16 = NEG_MIN;
        else                            sat16 = v[DATA_WIDTH-1:0];
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_out  <= 1'b0;
        end else begin
            valid_out  <= s3_valid;
            x_even_out <= sat16(s3_even_shift);
            x_odd_out  <= sat16(s3_odd_shift);
        end
    end

endmodule

`default_nettype wire
