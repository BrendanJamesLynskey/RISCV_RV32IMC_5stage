// xbrvdsp.cc — Spike model of Xbrvdsp, BRV32P's DSP extension (step 1:
// the multiply-accumulate unit). Loaded with
//   spike --extlib=libxbrvdsp.so --extension=xbrvdsp ...
// so that programs using the extension run in lockstep with the RTL.
// Specification: doc/dsp_extension.md.
//
// State: acc, a 40-bit signed accumulator (held sign-extended in 64 bits).
// Encodings, all in custom-0 (opcode 0001011):
//   mac     rs1, rs2   funct7 0000000, funct3 000, rd 0   acc += lo(rs1) * lo(rs2)
//   dmac    rs1, rs2   funct7 0000001, funct3 000, rd 0   acc += lo*lo + hi*hi
//   msu     rs1, rs2   funct7 0000010, funct3 000, rd 0   acc -= lo(rs1) * lo(rs2)
//   acc.set rs1        funct7 0000100, funct3 000, rd 0   acc = sext(rs1)
//   acc.seth rs1       funct7 0000101, funct3 000, rd 0   acc[39:32] = rs1[7:0]
//   acc.rd  rd, sh     funct7 0000000, funct3 001, rs1 0  rd = sat32((acc + rnd) >> sh)
//   acc.rdh rd, sh     funct7 0000000, funct3 010, rs1 0  rd = sat16((acc + rnd) >> sh)
//   acc.rdl rd         funct7 0000000, funct3 011, rs1 0, rs2 0  rd = acc[31:0]
//   acc.rdx rd         funct7 0000001, funct3 011, rs1 0, rs2 0  rd = sext(acc[39:32])
// lo/hi are the signed 16-bit halves; sh is the rs2 field (0-31); rnd is
// 2^(sh-1), or 0 when sh is 0.

// Register writes go to the commit log (--log-commits), which the lockstep
// check compares; Spike's own instructions set this in insn_template.cc
#define DECODE_MACRO_USAGE_LOGGED 1

#include "insn_macros.h"
#include "extension.h"
#include "decode_macros.h"
#include <cstdint>

static int64_t acc;                       // one hart

static int64_t wrap40(int64_t v)          // keep 40 bits, sign-extended
{
  return (int64_t)((uint64_t)v << 24) >> 24;
}

static int64_t lo16(reg_t r) { return (int16_t)(r & 0xFFFF); }
static int64_t hi16(reg_t r) { return (int16_t)((r >> 16) & 0xFFFF); }

static int64_t rounded_shift(unsigned sh)
{
  int64_t v = acc + (sh ? ((int64_t)1 << (sh - 1)) : 0);
  return v >> sh;
}

static reg_t x_mac(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc + lo16(RS1) * lo16(RS2));
  return pc + 4;
}

static reg_t x_dmac(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc + lo16(RS1) * lo16(RS2) + hi16(RS1) * hi16(RS2));
  return pc + 4;
}

static reg_t x_msu(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc - lo16(RS1) * lo16(RS2));
  return pc + 4;
}

static reg_t x_acc_set(processor_t* p, insn_t insn, reg_t pc)
{
  acc = (int32_t)RS1;
  return pc + 4;
}

static reg_t x_acc_seth(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40((acc & 0xFFFFFFFFLL) | ((int64_t)(RS1 & 0xFF) << 32));
  return pc + 4;
}

static reg_t x_acc_rdl(processor_t* p, insn_t insn, reg_t pc)
{
  WRITE_RD(sext32(acc & 0xFFFFFFFF));
  return pc + 4;
}

static reg_t x_acc_rdx(processor_t* p, insn_t insn, reg_t pc)
{
  WRITE_RD(sext32(acc >> 32));
  return pc + 4;
}

static reg_t x_acc_rd(processor_t* p, insn_t insn, reg_t pc)
{
  int64_t v = rounded_shift(insn.rs2());
  if (v > INT32_MAX) v = INT32_MAX;
  if (v < INT32_MIN) v = INT32_MIN;
  WRITE_RD(sext32(v));
  return pc + 4;
}

static reg_t x_acc_rdh(processor_t* p, insn_t insn, reg_t pc)
{
  int64_t v = rounded_shift(insn.rs2());
  if (v > INT16_MAX) v = INT16_MAX;
  if (v < INT16_MIN) v = INT16_MIN;
  WRITE_RD(sext32(v));
  return pc + 4;
}

struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rs1()]; }
} xrs1;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rs2()]; }
} xrs2;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return xpr_name[insn.rd()]; }
} xrd;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return std::to_string(insn.rs2()); }
} xsh;

#define ALL(f) f, f, f, f, f, f, f, f

class xbrvdsp_t : public extension_t
{
 public:
  const char* name() const override { return "xbrvdsp"; }

  std::vector<insn_desc_t> get_instructions(const processor_t &) override {
    return {
      {0x0000000B, 0xFE007FFF, ALL(x_mac)},
      {0x0200000B, 0xFE007FFF, ALL(x_dmac)},
      {0x0400000B, 0xFE007FFF, ALL(x_msu)},
      {0x0800000B, 0xFFF07FFF, ALL(x_acc_set)},
      {0x0A00000B, 0xFFF07FFF, ALL(x_acc_seth)},
      {0x0000300B, 0xFFFFF07F, ALL(x_acc_rdl)},
      {0x0200300B, 0xFFFFF07F, ALL(x_acc_rdx)},
      {0x0000100B, 0xFE0FF07F, ALL(x_acc_rd)},
      {0x0000200B, 0xFE0FF07F, ALL(x_acc_rdh)},
    };
  }

  std::vector<disasm_insn_t*> get_disasms(const processor_t *) override {
    return {
      new disasm_insn_t("mac",     0x0000000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("dmac",    0x0200000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("msu",     0x0400000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("acc.set", 0x0800000B, 0xFFF07FFF, {&xrs1}),
      new disasm_insn_t("acc.seth", 0x0A00000B, 0xFFF07FFF, {&xrs1}),
      new disasm_insn_t("acc.rdl", 0x0000300B, 0xFFFFF07F, {&xrd}),
      new disasm_insn_t("acc.rdx", 0x0200300B, 0xFFFFF07F, {&xrd}),
      new disasm_insn_t("acc.rd",  0x0000100B, 0xFE0FF07F, {&xrd, &xsh}),
      new disasm_insn_t("acc.rdh", 0x0000200B, 0xFE0FF07F, {&xrd, &xsh}),
    };
  }

  void reset(processor_t &) override { acc = 0; }
};

REGISTER_EXTENSION(xbrvdsp, []() { static xbrvdsp_t ext; return &ext; })
