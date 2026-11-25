// SPDX-License-Identifier: MIT
// Oxide comparison adapter: accept a replacement beat as the last byte drains.
// Compile instead of rtl/common/axis_bytes.sv; the core itself is unchanged.
module axis_bytes (
    input  logic aclk, aresetn, start,
    input  logic [63:0] message_length,
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0] s_axis_tkeep,
    input  logic s_axis_tvalid, s_axis_tlast,
    output logic s_axis_tready,
    output logic [7:0] byte_data,
    output logic byte_valid, byte_last,
    input  logic byte_ready,
    output logic error
);
    logic [63:0] data_q, remaining;
    logic [3:0] count_q;
    logic final_q, active;
    logic [3:0] incoming_count;
    logic keep_ok;

    always_comb begin
        incoming_count = 0;
        for (int i=0; i<8; i++) incoming_count += {3'b0,s_axis_tkeep[i]};
        keep_ok = (s_axis_tkeep != 0) &&
                  ((s_axis_tkeep & (s_axis_tkeep + 8'd1)) == 0);
    end
    assign s_axis_tready = aresetn && active && !error &&
                           (count_q == 0 || (count_q == 1 && byte_ready));
    assign byte_data = data_q[7:0];
    assign byte_valid = aresetn && !error && (count_q != 0);
    assign byte_last = final_q && (count_q == 1);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            data_q <= 0; remaining <= 0; count_q <= 0;
            final_q <= 0; active <= 0; error <= 0;
        end else if (start) begin
            data_q <= 0; count_q <= 0; final_q <= 0; error <= 0;
            remaining <= message_length;
            active <= (message_length != 0);
        end else begin
            if (byte_valid && byte_ready) begin
                data_q <= data_q >> 8;
                count_q <= count_q - 1'b1;
            end
            if (s_axis_tvalid && s_axis_tready) begin
                if (!keep_ok || {60'd0,incoming_count} > remaining ||
                    s_axis_tlast != ({60'd0,incoming_count} == remaining)) begin
                    error <= 1; active <= 0; count_q <= 0;
                end else begin
                    data_q <= s_axis_tdata; count_q <= incoming_count;
                    remaining <= remaining - {60'd0,incoming_count};
                    final_q <= s_axis_tlast;
                    if (s_axis_tlast) active <= 0;
                end
            end
        end
    end
endmodule
