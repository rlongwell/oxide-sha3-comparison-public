library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use work.axi_st8_pkg;
use work.keccak_pkg.all;

entity baseline_tb is
    generic (DB : boolean := false; SOURCE_GAPS : boolean := false);
end entity;

architecture test of baseline_tb is
    constant PERIOD : time := 10 ns;
    constant A_DIGEST : digest_t := x"8bcd2e03571215c8b2bfd8bdc64bb1ea15822dab2ceb6f727524a0fbf24b0880";
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal init : std_logic := '0';
    signal msg : axi_st8_pkg.axi_st_pkt_t;
    signal busy, dv : std_logic;
    signal digest : digest_t;
begin
    clk <= not clk after PERIOD / 2;
    dut : entity work.sha3_256
        generic map (DOUBLE_BUFFER => DB)
        port map (clk => clk, reset => reset, init => init, busy => busy,
                  msg_if => msg, digest => digest, digest_valid => dv);

    stimulus : process
        file vectors : text open read_mode is "vectors.txt";
        file cycles : text open write_mode is "cycles.csv";
        variable line_in, line_out : line;
        variable length, stalls, cases, input_cycles, total_cycles : natural := 0;
        variable expected, held : digest_t;
        variable byte_in : std_logic_vector(7 downto 0);
        variable first_time, last_time : time;

        procedure send_byte(value : std_logic_vector(7 downto 0); last : std_logic) is
        begin
            msg.data <= value; msg.valid <= '1'; msg.last <= last;
            loop
                wait until rising_edge(clk);
                exit when msg.ready = '1';
            end loop;
            wait until falling_edge(clk);
        end procedure;

        procedure check_clear is
        begin
            assert busy = '0' and dv = '0' and digest = (digest'range => '0')
                report "reset/init did not clear state" severity failure;
        end procedure;

        procedure check_recovery is
        begin
            send_byte(x"61", '1');
            msg.valid <= '0'; msg.last <= '0';
            wait until dv = '1' for 10 us;
            assert dv = '1' and digest = A_DIGEST
                report "recovery hash mismatch" severity failure;
            wait until falling_edge(clk);
            wait until falling_edge(clk);
        end procedure;
    begin
        write(line_out, string'("case,bytes,input_cycles,total_cycles,input_stalls"));
        writeline(cycles, line_out);
        msg.valid <= '0'; msg.last <= '0'; msg.data <= (others => '0');
        wait for 27 ns; check_clear; reset <= '0';
        wait until falling_edge(clk);
        for i in 1 to 8 loop
            wait until falling_edge(clk);
            assert dv = '0' and busy = '0' report "idle core invented a message" severity failure;
        end loop;

        while not endfile(vectors) loop
            readline(vectors, line_in); read(line_in, length); hread(line_in, expected);
            stalls := 0;
            for i in 1 to length loop
                hread(line_in, byte_in);
                if SOURCE_GAPS and i mod 7 = 0 then
                    msg.valid <= '0'; wait until falling_edge(clk);
                end if;
                msg.data <= byte_in; msg.valid <= '1';
                if i = length then msg.last <= '1'; else msg.last <= '0'; end if;
                loop
                    wait until rising_edge(clk);
                    exit when msg.ready = '1';
                    stalls := stalls + 1;
                end loop;
                if i = 1 then first_time := now; end if;
                if i = length then last_time := now; end if;
                wait until falling_edge(clk);
            end loop;
            msg.valid <= '0'; msg.last <= '0';
            -- A previous digest remains valid one cycle after next-message acceptance.
            if dv = '1' then wait until dv = '0' for 100 ns; end if;
            wait until dv = '1' for 10 us;
            assert dv = '1' report "digest timeout" severity failure;
            assert digest = expected
                report "digest mismatch length " & natural'image(length) & " got " & to_hstring(digest)
                severity failure;
            input_cycles := natural((last_time - first_time) / PERIOD) + 1;
            total_cycles := natural((now - first_time) / PERIOD) + 1;
            if DB then
                assert stalls = 0 report "double buffering stalled mid-message" severity failure;
            elsif length > 272 then
                assert stalls > 0 report "single-buffer test did not exercise backpressure" severity failure;
            end if;
            held := digest;
            for i in 1 to 4 loop
                wait until falling_edge(clk);
                assert dv = '1' and digest = held report "result was not held" severity failure;
            end loop;
            cases := cases + 1;
            write(line_out, cases); write(line_out, string'(","));
            write(line_out, length); write(line_out, string'(","));
            write(line_out, input_cycles); write(line_out, string'(","));
            write(line_out, total_cycles); write(line_out, string'(","));
            write(line_out, stalls); writeline(cycles, line_out);
        end loop;

        -- Synchronous abort during absorption, including a held init with active input.
        send_byte(x"55", '0');
        init <= '1';
        for i in 1 to 3 loop wait until falling_edge(clk); check_clear; end loop;
        msg.valid <= '0'; init <= '0'; wait until falling_edge(clk);
        check_recovery;

        -- Asynchronous reset in the middle of an unfinished block.
        send_byte(x"f0", '0');
        wait for 2 ns; reset <= '1'; wait for 1 ns; check_clear;
        msg.valid <= '0'; msg.last <= '0';
        wait until falling_edge(clk); reset <= '0'; wait until falling_edge(clk);
        check_recovery;

        -- Feed 135 bytes: the single padding byte closes the block immediately.
        -- Ten further cycles put both buffer configurations inside permutation.
        for i in 1 to 134 loop send_byte(x"a3", '0'); end loop;
        send_byte(x"a3", '1'); msg.valid <= '0'; msg.last <= '0';
        for i in 1 to 10 loop wait until falling_edge(clk); end loop;
        assert busy = '1' and dv = '0' report "reset-permutation test missed active operation" severity failure;
        wait for 2 ns; reset <= '1'; wait for 1 ns; check_clear;
        wait until falling_edge(clk); reset <= '0'; wait until falling_edge(clk);
        check_recovery;
        report "ALL PASS cases=" & natural'image(cases) & " DB=" & boolean'image(DB) &
               " SOURCE_GAPS=" & boolean'image(SOURCE_GAPS) & "; init/async reset recovery passed";
        std.env.finish;
    end process;

    watchdog : process
    begin
        wait for 10 ms;
        assert false report "baseline watchdog timeout" severity failure;
    end process;
end architecture;
