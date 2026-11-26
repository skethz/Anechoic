// Stream testbench for sca_core.v: drives stim.hex (random input gaps), checks every output word against expect.hex
// (random output back-pressure). Prints the cycle of each trial's last word so per-trial cycles can be read off.
`timescale 1ns/1ps
module tb;
    parameter integer DRAIN = 2;
    parameter integer TRIAL_WORDS = 34;   // informational
    reg clk = 1'b0, rst_n = 1'b0;
    always #1 clk = ~clk;

    reg [127:0] stim [0:65535];
    reg [63:0] expv [0:65535];
    integer nbeats, nwords, fd, rc;

    wire [127:0] s_tdata; wire s_tvalid, s_tready;
    wire [63:0] m_tdata; wire m_tvalid; reg m_tready;
    reg gap;
    integer bi, ei, errors, cycle, seedv;

    sca_core #(.DRAIN(DRAIN)) dut (.clk(clk), .rst_n(rst_n), .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready));

    assign s_tdata = stim[bi];
    assign s_tvalid = (bi < nbeats) & ~gap;

    initial begin
        $readmemh("stim.hex", stim);
        $readmemh("expect.hex", expv);
        fd = $fopen("counts.txt", "r");
        rc = $fscanf(fd, "%d %d", nbeats, nwords);
        $fclose(fd);
        $display("beats %0d words %0d DRAIN %0d", nbeats, nwords, DRAIN);
        bi = 0; ei = 0; errors = 0; cycle = 0; seedv = 12345; gap = 1'b0; m_tready = 1'b1;
        repeat (20) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;   // release between edges (no race with the DUT's synchronous reset)
    end

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (rst_n) begin
            if (s_tvalid & s_tready) bi <= bi + 1;
            if (!(s_tvalid && !s_tready)) gap <= ($random(seedv) % 16) == 0;
            m_tready <= ((cycle % 37) < 19) && (($random(seedv) % 8) != 0);
            if (m_tvalid & m_tready) begin
                if (m_tdata !== expv[ei]) begin
                    errors = errors + 1;
                    if (errors <= 20) $display("MISMATCH word %0d: got %016h expected %016h (cycle %0d)", ei, m_tdata, expv[ei], cycle);
                end
                ei <= ei + 1;
                if (ei + 1 == nwords) begin
                    if (bi != nbeats) $fatal(1, "unconsumed input");
                    $display("PROTOCOL input %0d output %0d input_stall %0d output_stall %0d prefetch_busy %0d",
                             bi, ei+1, input_stalls, output_stalls, prefetched_busy);
                    $display("DONE: %0d words, %0d errors, cycle %0d", nwords, errors, cycle);
                    $display(errors == 0 ? "TESTBENCH PASSED" : "TESTBENCH FAILED");
                    $finish;
                end
            end
        end
        if (cycle == 3000000) begin $display("TIMEOUT at word %0d beat %0d", ei, bi); $finish; end
    end

    reg prev_input_stall = 1'b0, prev_output_stall = 1'b0;
    reg [127:0] held_input;
    reg [63:0] held_output;
    integer input_stalls = 0, output_stalls = 0, prefetched_busy = 0;
    always @(posedge clk) if (rst_n) begin
        if (prev_input_stall && ((s_tvalid !== 1'b1) || s_tdata !== held_input))
            $fatal(1, "input changed while stalled");
        if (prev_output_stall && ((m_tvalid !== 1'b1) || m_tdata !== held_output))
            $fatal(1, "output changed while stalled");
        prev_input_stall = s_tvalid && !s_tready;
        prev_output_stall = m_tvalid && !m_tready;
        held_input = s_tdata; held_output = m_tdata;
        if (prev_input_stall) input_stalls = input_stalls + 1;
        if (prev_output_stall) output_stalls = output_stalls + 1;
        if (s_tvalid && s_tready && !dut.core_ready) prefetched_busy = prefetched_busy + 1;
    end
    // trial timing: entry to SEED (trial start) and to OUT (results ready), from the DUT state register
    reg [3:0] st_prev; initial st_prev = 4'hf;
    always @(posedge clk) begin
        st_prev <= dut.st;
        if (dut.st == 4'd5 && st_prev != 4'd5) $display("trial start: cycle %0d", cycle);
        if (dut.st == 4'd9 && st_prev != 4'd9) $display("trial out: cycle %0d", cycle);
    end
    // launch timing: header accepted -> last word of the launch accepted
    always @(posedge clk) if (rst_n & s_tvalid & s_tready & (dut.st == 4'd0))
        $display("launch start: beat %0d cycle %0d", bi, cycle);
    // per-trial timing: report when the 33rd word (flips) of a trial is accepted
    integer wi_in_trial; initial wi_in_trial = 0;
    always @(posedge clk) if (rst_n & m_tvalid & m_tready) begin
        if (wi_in_trial == 33) $display("trial end: word %0d cycle %0d flips %0d", ei, cycle, m_tdata);
        wi_in_trial <= wi_in_trial + 1;
    end
    // trial word counting depends on trace length; reset the counter on the testbench side from the DUT's FSM
    always @(posedge clk) if (dut.st == 4'd4) wi_in_trial <= 0;
endmodule
