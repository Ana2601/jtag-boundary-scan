`timescale 1ns/1ps
// Two boundary-scan devices on one JTAG chain, wired output->input on a "board":
//
//     TDI -> [U1] -> [U2] -> TDO        U1.pad_out[i] ---- net[i] ---- U2.pad_in[i]
//
// Part 1 exercises each instruction; part 2 runs a board-level interconnect
// test (walking ones/zeros through EXTEST) against injected opens, stuck nets
// and shorts, and checks that each defect is detected and located.
module tb_jtag;
    localparam integer NI = 8, NO = 8, UW = 16, N = NI + NO;
    localparam [31:0] ID1 = 32'h1A2B_C0DF, ID2 = 32'h2F00_D15B;

    reg tck = 0, tms = 1, tdi = 0, trst_n = 0;
    wire tdo1, tdo2, en1, en2;

    reg  [NI-1:0] u1_pad_in = 8'h00;
    wire [NO-1:0] u1_pad_out, u2_pad_out;
    wire [NI-1:0] u1_core_in, u2_core_in;
    reg  [NO-1:0] u1_core_out = 8'h00, u2_core_out = 8'h00;
    reg  [UW-1:0] u1_user_cap = 16'hBEEF;
    wire [UW-1:0] u1_user_upd;
    wire          u1_user_stb;

    // ---- board wiring with injectable defects
    integer f_kind = 0, f_a = 0, f_b = 0;      // 0 none, 1 open, 2 stuck-0, 3 stuck-1, 4 short (wired-AND)
    reg [NI-1:0] net;
    integer q;
    always @* begin
        net = u1_pad_out;
        if (f_kind == 1) net[f_a] = 1'b1;                       // open input floats high (pull-up)
        if (f_kind == 2) net[f_a] = 1'b0;
        if (f_kind == 3) net[f_a] = 1'b1;
        if (f_kind == 4) begin
            net[f_a] = u1_pad_out[f_a] & u1_pad_out[f_b];
            net[f_b] = u1_pad_out[f_a] & u1_pad_out[f_b];
        end
    end

    jtag_bscan #(.N_IN(NI), .N_OUT(NO), .USER_W(UW), .IDCODE(ID1)) u1 (
        .tck(tck), .tms(tms), .tdi(tdi), .trst_n(trst_n), .tdo(tdo1), .tdo_en(en1),
        .pad_in(u1_pad_in), .pad_out(u1_pad_out), .core_in(u1_core_in), .core_out(u1_core_out),
        .user_capture(u1_user_cap), .user_update(u1_user_upd), .user_update_stb(u1_user_stb));
    jtag_bscan #(.N_IN(NI), .N_OUT(NO), .USER_W(UW), .IDCODE(ID2)) u2 (
        .tck(tck), .tms(tms), .tdi(tdo1), .trst_n(trst_n), .tdo(tdo2), .tdo_en(en2),
        .pad_in(net), .pad_out(u2_pad_out), .core_in(u2_core_in), .core_out(u2_core_out),
        .user_capture(16'h0), .user_update(), .user_update_stb());

    integer errors = 0, checks = 0;
    task automatic check(input string what, input [127:0] got, input [127:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %s: got %h expected %h", what, got, exp);
            end
        end
    endtask

    // ---- JTAG driver: TMS/TDI change on the falling edge, TDO is sampled on the rising edge
    task automatic tick(input t_tms, input t_tdi, output t_tdo);
        begin
            tms = t_tms; tdi = t_tdi;
            #10 t_tdo = tdo2; tck = 1;
            #10 tck = 0;
        end
    endtask

    reg dummy;
    task automatic tap_reset;
        begin repeat (6) tick(1, 0, dummy); tick(0, 0, dummy); end       // -> Run-Test/Idle
    endtask

    // shift `n` bits through IR (ir=1) or DR (ir=0), LSB first; returns the bits shifted out
    task automatic scan(input ir, input integer n, input [127:0] din, output [127:0] dout);
        integer i;
        reg b;
        begin
            dout = 128'd0;
            tick(1, 0, dummy);                       // Select-DR
            if (ir) tick(1, 0, dummy);               // Select-IR
            tick(0, 0, dummy);                       // Capture
            tick(0, 0, dummy);                       // -> Shift
            for (i = 0; i < n; i = i + 1) begin
                tick(i == n - 1, din[i], b);         // last bit leaves through Exit1
                dout[i] = b;
            end
            tick(1, 0, dummy);                       // Update
            tick(0, 0, dummy);                       // Run-Test/Idle
        end
    endtask

    // chain order: bits leave U2 first, so U2 occupies the LOW bits of every scan
    task automatic load_ir(input [3:0] ir1, input [3:0] ir2, output [7:0] cap);
        reg [127:0] o;
        begin scan(1, 8, {120'd0, ir1, ir2}, o); cap = o[7:0]; end
    endtask

    localparam [3:0] EXTEST = 4'h0, IDCODE = 4'h1, SAMPLE = 4'h2, INTEST = 4'h3, CLAMP = 4'h4,
                     USER = 4'h8, BYPASS = 4'hF;

    reg [127:0] o;
    reg [7:0]   cap;
    reg [N-1:0] b1, b2;
    integer i, k, a, b, detected, located, n_faults;
    reg [NI-1:0] seen, pat, bad_mask;

    // Interconnect test: drive walking-1 then walking-0 from U1, capture at U2.
    task automatic interconnect_test(output [NI-1:0] bad);
        integer p;
        reg [NO-1:0] drv;
        begin
            bad = {NI{1'b0}};
            for (p = 0; p < 2 * NO; p = p + 1) begin
                drv = (p < NO) ? (8'd1 << p) : ~(8'd1 << (p - NO));
                load_ir(SAMPLE, BYPASS, cap);                       // PRELOAD U1's update latches
                scan(0, N + 1, {111'd0, drv, {NI{1'b0}}, 1'b0}, o);
                load_ir(EXTEST, EXTEST, cap);                        // drive pins, then capture at U2
                scan(0, 2 * N, {96'd0, drv, {NI{1'b0}}, {N{1'b0}}}, o);
                seen = o[NI-1:0];                                    // U2 input cells
                bad  = bad | (seen ^ drv);
            end
        end
    endtask

    initial begin
        #25 trst_n = 1;
        tap_reset;

        // ---- IDCODE is selected by reset: a plain DR scan returns both IDs
        scan(0, 64, 0, o);
        check("IDCODE U2", o[31:0], ID2);
        check("IDCODE U1", o[63:32], ID1);

        // ---- IR capture must read ...01 for every device
        load_ir(BYPASS, BYPASS, cap);
        check("IR capture", cap, 8'b0001_0001);

        // ---- BYPASS: each device adds exactly one bit of delay
        scan(0, 34, {94'd0, 32'hDEADBEEF, 2'b00} >> 2, o);
        check("BYPASS data", o[33:2], 32'hDEADBEEF);
        check("BYPASS capture zeros", o[1:0], 2'b00);

        // ---- normal mode: pins are transparent
        u1_pad_in = 8'hA5; u1_core_out = 8'h3C; #1;
        check("transparent in", u1_core_in, 8'hA5);
        check("transparent out", u1_pad_out, 8'h3C);

        // ---- SAMPLE: snapshot pins without disturbing them
        load_ir(SAMPLE, BYPASS, cap);
        scan(0, N + 1, 0, o);
        check("SAMPLE captured {core_out, pad_in}", o[N:1], {8'h3C, 8'hA5});
        check("SAMPLE leaves pins alone", {u1_pad_out, u1_core_in}, {8'h3C, 8'hA5});

        // ---- PRELOAD + EXTEST: pins come from the boundary register
        scan(0, N + 1, {111'd0, 8'h5A, 8'h00, 1'b0}, o);
        check("PRELOAD does not drive", u1_pad_out, 8'h3C);
        load_ir(EXTEST, BYPASS, cap);
        check("EXTEST drives preloaded value", u1_pad_out, 8'h5A);
        scan(0, N + 1, {111'd0, 8'hC3, 8'h00, 1'b0}, o);
        check("EXTEST captured input pins", o[NI:1], 8'hA5);
        check("EXTEST new drive value", u1_pad_out, 8'hC3);

        // ---- CLAMP: outputs stay held while the chain is short
        load_ir(CLAMP, BYPASS, cap);
        scan(0, 10, 10'h2AA, o);
        check("CLAMP holds outputs", u1_pad_out, 8'hC3);

        // ---- INTEST: boundary register drives the core, observes its outputs
        load_ir(SAMPLE, BYPASS, cap);
        scan(0, N + 1, {111'd0, 8'h00, 8'h77, 1'b0}, o);
        load_ir(INTEST, BYPASS, cap);
        check("INTEST drives core inputs", u1_core_in, 8'h77);
        check("INTEST passes core outputs", u1_pad_out, 8'h3C);

        // ---- USER register: read status, write a control word
        load_ir(USER, BYPASS, cap);
        scan(0, UW + 1, {111'd0, 16'hCAFE, 1'b0}, o);
        check("USER capture", o[UW:1], 16'hBEEF);
        check("USER update", u1_user_upd, 16'hCAFE);

        // ---- random boundary-register shift integrity
        for (i = 0; i < 50; i = i + 1) begin
            b1 = $urandom; b2 = $urandom;
            load_ir(SAMPLE, SAMPLE, cap);
            scan(0, 2 * N, {96'd0, b1, b2}, o);          // preload both
            u1_pad_in = $urandom; u1_core_out = $urandom; u2_core_out = $urandom; #1;
            scan(0, 2 * N, 0, o);
            check("random SAMPLE U1", o[2*N-1:N], {u1_core_out, u1_pad_in});
            check("random SAMPLE U2", o[N-1:0], {u2_core_out, net});
        end

        // ---- TMS reset from any state returns to IDCODE and releases the pins
        load_ir(EXTEST, EXTEST, cap);
        tap_reset;
        u1_core_out = 8'h99; #1;
        check("reset releases pins", u1_pad_out, 8'h99);
        scan(0, 64, 0, o);
        check("IDCODE after reset", o[63:0], {ID1, ID2});

        // ================= board-level interconnect test =================
        f_kind = 0;
        interconnect_test(bad_mask);
        check("good board has no bad nets", bad_mask, 8'h00);

        detected = 0; located = 0; n_faults = 0;
        for (k = 1; k <= 4; k = k + 1)
            for (a = 0; a < NI; a = a + 1) begin
                b = (a + 1 + $urandom_range(0, NI - 2)) % NI;
                f_kind = k; f_a = a; f_b = b;
                interconnect_test(bad_mask);
                n_faults = n_faults + 1;
                if (bad_mask != 0) detected = detected + 1;
                pat = (k == 4) ? ((8'd1 << a) | (8'd1 << b)) : (8'd1 << a);
                if (bad_mask == pat) located = located + 1;
                else $display("  defect kind %0d on net %0d/%0d: diagnosed mask %b, expected %b", k, a, b, bad_mask, pat);
            end
        f_kind = 0;
        $display("interconnect test: %0d defects injected (open, stuck-0, stuck-1, short), %0d detected, %0d located exactly",
                 n_faults, detected, located);
        if (detected != n_faults || located != n_faults) errors = errors + 1;

        $display("JTAG: %0d checks, %0d errors", checks, errors);
        if (errors != 0) $fatal(1, "TEST FAILED");
        $display("TEST PASSED");
        $finish;
    end
endmodule
