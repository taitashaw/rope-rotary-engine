`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// rope_sincos_lut_bank.sv — Banked pre-computed cos/sin lookup for RoPE.
//
// One instance per rotation PE. Bank `g` stores cos/sin for pair indices
// {g, g+PPC, g+2*PPC, ...} across all supported positions. This cuts per-PE
// BRAM footprint by PAIRS_PER_CYCLE compared to a full-depth LUT.
//
// Layout (matches python/rope_golden.py::gen_vectors banked output):
//     addr = position * LOCAL_PAIRS + local_pair_idx
//     where LOCAL_PAIRS = (HEAD_DIM / 2) / PAIRS_PER_CYCLE
//
// Hex-file naming: cos_lut_bank{g}.hex / sin_lut_bank{g}.hex (see BANK_ID).
// -----------------------------------------------------------------------------
`default_nettype none

module rope_sincos_lut_bank #(
    parameter int DATA_WIDTH  = 16,
    parameter int MAX_SEQ_LEN = 2048,
    parameter int LOCAL_PAIRS = 16,                    // N_PAIRS / PAIRS_PER_CYCLE
    parameter int ADDR_WIDTH  = $clog2(MAX_SEQ_LEN * LOCAL_PAIRS),
    parameter     COS_PATH    = "cos_lut_bank0.hex",
    parameter     SIN_PATH    = "sin_lut_bank0.hex"
) (
    input  wire                          clk,
    input  wire                          rd_en,
    input  wire [ADDR_WIDTH-1:0]         rd_addr,
    output reg  signed [DATA_WIDTH-1:0]  cos_out,
    output reg  signed [DATA_WIDTH-1:0]  sin_out
);

    localparam int DEPTH = MAX_SEQ_LEN * LOCAL_PAIRS;

    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] cos_mem [0:DEPTH-1];
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] sin_mem [0:DEPTH-1];

    // Vivado synthesis requires the $readmemh path to be a literal or parameter
    // string at elaboration — so we pass the filename in from the parent
    // instead of composing it with $sformatf.
    initial begin
        $readmemh(COS_PATH, cos_mem);
        $readmemh(SIN_PATH, sin_mem);
    end

    always_ff @(posedge clk) begin
        if (rd_en) begin
            cos_out <= cos_mem[rd_addr];
            sin_out <= sin_mem[rd_addr];
        end
    end

endmodule

`default_nettype wire
