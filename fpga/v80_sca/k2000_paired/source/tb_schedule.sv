`timescale 1ns/1ps
// Exercise the actual sequencer over all schedule rows. Bypass datapath wait/seed latency only.
module tb_schedule;
    reg clk=0, rst_n=1;
    always #1 clk=~clk;
    sca_core dut(.clk(clk),.rst_n(rst_n),.s_axis_tdata(128'd0),.s_axis_tvalid(1'b0),.m_axis_tready(1'b1));
    task traverse(input integer length);
        integer t, dest;
        begin
            @(negedge clk);
            force dut.st=4'd4;
            dut.p_S=length;dut.tr=0;dut.p_trials=1;dut.last_dec=0;
            @(posedge clk); #0.1;
            if(dut.tab_raddr!==12'd0 || !dut.tab_ld1) $fatal(1,"bad reset row");
            release dut.st;
            for(t=0;t<length;t=t+1)begin
                @(negedge clk);force dut.st=4'd7;dut.b_mode=t==0?0:1;
                dut.dr=2;dut.nk_ready=1;
                @(posedge clk); #0.1;
                dest=length==21400?((t+1)*3649/21399):(t+1);
                if(t+1<length && (dut.tab_raddr!==dest[11:0] || !dut.tab_ld1)) $fatal(1,"row address mismatch length %0d t %0d got %0d expected %0d",length,t,dut.tab_raddr,dest);
                if(dut.last_dec!==(t+1==length))$fatal(1,"incorrect final step");
                release dut.st;
            end
            $display("PASS all %0d table addresses and final-step flag",length);
        end
    endtask
    initial begin
        traverse(3650); traverse(21400); traverse(21400); traverse(280);
        $finish;
    end
endmodule
