AXI Dual-Port Multi-Clock BRAM
High-Performance AXI4 Memory-Mapped Scratchpad RAM

Version: 1.0
Author: Eric
Description:
This module implements a synthesizable, IP-like Dual-Port Block RAM with 2 fully independent AXI4 Memory-Mapped slave interfaces, operating under two independent clock domains.
It is intended to serve as a low-latency scratchpad memory for DMA engines, AI/ML accelerators, or other multi-clock SoC subsystems.

1. Features
✔ True Dual-Port RAM

Port 0 (AXI Slave): dma_clk domain

Port 1 (AXI Slave): core_clk domain

2 fully independent read/write pipes

No cross-domain handshake required

Synthesizes into FPGA True-Dual-Port BRAM

✔ AXI4-Lite / AXI4-MM Compatible

Each port contains a complete AXI-MM slave with:

AR, AW, W, R, B channels

Write strobe (WSTRB) supporting byte-wise writes

Burst length (AxLEN) support (depending on config)

✔ Simulation-Only Safety Checking

Write-Write Conflict Detection
When both ports attempt to write the same byte in the same cycle.

Read-After-Write Forwarding
Ensures deterministic read behavior across ports.

Starvation Monitor
Detects if either port is permanently blocked from memory access.

✔ Configurable Parameters
Parameter	Description
DATA_WIDTH	32 / 64 / 128-bit
ADDR_WIDTH	Address bit width
DEPTH_WORDS	Memory depth in words
ID_WIDTH	AXI transaction ID width
2. Architecture Overview
                +-------------------------------+
   dma_clk ---> |  AXI-MM Slave Port 0          |
                |    (frontend logic)           |
                +---------------+---------------+
                                |
                                | Port 0 Access
                                v
                      +-------------------+
                      |  TDP BRAM Memory  |
                      | (byte-addressable)|
                                ^
                                |
                +---------------+---------------+
   core_clk --> |  AXI-MM Slave Port 1          |
                |    (frontend logic)           |
                +-------------------------------+


The memory block is implemented as:

logic [7:0] mem_byte [0:DEPTH_BYTES-1];


This allows:

Byte-granular WSTRB writes

Clean conflict detection

FPGA to infer true dual-port BRAM cells

3. Multi-Clock Behavior
✔ Independent clock domains

dma_clk drives Port 0

core_clk drives Port 1

Ports may operate at completely unrelated frequencies and phases

No CDC logic is needed between ports

✔ Internal BRAM is naturally multi-clock safe

True Dual-Port BRAM hardware structures internally arbitrate read/write hazards and maintain coherence without additional CDC logic.

Thus, the module does NOT require async FIFO or synchronizers between the ports —
the underlying memory fabric guarantees correctness.

✔ Hazard resolution rules

Write-After-Write (WAW) conflict on the same byte (same cycle)

Detect → raise SLVERR + simulation error message

Both sides receive valid BRESP

Read-After-Write across ports (RAW, cross-domain)

Read returns newly written data immediately (forwarding)

Guarantees deterministic accelerator behavior

Write starvation

If one port monopolizes access, starvation detector fires after N cycles

4. Assumptions

This BRAM assumes:

AXI masters behave according to AXI4 protocol

AWVALID/WVALID handshake correctly

No malformed bursting

WSTRB follows byte-aligned patterns

Only 1 AXI master per port
(Each port is a slave interface; upstream arbitration must be done externally)

Clock domains are stable
dma_clk and core_clk must be free from excessive jitter or glitching.

FPGA / ASIC synthesis infers or maps memory correctly
Most FPGA tools infer TDP BRAM automatically.

5. Guarantees
This module guarantees:

Functionally correct dual-port shared-memory semantics

Deterministic read-after-write

Conflict detection and SLVERR reporting

No cross-domain metastability

Synthesizable and timing-clean design

6. Integration Guide
6.1 Typical Integration with DMA + AI Core
       DRAM                AXI-MM
   +-----------+        +---------+
   | AXI DMA   |------->|  Port 0 |
   +-----------+        | (dma_clk)
                        | BRAM IP |
                        |         |-------> Accelerator Core
                        |         |         (AXI-MM Port 1, core_clk)
                        +---------+

Port 0 (dma_clk)

Used where memory is filled or drained by:

AXI DMA Engines

CPU/SoC AXI Masters

MM2S (Memory-to-Stream)

S2MM (Stream-to-Memory)

Port 1 (core_clk)

Used by accelerator logic to:

Read input feature maps

Read weight blocks

Write intermediate results

Possibly store partial accumulations

6.2 Addressing Scheme
BYTE ADDRESS = word address * (DATA_WIDTH/8)
WORD INDEX   = ARADDR >> $clog2(DATA_WIDTH/8)


Example (DATA_WIDTH=64):

Address 0x20 → word index = 0x20 >> 3 = 0x4

7. Error Conditions
Condition	Detection	Response
Write-Write same-byte same-cycle	yes	SLVERR + simulation error
Bursts crossing memory boundary	optional	SLVERR
Misaligned AXI address	optional	SLVERR
Starvation (port monopolization)	yes	Warning in simulation
8. Recommended Usage in AI/ML Subsystems

This BRAM is ideal for:

Small tensor tiles

Sliding-window storage

Weight blocks

Input activations

Line buffers

Intermediate partial sums

DMA decoupling between SoC domain ↔ Core domain

Because it is:

dual-clock

dual-port

low-latency

AXI-compatible

It is directly usable in:

CNN accelerators

RNN/Transformer tile processors

systolic arrays

MAC clusters

9. Future Extensions

Possible enhancements:

ECC (SECDED)

Parity bits per byte

AXI QoS aware arbitration

Performance counters

Prefetch buffer or burst-repacker

10. License

MIT or proprietary internal (your choice)