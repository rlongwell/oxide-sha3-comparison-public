-- SPDX-License-Identifier: MIT
-- Integration wrapper; the referenced Oxide algorithm source is unchanged.
library ieee;
use ieee.std_logic_1164.all;
use work.axi_st8_pkg;

-- Only flattens the VHDL-2019 record view; no algorithm or timing adaptation.
entity sha3_oxide_core is
    port (
        clk, reset, init, msg_valid, msg_last : in std_logic;
        msg_data : in std_logic_vector(7 downto 0);
        msg_ready, busy, digest_valid : out std_logic;
        digest : out std_logic_vector(255 downto 0)
    );
end entity;
architecture rtl of sha3_oxide_core is
    signal msg : axi_st8_pkg.axi_st_pkt_t;
begin
    msg.valid <= msg_valid; msg.last <= msg_last; msg.data <= msg_data;
    msg_ready <= msg.ready;
    core : entity work.sha3_256
        generic map (DOUBLE_BUFFER => true)
        port map (clk => clk, reset => reset, init => init, busy => busy,
                  msg_if => msg, digest => digest, digest_valid => digest_valid);
end architecture;
