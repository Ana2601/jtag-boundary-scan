// IEEE 1149.1 TAP controller: the 16-state machine plus the instruction register.
// TMS/TDI are sampled on the rising edge of TCK; the instruction is updated
// on the falling edge in Update-IR, as the standard requires.
module jtag_tap #(
    parameter integer        IR_W        = 4,
    parameter [IR_W-1:0]     IR_RESET    = 4'b0001     // instruction after reset (IDCODE)
) (
    input  wire            tck,
    input  wire            tms,
    input  wire            tdi,
    input  wire            trst_n,

    output reg  [IR_W-1:0] ir,            // current instruction
    output wire            ir_tdo,        // serial output of the IR shift stage
    output wire            sel_ir,        // an IR scan is in progress
    output wire            capture_dr,
    output wire            shift_dr,
    output wire            update_dr,
    output wire            shift_any,     // Shift-DR or Shift-IR: TDO is driven
    output wire            tlr            // Test-Logic-Reset
);
    localparam [3:0] TLR = 4'd0,  RTI = 4'd1,
                     SEL_DR = 4'd2, CAP_DR = 4'd3, SH_DR = 4'd4, EX1_DR = 4'd5,
                     PAU_DR = 4'd6, EX2_DR = 4'd7, UPD_DR = 4'd8,
                     SEL_IR = 4'd9, CAP_IR = 4'd10, SH_IR = 4'd11, EX1_IR = 4'd12,
                     PAU_IR = 4'd13, EX2_IR = 4'd14, UPD_IR = 4'd15;

    reg [3:0]      state;
    reg [IR_W-1:0] ir_shift;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) state <= TLR;
        else case (state)
            TLR:    state <= tms ? TLR    : RTI;
            RTI:    state <= tms ? SEL_DR : RTI;
            SEL_DR: state <= tms ? SEL_IR : CAP_DR;
            CAP_DR: state <= tms ? EX1_DR : SH_DR;
            SH_DR:  state <= tms ? EX1_DR : SH_DR;
            EX1_DR: state <= tms ? UPD_DR : PAU_DR;
            PAU_DR: state <= tms ? EX2_DR : PAU_DR;
            EX2_DR: state <= tms ? UPD_DR : SH_DR;
            UPD_DR: state <= tms ? SEL_DR : RTI;
            SEL_IR: state <= tms ? TLR    : CAP_IR;
            CAP_IR: state <= tms ? EX1_IR : SH_IR;
            SH_IR:  state <= tms ? EX1_IR : SH_IR;
            EX1_IR: state <= tms ? UPD_IR : PAU_IR;
            PAU_IR: state <= tms ? EX2_IR : PAU_IR;
            EX2_IR: state <= tms ? UPD_IR : SH_IR;
            default: state <= tms ? SEL_DR : RTI;     // UPD_IR
        endcase
    end

    // IR shift stage: captures the mandatory ...01 pattern
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) ir_shift <= {IR_W{1'b0}};
        else if (state == CAP_IR) ir_shift <= {{(IR_W-1){1'b0}}, 1'b1};
        else if (state == SH_IR)  ir_shift <= {tdi, ir_shift[IR_W-1:1]};
    end

    always @(negedge tck or negedge trst_n) begin
        if (!trst_n)              ir <= IR_RESET;
        else if (state == TLR)    ir <= IR_RESET;
        else if (state == UPD_IR) ir <= ir_shift;
    end

    assign ir_tdo     = ir_shift[0];
    assign sel_ir     = (state >= SEL_IR);
    assign capture_dr = (state == CAP_DR);
    assign shift_dr   = (state == SH_DR);
    assign update_dr  = (state == UPD_DR);
    assign shift_any  = (state == SH_DR) || (state == SH_IR);
    assign tlr        = (state == TLR);
endmodule
