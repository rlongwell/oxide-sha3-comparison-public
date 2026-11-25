// SPDX-License-Identifier: MIT
#include "Vhash_rm.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

class Bench {
public:
    Vhash_rm dut;
    uint64_t cycles = 0;
    std::mt19937 rng{0xdf02026};
    void require(bool okay, const std::string& message) {
        if (!okay) throw std::runtime_error(message + " at cycle " + std::to_string(cycles));
    }
    void settle() { dut.aclk = 0; dut.eval(); }
    void tick() {
        settle(); dut.aclk = 1; dut.eval(); ++cycles; dut.aclk = 0; dut.eval();
    }
    void reset() {
        dut.aresetn = 0; dut.start = 0; dut.s_axis_tvalid = 0;
        dut.s_axis_tlast = 0; dut.s_axis_tkeep = 0;
        dut.s_axis_tdata = 0; dut.digest_ready = 0; dut.message_length = 0;
        tick(); tick();
        require(!dut.busy && !dut.digest_valid && !dut.s_axis_tready && !dut.error,
                "reset did not clear interface");
        dut.aresetn = 1; tick();
    }
    void start(uint64_t n) {
        require(!dut.busy && !dut.digest_valid, "new request while occupied");
        dut.message_length=n; dut.start=1; tick(); dut.start=0; settle();
    }
    void beat(uint64_t data, unsigned keep, bool last) {
        dut.s_axis_tdata=data; dut.s_axis_tkeep=keep; dut.s_axis_tlast=last;
        dut.s_axis_tvalid=1;
        for (unsigned timeout=0; ; ++timeout) {
            settle(); bool accepted=dut.s_axis_tready; tick();
            if (accepted) break;
            require(timeout < 10000, "input handshake timeout");
        }
        dut.s_axis_tvalid=0; dut.s_axis_tlast=0; settle();
    }
    std::string digest() {
        std::ostringstream text; text << std::hex << std::setfill('0');
        for (int i=0; i<32; ++i) text << std::setw(2)
            << ((dut.digest[i/4] >> (8*(i%4))) & 255);
        return text.str();
    }
    void wait_result() {
        for (unsigned timeout=0; !dut.digest_valid; ++timeout) {
            require(!dut.error, "unexpected engine error");
            require(timeout < 10000, "result timeout"); tick();
        }
    }
    uint64_t run(const std::vector<uint8_t>& payload, const std::string& expected,
                 bool stressed) {
        uint64_t begin=cycles;
        start(payload.size());
        if (stressed) {
            // A second start while processing must not clear the transaction.
            dut.start=1; dut.message_length=0; tick(); dut.start=0;
        }
        size_t offset=0;
        while (offset<payload.size()) {
            if (stressed) for (unsigned i=0,n=rng()%5; i<n; ++i) tick();
            size_t n=std::min<size_t>(stressed ? 1+rng()%8 : 8,payload.size()-offset);
            uint64_t data=0; for (size_t i=0; i<n; ++i) data|=uint64_t(payload[offset+i])<<(8*i);
            beat(data,(1u<<n)-1,offset+n==payload.size()); offset+=n;
        }
        wait_result(); uint64_t elapsed=cycles-begin;
        require(digest()==expected,"digest mismatch: got "+digest()+" expected "+expected);
        auto held=digest();
        for (unsigned i=0,n=stressed ? 1+rng()%37 : 2; i<n; ++i) {
            // A spurious start must not overwrite a held result.
            dut.start=(i==0); dut.message_length=0; tick(); dut.start=0;
            require(dut.digest_valid && digest()==held,"result changed under backpressure");
            require(!dut.s_axis_tready,"input accepted after final file byte");
        }
        dut.digest_ready=1; tick(); dut.digest_ready=0; tick();
        require(!dut.digest_valid && !dut.busy,"completion not retired");
        return elapsed;
    }
    void bad_frame(uint64_t length, unsigned keep, bool last) {
        reset(); start(length); beat(0x0102030405060708ULL,keep,last);
        for (int i=0;i<4;++i) tick();
        require(dut.error && !dut.digest_valid && !dut.s_axis_tready,"bad framing not rejected");
        // Error recovery is permitted by a fresh start as well as reset.
        dut.message_length=0; dut.start=1; tick(); dut.start=0;
        require(!dut.error,"fresh request did not clear protocol error");
        wait_result(); dut.digest_ready=1; tick(); dut.digest_ready=0; tick();
    }
};

std::vector<uint8_t> decode(const std::string& hex) {
    std::vector<uint8_t> bytes;
    if(hex=="-") return bytes;
    for(size_t i=0;i<hex.size();i+=2) bytes.push_back(std::stoul(hex.substr(i,2),nullptr,16));
    return bytes;
}
int main(int argc,char** argv) {
    try {
        Verilated::commandArgs(argc,argv);
        if(argc!=3) throw std::runtime_error("usage: test_engine vectors.txt algorithm_id");
        Bench b; b.reset();
        b.require(b.dut.algorithm_id==std::stoul(argv[2]),"algorithm ID mismatch");
        std::ifstream input(argv[1]); if(!input) throw std::runtime_error("cannot open vector file");
        std::string name,hex,expected,abc_digest; size_t n; unsigned count=0;
        while(input>>name>>n>>hex>>expected) {
            auto data=decode(hex); b.require(data.size()==n,"malformed vector size");
            auto continuous=b.run(data,expected,false);
            auto stressed=b.run(data,expected,true);
            std::cout << "PASS " << name << " length=" << n << " continuous_cycles="
                      << continuous << " stressed_cycles=" << stressed << '\n'; ++count;
            if(name=="ascii_abc") abc_digest=expected;
        }
        b.require(count>=70,"missing expected vector set");
        b.bad_frame(8,0,false); b.bad_frame(8,0x55,false); b.bad_frame(3,0xff,true);
        b.bad_frame(8,0xff,false); b.bad_frame(16,0xff,true);
        // Abort with buffered bytes and during compression, then prove a fresh message.
        b.reset(); b.start(1024); b.beat(0x12345678,0xff,false); b.tick(); b.reset();
        b.run({'a','b','c'},abc_digest,true);
        b.start(64);
        for(int i=0;i<8;++i) b.beat(0x0706050403020100ULL,255,i==7);
        for(int i=0;i<12;++i) b.tick();
        b.reset(); b.run({'a','b','c'},abc_digest,true);
        if(b.dut.algorithm_id==2) {
            b.start(uint64_t(1)<<61); b.tick();
            b.require(b.dut.error && !b.dut.s_axis_tready && !b.dut.busy,
                      "SHA256 accepted length that overflows its bit counter");
            b.run({'a','b','c'},abc_digest,true);
        }
        std::cout << "ALL PASS vectors=" << count << " modes=2 framing_errors=5 abort_cases=2\n";
        b.dut.final(); return 0;
    } catch(const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
