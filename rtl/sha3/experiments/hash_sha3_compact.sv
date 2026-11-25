// SPDX-License-Identifier: MIT
// Original SHA3-256 RTL implementing FIPS 202. This is not the Oxide baseline.
// Registered framing validation keeps AXI inputs off the 1600-bit state enable.
// Up to eight bytes absorbed per clock, one Keccak round per clock.
// Digest is a view of the held state: there is no separate digest register.
module hash_sha3_compact (
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
    typedef enum logic [2:0] {IDLE, ABSORB, PAD, PERMUTE, HOLD, FAILED} state_t;
    state_t state;
    logic [63:0] lanes [0:24];
    logic [63:0] theta [0:24], rho_pi [0:24], round_value [0:24];
    logic [63:0] parity [0:4], delta [0:4];
    logic [7:0] position;
    logic [4:0] round_index;
    logic final_permutation, pad_after_permutation;
    logic accepted_start, stream_active, buffer_final;
    logic [63:0] buffer_data, remaining;
    logic [3:0] buffer_count, incoming_count, take_count;
    logic keep_ok, stream_error;
    logic [63:0] absorb_value [0:24];
    logic [63:0] byte_mask;
    logic [127:0] aligned_chunk;

    localparam logic [63:0] RC [0:23] = '{
        64'h0000000000000001, 64'h0000000000008082,
        64'h800000000000808a, 64'h8000000080008000,
        64'h000000000000808b, 64'h0000000080000001,
        64'h8000000080008081, 64'h8000000000008009,
        64'h000000000000008a, 64'h0000000000000088,
        64'h0000000080008009, 64'h000000008000000a,
        64'h000000008000808b, 64'h800000000000008b,
        64'h8000000000008089, 64'h8000000000008003,
        64'h8000000000008002, 64'h8000000000000080,
        64'h000000000000800a, 64'h800000008000000a,
        64'h8000000080008081, 64'h8000000000008080,
        64'h0000000080000001, 64'h8000000080008008
    };
    // Index x+5*y follows the FIPS 202 state mapping.
    localparam int RHO [0:24] = '{
         0, 1,62,28,27, 36,44, 6,55,20, 3,10,43,25,39,
        41,45,15,21, 8, 18, 2,61,56,14
    };
    function automatic logic [63:0] rol64(input logic [63:0] value, input int n);
        return (value << n) | (value >> ((64-n) % 64));
    endfunction

    always_comb begin
        for (int x=0; x<5; x++) begin
            parity[x] = lanes[x] ^ lanes[x+5] ^ lanes[x+10] ^ lanes[x+15] ^ lanes[x+20];
        end
        for (int x=0; x<5; x++) begin
            delta[x] = parity[(x+4)%5] ^ rol64(parity[(x+1)%5],1);
        end
        for (int y=0; y<5; y++) begin
            for (int x=0; x<5; x++) begin
                theta[x+5*y] = lanes[x+5*y] ^ delta[x];
                rho_pi[y+5*((2*x+3*y)%5)] = rol64(theta[x+5*y],RHO[x+5*y]);
            end
        end
        for (int y=0; y<5; y++) begin
            for (int x=0; x<5; x++) begin
                round_value[x+5*y] = rho_pi[x+5*y] ^
                    ((~rho_pi[(x+1)%5+5*y]) & rho_pi[(x+2)%5+5*y]);
            end
        end
        round_value[0] = round_value[0] ^ RC[round_index];
    end

    assign accepted_start = aresetn && start && (state == IDLE || state == FAILED);
    assign s_axis_tready = aresetn && !stream_error && stream_active && buffer_count == 0 &&
                           state != FAILED && state != IDLE && state != HOLD;
    assign algorithm_id = 32'd1;
    assign error = stream_error || state == FAILED;
    assign busy = (state != IDLE && state != HOLD && state != FAILED);
    assign digest_valid = aresetn && !stream_error && (state == HOLD);
    for (genvar i=0; i<4; i++) begin : digest_lanes
        assign digest[64*i +: 64] = lanes[i];
    end

    always_comb begin
        incoming_count = 0;
        for (int i=0; i<8; i++) incoming_count += {3'b0,s_axis_tkeep[i]};
        keep_ok = s_axis_tkeep != 0 && (s_axis_tkeep & (s_axis_tkeep + 8'd1)) == 0;
        take_count = buffer_count;
        if (int'(position) + int'(buffer_count) > 136)
            take_count = 4'(136-int'(position));
        byte_mask = 0;
        for (int i=0; i<8; i++) begin
            if (i < int'(take_count)) byte_mask[8*i +:8] = 8'hff;
        end
        // At most two adjacent lanes change. A single small alignment network
        // avoids eight cascaded dynamic read/modify/write muxes on the state.
        aligned_chunk = {64'd0,buffer_data & byte_mask} << (8*int'(position[2:0]));
        for (int i=0; i<25; i++) begin
            absorb_value[i] = lanes[i];
            if (i < 17) begin
                if (int'(position[7:3]) == i)
                    absorb_value[i] = lanes[i] ^ aligned_chunk[63:0];
                else if (i > 0 && int'(position[7:3]) == i-1)
                    absorb_value[i] = lanes[i] ^ aligned_chunk[127:64];
            end
        end
    end

    // An invalid beat is captured but can never be absorbed: the registered
    // fault takes priority over ABSORB on the following clock. Keep framing
    // carry/comparison logic independent of the high-fanout state write enable.
    always_ff @(posedge aclk) begin
        if (!aresetn || accepted_start) stream_error <= 0;
        else if (s_axis_tvalid && s_axis_tready &&
                 (!keep_ok || {60'd0,incoming_count} > remaining ||
                  s_axis_tlast != ({60'd0,incoming_count} == remaining)))
            stream_error <= 1;
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state <= IDLE; position <= 0; round_index <= 0;
            stream_active <= 0; buffer_final <= 0; buffer_data <= 0;
            remaining <= 0; buffer_count <= 0;
            final_permutation <= 0; pad_after_permutation <= 0;
            for (int i=0; i<25; i++) lanes[i] <= 0;
        end else if (accepted_start) begin
            state <= (message_length == 0) ? PAD : ABSORB;
            stream_active <= message_length != 0; remaining <= message_length;
            buffer_final <= 0; buffer_data <= 0; buffer_count <= 0;
            position <= 0; round_index <= 0;
            final_permutation <= 0; pad_after_permutation <= 0;
            for (int i=0; i<25; i++) lanes[i] <= 0;
        end else if (stream_error) begin
            state <= FAILED; stream_active <= 0; buffer_count <= 0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                buffer_data <= s_axis_tdata; buffer_count <= incoming_count;
                buffer_final <= s_axis_tlast;
                remaining <= remaining - {60'd0,incoming_count};
                if (s_axis_tlast) stream_active <= 0;
            end
            case (state)
                ABSORB: if (buffer_count != 0) begin
                    for (int i=0; i<25; i++) lanes[i] <= absorb_value[i];
                    buffer_count <= buffer_count - take_count;
                    buffer_data <= buffer_data >> (8*int'(take_count));
                    if (int'(position) + int'(take_count) == 136) begin
                        position <= 0; round_index <= 0;
                        final_permutation <= 0;
                        pad_after_permutation <= buffer_final && take_count == buffer_count;
                        state <= PERMUTE;
                    end else begin
                        position <= position + {4'b0,take_count};
                        if (buffer_final && take_count == buffer_count) state <= PAD;
                    end
                end
                PAD: begin
                    // Decode only the 17 rate lanes. A dynamic state read /
                    // modify / write would build a mux across all 25 lanes,
                    // including capacity lanes that padding must never touch.
                    // XORing both masks naturally combines 06 and 80 into 86
                    // when the domain byte occupies the final rate byte.
                    for (int i=0; i<17; i++) begin
                        if (position[7:3] == 5'(i))
                            lanes[i] <= lanes[i] ^ (64'h06 << (8*position[2:0])) ^
                                        (i == 16 ? 64'h8000000000000000 : 64'd0);
                        else if (i == 16)
                            lanes[i] <= lanes[i] ^ 64'h8000000000000000;
                    end
                    final_permutation <= 1;
                    round_index <= 0;
                    state <= PERMUTE;
                end
                PERMUTE: begin
                    for (int i=0; i<25; i++) lanes[i] <= round_value[i];
                    if (round_index == 23) begin
                        round_index <= 0;
                        if (final_permutation) state <= HOLD;
                        else if (pad_after_permutation) state <= PAD;
                        else state <= ABSORB;
                    end else round_index <= round_index + 1'b1;
                end
                HOLD: if (digest_ready) state <= IDLE;
                default: ;
            endcase
        end
    end
endmodule
