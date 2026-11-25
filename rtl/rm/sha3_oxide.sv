// SPDX-License-Identifier: MIT
// Compile exactly one rtl/rm/*.sv file into each reconfigurable checkpoint.
module hash_rm (
    input  logic aclk, aresetn, start,
    input  logic [63:0] message_length,
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0] s_axis_tkeep,
    input  logic s_axis_tvalid, s_axis_tlast,
    output logic s_axis_tready,
    output logic [255:0] digest,
    output logic digest_valid,
    input  logic digest_ready,
    output logic busy,
    output logic [31:0] algorithm_id,
    output logic error
);
    typedef enum logic [1:0] {IDLE, RUN, HOLD, FAILED} state_t;
    state_t state;
    logic accepted_start, byte_valid, byte_last, byte_ready, stream_error;
    logic core_ready, core_valid, core_busy;
    logic [7:0] byte_data;
    assign accepted_start = start && (state == IDLE || state == FAILED);
    assign byte_ready = state == RUN && core_ready && !stream_error;
    assign algorithm_id = 1;
    assign busy = state == RUN;
    assign digest_valid = aresetn && state == HOLD && !stream_error;
    assign error = stream_error || state == FAILED;
    axis_bytes input_buffer (
        .aclk, .aresetn, .start(accepted_start), .message_length,
        .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tlast, .s_axis_tready,
        .byte_data, .byte_valid, .byte_last, .byte_ready, .error(stream_error)
    );
    // Unchanged Oxide SHA3-256, fastest (double-buffer) configuration.
    // Same byte adapter as the deployed byte-absorption core. Empty input is
    // explicitly unsupported by this comparison image, as in upstream Oxide.
    sha3_oxide_core core (
        .clk(aclk), .reset(!aresetn), .init(accepted_start),
        .msg_valid(byte_valid && state == RUN && !stream_error),
        .msg_last(byte_last), .msg_data(byte_data), .msg_ready(core_ready),
        .busy(core_busy), .digest_valid(core_valid), .digest
    );
    always_ff @(posedge aclk) begin
        if (!aresetn) state <= IDLE;
        else if (accepted_start) state <= message_length == 0 ? FAILED : RUN;
        else if (stream_error) state <= FAILED;
        else case (state)
            RUN: if (core_valid) state <= HOLD;
            HOLD: if (digest_ready) state <= IDLE;
            default: ;
        endcase
    end
endmodule
