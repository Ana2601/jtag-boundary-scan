// JTAG boundary-scan wrapper (IEEE 1149.1) for a core with N_IN input pins and
// N_OUT output pins.
//
// Instructions (4-bit IR)
//   0000 EXTEST          boundary register drives the output pins, captures the input pins
//   0001 IDCODE          32-bit device identification register (selected after reset)
//   0010 SAMPLE/PRELOAD  snapshot pins without disturbing the core; preload the update latches
//   0011 INTEST          boundary register drives the core inputs, captures the core outputs
//   0100 CLAMP           outputs held from the update latches, bypass register in the chain
//   1000 USER            a USER_W-bit data register for debug/config access to the core
//   others BYPASS        (1111 is the mandatory encoding)
//
// Boundary register order, TDI -> TDO:  out[N_OUT-1] .. out[0], in[N_IN-1] .. in[0]
module jtag_bscan #(
    parameter integer N_IN   = 8,
    parameter integer N_OUT  = 8,
    parameter integer USER_W = 16,
    parameter [31:0]  IDCODE = 32'h1A2B_C0DF      // bit 0 must be 1
) (
    input  wire              tck,
    input  wire              tms,
    input  wire              tdi,
    input  wire              trst_n,
    output reg               tdo,
    output reg               tdo_en,

    // pad side
    input  wire [N_IN-1:0]   pad_in,
    output wire [N_OUT-1:0]  pad_out,
    // core side
    output wire [N_IN-1:0]   core_in,
    input  wire [N_OUT-1:0]  core_out,

    // USER data register
    input  wire [USER_W-1:0] user_capture,     // sampled in Capture-DR
    output reg  [USER_W-1:0] user_update,      // written in Update-DR
    output reg               user_update_stb   // toggles on every USER update
);
    localparam integer N = N_IN + N_OUT;
    localparam [3:0] I_EXTEST = 4'b0000, I_IDCODE = 4'b0001, I_SAMPLE = 4'b0010,
                     I_INTEST = 4'b0011, I_CLAMP  = 4'b0100, I_USER   = 4'b1000;

    wire [3:0] ir;
    wire ir_tdo, sel_ir, capture_dr, shift_dr, update_dr, shift_any, tlr;

    jtag_tap #(.IR_W(4), .IR_RESET(I_IDCODE)) u_tap (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(trst_n),
        .ir(ir), .ir_tdo(ir_tdo), .sel_ir(sel_ir),
        .capture_dr(capture_dr), .shift_dr(shift_dr), .update_dr(update_dr),
        .shift_any(shift_any), .tlr(tlr)
    );

    wire sel_bsr    = (ir == I_EXTEST) || (ir == I_SAMPLE) || (ir == I_INTEST);
    wire sel_id     = (ir == I_IDCODE);
    wire sel_user   = (ir == I_USER);
    wire sel_bypass = !sel_bsr && !sel_id && !sel_user;

    reg [N-1:0]      bsr, bsr_upd;
    reg [31:0]       id_sr;
    reg [USER_W-1:0] user_sr;
    reg              bypass;

    // capture / shift on the rising edge
    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            bsr <= {N{1'b0}}; id_sr <= IDCODE; user_sr <= {USER_W{1'b0}}; bypass <= 1'b0;
        end else if (capture_dr) begin
            if (sel_bsr)    bsr     <= {core_out, pad_in};
            if (sel_id)     id_sr   <= IDCODE;
            if (sel_user)   user_sr <= user_capture;
            if (sel_bypass) bypass  <= 1'b0;
        end else if (shift_dr) begin
            if (sel_bsr)    bsr     <= {tdi, bsr[N-1:1]};
            if (sel_id)     id_sr   <= {tdi, id_sr[31:1]};
            if (sel_user)   user_sr <= {tdi, user_sr[USER_W-1:1]};
            if (sel_bypass) bypass  <= tdi;
        end
    end

    // update latches and TDO change on the falling edge
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) begin
            bsr_upd <= {N{1'b0}}; user_update <= {USER_W{1'b0}}; user_update_stb <= 1'b0;
            tdo <= 1'b0; tdo_en <= 1'b0;
        end else begin
            if (update_dr && sel_bsr) bsr_upd <= bsr;
            if (update_dr && sel_user) begin
                user_update     <= user_sr;
                user_update_stb <= ~user_update_stb;
            end
            tdo_en <= shift_any;
            tdo    <= sel_ir   ? ir_tdo  :
                      sel_bsr  ? bsr[0]  :
                      sel_id   ? id_sr[0] :
                      sel_user ? user_sr[0] : bypass;
        end
    end

    // pin multiplexers (BC_1-style cells)
    wire drive_pads = (ir == I_EXTEST) || (ir == I_CLAMP);
    assign pad_out = (drive_pads && !tlr)        ? bsr_upd[N-1:N_IN] : core_out;
    assign core_in = ((ir == I_INTEST) && !tlr)  ? bsr_upd[N_IN-1:0] : pad_in;
endmodule
