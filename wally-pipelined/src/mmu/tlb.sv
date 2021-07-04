///////////////////////////////////////////
// tlb.sv
//
// Written: jtorrey@hmc.edu 16 February 2021
// Modified: kmacsaigoren@hmc.edu 1 June 2021
//            Implemented SV48 on top of SV39. This included adding the SvMode signal,
//            and using it to decide the translate signal and get the virtual page number
//
// Purpose: Translation lookaside buffer
//          Cache of virtural-to-physical address translations
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, 
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software 
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES 
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT 
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

/**
 * SV32 specs
 * ----------
 * Virtual address [31:0] (32 bits)
 *    [________________________________]
 *     |--VPN1--||--VPN0--||----OFF---|
 *         10        10         12
 * 
 * Physical address [33:0] (34 bits)
 *  [__________________________________]
 *   |---PPN1---||--PPN0--||----OFF---|
 *        12         10         12
 * 
 * Page Table Entry [31:0] (32 bits)
 *    [________________________________]
 *     |---PPN1---||--PPN0--|||DAGUXWRV
 *          12         10    ^^
 *                         RSW(2) -- for OS
 */

`include "wally-config.vh"

// The TLB will have 2**ENTRY_BITS total entries
module tlb #(parameter ENTRY_BITS = 3,
             parameter ITLB = 0) (
  input logic              clk, reset,

  // Current value of satp CSR (from privileged unit)
  input logic  [`XLEN-1:0] SATP_REGW,
  input logic              STATUS_MXR, STATUS_SUM, STATUS_MPRV,
  input logic  [1:0]       STATUS_MPP,

  // Current privilege level of the processeor
  input logic  [1:0]       PrivilegeModeW,

  // 00 - TLB is not being accessed
  // 1x - TLB is accessed for a read (or an instruction)
  // x1 - TLB is accessed for a write
  // 11 - TLB is accessed for both read and write
  input logic [1:0]        TLBAccessType,
  input logic              DisableTranslation,

  // Virtual address input
  input logic  [`XLEN-1:0] VirtualAddress,

  // Controls for writing a new entry to the TLB
  input logic  [`XLEN-1:0] PTEWriteVal,
  input logic  [1:0]       PageTypeWriteVal,
  input logic              TLBWrite,

  // Invalidate all TLB entries
  input logic              TLBFlush,

  // Physical address outputs
  output logic [`PA_BITS-1:0] PhysicalAddress,
  output logic             TLBMiss,
  output logic             TLBHit,

  // Faults
  output logic             TLBPageFault
);

  localparam NENTRIES = 2**ENTRY_BITS;

  logic Translate;
  logic TLBAccess, ReadAccess, WriteAccess;

  // Store current virtual memory mode (SV32, SV39, SV48, ect...)
  logic [`SVMODE_BITS-1:0] SvMode;
  logic  [1:0]       EffectivePrivilegeMode; // privilege mode, possibly modified by MPRV

  //logic [ENTRY_BITS-1:0] WriteIndex;
  logic [NENTRIES-1:0] ReadLines, WriteLines, WriteEnables; // used as the one-hot encoding of WriteIndex

  // Sections of the virtual and physical addresses
  logic [`VPN_BITS-1:0] VirtualPageNumber;
  logic [`PPN_BITS-1:0] PhysicalPageNumber, PhysicalPageNumberMixed;
  logic [`PA_BITS-1:0]  PhysicalAddressFull;
  logic [`XLEN+1:0]     VAExt;

  // Sections of the page table entry
  logic [7:0]           PTEAccessBits;
  logic [11:0]          PageOffset;

  // Useful PTE Control Bits
  logic PTE_U, PTE_X, PTE_W, PTE_R;

  // Pattern location in the CAM and type of page hit
  //ogic [ENTRY_BITS-1:0] VPNIndex;
  logic [1:0]            HitPageType;

  // Whether the virtual address has a match in the CAM
  logic                  CAMHit;

  // Grab the sv mode from SATP and determine whether translation should occur
  assign SvMode = SATP_REGW[`XLEN-1:`XLEN-`SVMODE_BITS];
  assign EffectivePrivilegeMode = (ITLB == 1) ? PrivilegeModeW : (STATUS_MPRV ? STATUS_MPP : PrivilegeModeW); // DTLB uses MPP mode when MPRV is 1
  assign Translate = (SvMode != `NO_TRANSLATE) & (EffectivePrivilegeMode != `M_MODE) & ~ DisableTranslation; 

  // Decode the integer encoded WriteIndex into the one-hot encoded WriteLines
  //decoder #(ENTRY_BITS) writedecoder(WriteIndex, WriteLines);
  assign WriteEnables = WriteLines & {(2**ENTRY_BITS){TLBWrite}};

  // The bus width is always the largest it could be for that XLEN. For example, vpn will be 36 bits wide in rv64
  // this, even though it could be 27 bits (SV39) or 36 bits (SV48) wide. When the value of VPN is narrower,
  // is shorter, the extra bits are used as padded zeros on the left of the full value.
  generate
    if (`XLEN == 32) begin
      assign VirtualPageNumber = VirtualAddress[`VPN_BITS+11:12];
    end else begin
      assign VirtualPageNumber = (SvMode == `SV48) ?
                                 VirtualAddress[`VPN_BITS+11:12] :
                                 {{`VPN_SEGMENT_BITS{1'b0}}, VirtualAddress[3*`VPN_SEGMENT_BITS+11:12]};
    end
  endgenerate

 
  // Determine how the TLB is currently being used
  // Note that we use ReadAccess for both loads and instruction fetches
  assign ReadAccess = TLBAccessType[1];
  assign WriteAccess = TLBAccessType[0];
  assign TLBAccess = ReadAccess || WriteAccess;


  // TLB entries are evicted according to the LRU algorithm
  tlblru #(ENTRY_BITS) lru(.*);

  // TLB memory
  tlbram #(ENTRY_BITS) tlbram(.*);
  tlbcam #(ENTRY_BITS, `VPN_BITS, `VPN_SEGMENT_BITS) tlbcam(.*);

  // Replace segments of the virtual page number with segments of the physical
  // page number. For 4 KB pages, the entire virtual page number is replaced.
  // For superpages, some segments are considered offsets into a larger page.
  tlbphysicalpagemask PageMask(VirtualPageNumber, PhysicalPageNumber, HitPageType, PhysicalPageNumberMixed);

  // unswizzle useful PTE bits
  assign {PTE_U, PTE_X, PTE_W, PTE_R} = PTEAccessBits[4:1];
 
  // Check whether the access is allowed, page faulting if not.
  generate
    if (ITLB == 1) begin
      logic ImproperPrivilege;

      // User mode may only execute user mode pages, and supervisor mode may
      // only execute non-user mode pages.
      assign ImproperPrivilege = ((EffectivePrivilegeMode == `U_MODE) && ~PTE_U) ||
        ((EffectivePrivilegeMode == `S_MODE) && PTE_U);
      assign TLBPageFault = Translate && TLBHit && (ImproperPrivilege || ~PTE_X);
    end else begin
      logic ImproperPrivilege, InvalidRead, InvalidWrite;

      // User mode may only load/store from user mode pages, and supervisor mode
      // may only access user mode pages when STATUS_SUM is low.
      assign ImproperPrivilege = ((EffectivePrivilegeMode == `U_MODE) && ~PTE_U) ||
        ((EffectivePrivilegeMode == `S_MODE) && PTE_U && ~STATUS_SUM);
      // Check for read error. Reads are invalid when the page is not readable
      // (and executable pages are not readable) or when the page is neither
      // readable nor executable (and executable pages are readable).
      assign InvalidRead = ReadAccess && ~PTE_R && (~STATUS_MXR | ~PTE_X);
      // Check for write error. Writes are invalid when the page's write bit is
      // low.
      assign InvalidWrite = WriteAccess && ~PTE_W;
      assign TLBPageFault = Translate && TLBHit && (ImproperPrivilege || InvalidRead || InvalidWrite);
    end
  endgenerate


  // Output the hit physical address if translation is currently on.
  // Provide physical address of zero if not TLBHits, to cause segmentation error if miss somehow percolated through signal
  assign VAExt = {2'b00, VirtualAddress}; // extend length of virtual address if necessary for RV32
  assign PageOffset = VirtualAddress[11:0];
  assign PhysicalAddressFull = TLBHit ? {PhysicalPageNumberMixed, PageOffset} : '0;
  mux2 #(`PA_BITS) addressmux(VAExt[`PA_BITS-1:0], PhysicalAddressFull, Translate, PhysicalAddress);

  assign TLBHit = CAMHit & TLBAccess;
  assign TLBMiss = ~TLBHit & ~TLBFlush & Translate & TLBAccess;
endmodule
