`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Self-checking testbench for systolic_controller (and, through it, Systolic_NxN and pe).
//
// The reference model is NumPy. tb/gen_vectors.py picks random operands, computes
//     C = A[:, :k_len] @ B[:k_len, :]
// with NumPy and writes operands and expected results to tb/vectors/vec_n<N>.mem.
// This testbench loads those files, drives the RTL and compares every result word.
//
// Five array sizes run side by side: N = 1, 2, 3, 4 and 8, all with K_MAX = 75.
//
// What is checked on every job
//   1. All N*N results equal the NumPy results.
//   2. Latency: done rises exactly k_len + 2N - 1 clocks after the start is accepted.
//   3. busy is high for the whole job; done is a single-clock pulse; busy is low with done.
//   4. Operands are latched at start: the inputs are overwritten with random data one
//      clock later, and operands past k_len are random from the beginning.
//   5. Results hold their value while the controller is idle.
// What is checked on some jobs (chosen by the vector file)
//   6. A start with an illegal k_len (0 or above K_MAX) is ignored.
//   7. A start pulse while busy is ignored.
//   8. A reset in the middle of a job clears busy, done and all sums; the job then
//      runs again and must give the right answer.
//
// Prints "TB PASS" or "TB FAIL" as its last line.
// Vector folder: +VEC_DIR=<path>. Without it: ./vectors, then ../vectors.
//////////////////////////////////////////////////////////////////////////////////

module tb_systolic_controller;
    localparam int K_MAX     = 75;
    localparam int NUM_TESTS = 200;   // jobs per array size; must match gen_vectors.py --tests
    localparam int CASES     = 5;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic [CASES-1:0] finished;
    int errors [CASES];
    int jobs   [CASES];

    sc_case #(.N(1), .K_MAX(K_MAX), .NUM_TESTS(NUM_TESTS)) n1 (.clk(clk), .finished(finished[0]), .errors(errors[0]), .jobs(jobs[0]));
    sc_case #(.N(2), .K_MAX(K_MAX), .NUM_TESTS(NUM_TESTS)) n2 (.clk(clk), .finished(finished[1]), .errors(errors[1]), .jobs(jobs[1]));
    sc_case #(.N(3), .K_MAX(K_MAX), .NUM_TESTS(NUM_TESTS)) n3 (.clk(clk), .finished(finished[2]), .errors(errors[2]), .jobs(jobs[2]));
    sc_case #(.N(4), .K_MAX(K_MAX), .NUM_TESTS(NUM_TESTS)) n4 (.clk(clk), .finished(finished[3]), .errors(errors[3]), .jobs(jobs[3]));
    sc_case #(.N(8), .K_MAX(K_MAX), .NUM_TESTS(NUM_TESTS)) n8 (.clk(clk), .finished(finished[4]), .errors(errors[4]), .jobs(jobs[4]));

    initial begin
        int total_errors;
        int total_jobs;
        wait (&finished);
        total_errors = 0;
        total_jobs   = 0;
        for (int i = 0; i < CASES; i++) begin
            total_errors += errors[i];
            total_jobs   += jobs[i];
        end
        if (total_errors == 0)
            $display("TB PASS: %0d jobs matched the NumPy reference (N = 1, 2, 3, 4, 8).", total_jobs);
        else
            $display("TB FAIL: %0d errors in %0d jobs.", total_errors, total_jobs);
        $finish;
    end

    initial begin
        #100ms;
        $display("TB FAIL: timeout, finished = %b", finished);
        $finish;
    end
endmodule


module sc_case #(
    parameter int N         = 2,
    parameter int K_MAX     = 75,
    parameter int NUM_TESTS = 200
) (
    input  logic clk,
    output logic finished,
    output int   errors,
    output int   jobs
);
    localparam int K_WIDTH    = $clog2(K_MAX + 1);
    localparam int FILE_HDR   = 3;
    localparam int REC_HDR    = 5;
    localparam int REC        = REC_HDR + 2 * N * K_MAX + N * N;
    localparam int MAX_ERRORS = 10;

    localparam int FLAG_INVALID_START = 1;
    localparam int FLAG_POKE_START    = 2;
    localparam int FLAG_RESET_ABORT   = 4;

    // ------------------------------------------------------------------ DUT
    logic rst, start, busy, done;
    logic [K_WIDTH-1:0] k_len;
    logic signed [7:0]  A [0:N-1][0:K_MAX-1];
    logic signed [7:0]  B [0:K_MAX-1][0:N-1];
    wire  signed [31:0] C [0:N-1][0:N-1];

    systolic_controller #(.N(N), .K_MAX(K_MAX)) dut (
        .clk(clk), .rst(rst), .start(start), .k_len(k_len),
        .A(A), .B(B), .busy(busy), .done(done), .C(C)
    );

    // ------------------------------------------------------------------ vectors
    logic [31:0] mem [0:FILE_HDR + NUM_TESTS * REC - 1];
    logic signed [31:0] c_expect [0:N-1][0:N-1];
    logic signed [31:0] c_before [0:N-1][0:N-1];
    string vec_dir;
    int    test_index;

    function automatic int word(input int base, input int offset);
        return int'(mem[base + offset]);
    endfunction

    task automatic fail(input string what);
        errors++;
        $display("ERROR N=%0d job %0d at %0t: %s", N, test_index, $time, what);
    endtask

    // Put a job's operands on the inputs. Call on a falling edge.
    task automatic drive_operands(input int base);
        for (int i = 0; i < N; i++)
            for (int k = 0; k < K_MAX; k++)
                A[i][k] = 8'(mem[base + REC_HDR + i * K_MAX + k]);
        for (int k = 0; k < K_MAX; k++)
            for (int j = 0; j < N; j++)
                B[k][j] = 8'(mem[base + REC_HDR + N * K_MAX + k * N + j]);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++)
                c_expect[i][j] = mem[base + REC_HDR + 2 * N * K_MAX + i * N + j];
    endtask

    // Overwrite the inputs with random data. A correct design has already latched them.
    task automatic scramble_inputs();
        for (int i = 0; i < N; i++)
            for (int k = 0; k < K_MAX; k++)
                A[i][k] = 8'($urandom);
        for (int k = 0; k < K_MAX; k++)
            for (int j = 0; j < N; j++)
                B[k][j] = 8'($urandom);
        k_len = K_WIDTH'($urandom);
    endtask

    task automatic check_results(input string when_checked);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++)
                if (C[i][j] !== c_expect[i][j])
                    fail($sformatf("%s: C[%0d][%0d] = %0d, NumPy says %0d",
                                   when_checked, i, j, C[i][j], c_expect[i][j]));
    endtask

    task automatic check_idle(input string when_checked);
        if (busy !== 1'b0) fail($sformatf("%s: busy should be 0", when_checked));
        if (done !== 1'b0) fail($sformatf("%s: done should be 0", when_checked));
    endtask

    // Start one job and follow it clock by clock.
    //   stop_at = 0: run to completion and check the results.
    //   stop_at = c: assert rst so that it is sampled on clock c of the job, then check
    //                that everything cleared. The caller runs the job again.
    //   poke_at = c: pulse start (with a random k_len) so that it is sampled on clock c.
    // Enter and leave on a falling edge. On a normal exit, done is high.
    task automatic run_job(input int base, input int poke_at, input int stop_at);
        int k;
        int latency;
        k       = word(base, 0);
        latency = k + 2 * N - 1;      // clocks from the accepting edge to the edge that raises done

        drive_operands(base);
        k_len = K_WIDTH'(k);
        start = 1'b1;
        @(negedge clk);               // the rising edge in between accepted the start
        start = 1'b0;
        scramble_inputs();

        // m counts rising edges since the accepting edge. We sit on the falling edge after edge m.
        for (int m = 0; m <= latency; m++) begin
            if (m < latency) begin
                if (busy !== 1'b1) fail($sformatf("busy dropped %0d clocks into a %0d-clock job", m, latency));
                if (done !== 1'b0) fail($sformatf("done rose after %0d clocks, expected %0d", m, latency));
            end else begin
                if (done !== 1'b1) fail($sformatf("done did not rise after %0d clocks (k_len = %0d)", latency, k));
                if (busy !== 1'b0) fail("busy still high when done is high");
                check_results("at done");
            end

            if (stop_at != 0 && m == stop_at - 1) begin
                rst = 1'b1;
                @(negedge clk);
                rst = 1'b0;
                check_idle("after reset in the middle of a job");
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++)
                        if (C[i][j] !== 32'sd0)
                            fail($sformatf("after reset in the middle of a job: C[%0d][%0d] = %0d, expected 0", i, j, C[i][j]));
                return;
            end

            start = (poke_at != 0 && m == poke_at - 1);
            if (start) k_len = K_WIDTH'($urandom);
            if (m < latency) @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------ main sequence
    initial begin
        int base, gap, flags, poke, bad_k, fd;

        finished = 1'b0;
        errors   = 0;
        jobs     = 0;
        test_index = -1;
        // Without +VEC_DIR, look in ./vectors and then ../vectors (run_xsim.tcl runs one folder down).
        if (!$value$plusargs("VEC_DIR=%s", vec_dir)) begin
            vec_dir = "vectors";
            fd = $fopen($sformatf("%s/vec_n%0d.mem", vec_dir, N), "r");
            if (fd == 0) vec_dir = "../vectors";
            else $fclose(fd);
        end
        $readmemh($sformatf("%s/vec_n%0d.mem", vec_dir, N), mem);
        if (mem[0] !== 32'(N) || mem[1] !== 32'(K_MAX) || mem[2] !== 32'(NUM_TESTS)) begin
            $display("ERROR N=%0d: %s/vec_n%0d.mem is missing or was generated for other settings.", N, vec_dir, N);
            $display("      Run: python tb/gen_vectors.py --tests %0d --kmax %0d", NUM_TESTS, K_MAX);
            errors   = 1;
            finished = 1'b1;
        end else begin
            rst   = 1'b1;
            start = 1'b0;
            scramble_inputs();
            repeat (3) @(negedge clk);
            check_idle("during reset");
            rst = 1'b0;
            @(negedge clk);
            check_idle("after reset");

            for (int t = 0; t < NUM_TESTS && errors < MAX_ERRORS; t++) begin
                test_index = t;
                base  = FILE_HDR + t * REC;
                gap   = word(base, 1);
                flags = word(base, 2);
                poke  = word(base, 3);
                bad_k = word(base, 4);

                // Idle clocks before the job. The previous results must not move.
                // (With gap = 0 we arrive here on the clock where done is high and start at once.)
                if (gap > 0) begin
                    for (int i = 0; i < N; i++)
                        for (int j = 0; j < N; j++)
                            c_before[i][j] = C[i][j];

                    if ((flags & FLAG_INVALID_START) != 0) begin
                        @(negedge clk);
                        check_idle("before an illegal start");
                        drive_operands(base);
                        k_len = K_WIDTH'(bad_k);
                        start = 1'b1;
                        @(negedge clk);
                        start = 1'b0;
                        if (busy !== 1'b0) fail($sformatf("start with illegal k_len = %0d was accepted", bad_k));
                    end

                    repeat (gap) begin
                        @(negedge clk);
                        check_idle("while idle");
                    end
                    for (int i = 0; i < N; i++)
                        for (int j = 0; j < N; j++)
                            if (C[i][j] !== c_before[i][j])
                                fail($sformatf("C[%0d][%0d] changed while idle: %0d -> %0d", i, j, c_before[i][j], C[i][j]));
                end

                if ((flags & FLAG_RESET_ABORT) != 0) begin
                    run_job(base, 0, poke);
                    @(negedge clk);
                    check_idle("one clock after the reset");
                    run_job(base, 0, 0);
                end else if ((flags & FLAG_POKE_START) != 0) begin
                    run_job(base, poke, 0);
                end else begin
                    run_job(base, 0, 0);
                end
                jobs++;
            end

            // done must be a single-clock pulse on the last job as well.
            start = 1'b0;
            @(negedge clk);
            check_idle("after the last job");
            check_results("one clock after the last done");

            if (errors == 0)
                $display("PASS N=%0d: %0d jobs matched NumPy; done after exactly k_len + %0d clocks on every job.", N, jobs, 2 * N - 1);
            else
                $display("FAIL N=%0d: %0d errors in %0d jobs.", N, errors, jobs);
            finished = 1'b1;
        end
    end
endmodule
