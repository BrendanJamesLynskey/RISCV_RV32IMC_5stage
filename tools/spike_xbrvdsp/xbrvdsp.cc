// xbrvdsp.cc — Spike model of Xbrvdsp, BRV32P's DSP extension (step 1:
// the multiply-accumulate unit; step 2: address generators; step 4: the
// hardware loop). Loaded with
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
//
// Address registers ar0-ar3: an address and a signed 16-bit byte stride.
// Encodings in custom-1 (opcode 0101011):
//   ar.set arN, rs1    funct7 0000000, funct3 000, rd N, rs2 0   addr = rs1
//   ar.cfg arN, rs1    funct7 0000001, funct3 000, rd N, rs2 0   stride = rs1[15:0]
//   lh.a  rd, arN      funct3 001, rs1 0, imm N    rd = sext(mem16[addr]); addr += stride
//   lw.a  rd, arN      funct3 010, rs1 0, imm N    rd = mem32[addr]; addr += stride
//   lhu.a rd, arN      funct3 101, rs1 0, imm N    rd = zext(mem16[addr]); addr += stride
//   ar.rd  rd, arN     funct3 011, rs1 0, imm N      rd = addr
//   ar.rds rd, arN     funct3 011, rs1 0, imm N + 4  rd = sext(stride)
// A load that traps (misaligned) leaves its address register unchanged.
//
// Hardware loop: lc (count) and lp_start. The body's last instruction is
// marked: mac.lp / dmac.lp / msu.lp (funct7 bit 6 set) or lp.end. After it,
// if lc > 1: lc -= 1 and go to lp_start; else lc = 0 and fall through.
//   lp.setup rs1   custom-1, funct3 110, rd 0, imm 0    lc = rs1; lp_start = pc + 4
//   lp.end         custom-1, funct3 111, all other fields 0
//   lp.set  rs1    custom-1, funct7 0000010, funct3 000, rd 0, rs2 0   lc = rs1
//   lp.sets rs1    ... rd 1                                         lp_start = rs1
//   lp.rd  rd, 8   custom-1, funct3 011, rs1 0, imm 8: rd = lc; imm 9: rd = lp_start

// Register writes go to the commit log (--log-commits), which the lockstep
// check compares; Spike's own instructions set this in insn_template.cc
#define DECODE_MACRO_USAGE_LOGGED 1

#include "insn_macros.h"
#include "extension.h"
#include "processor.h"
#include "mmu.h"
#include "decode_macros.h"
#include <cstdint>

static int64_t acc;                       // one hart
static uint32_t ar_addr[4];
static int16_t  ar_stride[4];
static uint32_t lc, lp_start;

static reg_t loop_next(reg_t pc)          // after a loop-end instruction
{
  if (lc > 1) {
    lc--;
    return lp_start;
  }
  lc = 0;
  return pc + 4;
}

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

static reg_t x_mac_lp(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc + lo16(RS1) * lo16(RS2));
  return loop_next(pc);
}

static reg_t x_dmac_lp(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc + lo16(RS1) * lo16(RS2) + hi16(RS1) * hi16(RS2));
  return loop_next(pc);
}

static reg_t x_msu_lp(processor_t* p, insn_t insn, reg_t pc)
{
  acc = wrap40(acc - lo16(RS1) * lo16(RS2));
  return loop_next(pc);
}

static reg_t x_lp_setup(processor_t* p, insn_t insn, reg_t pc)
{
  lc = (uint32_t)RS1;
  lp_start = (uint32_t)(pc + 4);
  return pc + 4;
}

static reg_t x_lp_end(processor_t* p, insn_t insn, reg_t pc)
{
  return loop_next(pc);
}

static reg_t x_lp_set(processor_t* p, insn_t insn, reg_t pc)
{
  if (insn.rd() == 1)
    lp_start = (uint32_t)RS1;
  else
    lc = (uint32_t)RS1;
  return pc + 4;
}

static reg_t x_lp_rd(processor_t* p, insn_t insn, reg_t pc)
{
  WRITE_RD(sext32(insn.i_imm() == 9 ? lp_start : lc));
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

static unsigned ar_set_n(insn_t insn) { return insn.rd() & 3; }
static unsigned ar_imm_n(insn_t insn) { return insn.i_imm() & 3; }

static void ar_step(unsigned n) { ar_addr[n] += (uint32_t)(int32_t)ar_stride[n]; }

static reg_t x_ar_set(processor_t* p, insn_t insn, reg_t pc)
{
  ar_addr[ar_set_n(insn)] = (uint32_t)RS1;
  return pc + 4;
}

static reg_t x_ar_cfg(processor_t* p, insn_t insn, reg_t pc)
{
  ar_stride[ar_set_n(insn)] = (int16_t)(RS1 & 0xFFFF);
  return pc + 4;
}

static reg_t x_lh_a(processor_t* p, insn_t insn, reg_t pc)
{
  unsigned n = ar_imm_n(insn);
  reg_t v = MMU.load<int16_t>(ar_addr[n]);   // traps before the step if misaligned
  WRITE_RD(sext32(v));
  ar_step(n);
  return pc + 4;
}

static reg_t x_lw_a(processor_t* p, insn_t insn, reg_t pc)
{
  unsigned n = ar_imm_n(insn);
  reg_t v = MMU.load<int32_t>(ar_addr[n]);
  WRITE_RD(sext32(v));
  ar_step(n);
  return pc + 4;
}

static reg_t x_lhu_a(processor_t* p, insn_t insn, reg_t pc)
{
  unsigned n = ar_imm_n(insn);
  reg_t v = MMU.load<uint16_t>(ar_addr[n]);
  WRITE_RD(v);
  ar_step(n);
  return pc + 4;
}

static reg_t x_ar_rd(processor_t* p, insn_t insn, reg_t pc)
{
  unsigned n = ar_imm_n(insn);
  WRITE_RD(insn.i_imm() & 4 ? sext32((int32_t)ar_stride[n]) : sext32(ar_addr[n]));
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
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return "ar" + std::to_string(ar_set_n(insn)); }
} xar_rd;
struct : public arg_t {
  std::string to_string(insn_t insn) const override { return "ar" + std::to_string(ar_imm_n(insn)); }
} xar_imm;

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
      {0x0000002B, 0xFFF07E7F, ALL(x_ar_set)},
      {0x0200002B, 0xFFF07E7F, ALL(x_ar_cfg)},
      {0x0000102B, 0xFFCFF07F, ALL(x_lh_a)},
      {0x0000202B, 0xFFCFF07F, ALL(x_lw_a)},
      {0x0000502B, 0xFFCFF07F, ALL(x_lhu_a)},
      {0x0000302B, 0xFF8FF07F, ALL(x_ar_rd)},
      {0x8000000B, 0xFE007FFF, ALL(x_mac_lp)},
      {0x8200000B, 0xFE007FFF, ALL(x_dmac_lp)},
      {0x8400000B, 0xFE007FFF, ALL(x_msu_lp)},
      {0x0000602B, 0xFFF07FFF, ALL(x_lp_setup)},
      {0x0000702B, 0xFFFFFFFF, ALL(x_lp_end)},
      {0x0400002B, 0xFFF07F7F, ALL(x_lp_set)},
      {0x0080302B, 0xFFEFF07F, ALL(x_lp_rd)},
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
      new disasm_insn_t("ar.set",  0x0000002B, 0xFFF07E7F, {&xar_rd, &xrs1}),
      new disasm_insn_t("ar.cfg",  0x0200002B, 0xFFF07E7F, {&xar_rd, &xrs1}),
      new disasm_insn_t("lh.a",    0x0000102B, 0xFFCFF07F, {&xrd, &xar_imm}),
      new disasm_insn_t("lw.a",    0x0000202B, 0xFFCFF07F, {&xrd, &xar_imm}),
      new disasm_insn_t("lhu.a",   0x0000502B, 0xFFCFF07F, {&xrd, &xar_imm}),
      new disasm_insn_t("ar.rd",   0x0000302B, 0xFFCFF07F, {&xrd, &xar_imm}),
      new disasm_insn_t("ar.rds",  0x0040302B, 0xFFCFF07F, {&xrd, &xar_imm}),
      new disasm_insn_t("mac.lp",  0x8000000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("dmac.lp", 0x8200000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("msu.lp",  0x8400000B, 0xFE007FFF, {&xrs1, &xrs2}),
      new disasm_insn_t("lp.setup", 0x0000602B, 0xFFF07FFF, {&xrs1}),
      new disasm_insn_t("lp.end",  0x0000702B, 0xFFFFFFFF, {}),
      new disasm_insn_t("lp.set",  0x0400002B, 0xFFF07FFF, {&xrs1}),
      new disasm_insn_t("lp.sets", 0x040000AB, 0xFFF07FFF, {&xrs1}),
      new disasm_insn_t("lp.rd",   0x0080302B, 0xFFFFF07F, {&xrd}),
      new disasm_insn_t("lp.rds",  0x0090302B, 0xFFFFF07F, {&xrd}),
    };
  }

  void reset(processor_t &) override
  {
    acc = 0;
    for (int i = 0; i < 4; i++) { ar_addr[i] = 0; ar_stride[i] = 0; }
    lc = 0;
    lp_start = 0;
  }
};

REGISTER_EXTENSION(xbrvdsp, []() { static xbrvdsp_t ext; return &ext; })
