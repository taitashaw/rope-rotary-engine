// -----------------------------------------------------------------------------
// rope_engine_axis.v — Thin AXI4-Stream wrapper around rope_engine.
//
// Deliberately written in pure Verilog-2001 (not SystemVerilog) so that it
// can serve as the top file of a Vivado block-design module reference
// (create_bd_cell -type module -reference). Vivado rejects SystemVerilog
// as the top of a module reference (filemgmt 56-195) but accepts the .v
// extension with a type tag of `Verilog`. The underlying rope_engine and
// its submodules remain SystemVerilog — that's fine because Vivado's synth
// engine handles mixed-language hierarchies once the *top* of the reference
// is Verilog.
//
// Port mapping:
//   s_axis_tuser[15:0]  -> rope_engine.s_position  (RoPE position index)
//   s_axis_tdata[127:0] -> rope_engine.s_data      (4 lanes * 2 * 16b)
//   s_axis_tlast        -> rope_engine.s_last
//   s_axis_tvalid/ready <-> rope_engine.s_valid/ready
//   m_axis_* mirror-maps back to rope_engine.m_*
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module rope_engine_axis #(
    parameter DATA_WIDTH       = 16,
    parameter HEAD_DIM         = 128,
    parameter MAX_SEQ_LEN      = 2048,
    parameter PAIRS_PER_CYCLE  = 4,
    parameter POS_WIDTH        = 16,
    parameter TDATA_WIDTH      = 128,  // PAIRS_PER_CYCLE * 2 * DATA_WIDTH = 4*2*16
    parameter TUSER_WIDTH      = 16    // = POS_WIDTH
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // AXI4-Stream slave
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    input  wire [TDATA_WIDTH-1:0]      s_axis_tdata,
    input  wire [TUSER_WIDTH-1:0]      s_axis_tuser,
    input  wire                        s_axis_tlast,

    // AXI4-Stream master
    output wire                        m_axis_tvalid,
    input  wire                        m_axis_tready,
    output wire [TDATA_WIDTH-1:0]      m_axis_tdata,
    output wire                        m_axis_tlast
);

    rope_engine #(
        .DATA_WIDTH     (DATA_WIDTH),
        .HEAD_DIM       (HEAD_DIM),
        .MAX_SEQ_LEN    (MAX_SEQ_LEN),
        .PAIRS_PER_CYCLE(PAIRS_PER_CYCLE),
        .POS_WIDTH      (POS_WIDTH)
    ) u_engine (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_valid    (s_axis_tvalid),
        .s_ready    (s_axis_tready),
        .s_data     (s_axis_tdata),
        .s_position (s_axis_tuser),
        .s_last     (s_axis_tlast),
        .m_valid    (m_axis_tvalid),
        .m_ready    (m_axis_tready),
        .m_data     (m_axis_tdata),
        .m_last     (m_axis_tlast)
    );

endmodule
