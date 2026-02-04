AXI Dual-Port Multi-Clock BRAM

AXI4 Memory-Mapped True Dual-Port Scratchpad RAM

Version: 1.0
Author: Eric

1. Overview

This module implements a synthesizable, IP-style True Dual-Port Block RAM with two fully independent AXI4 Memory-Mapped slave interfaces, each operating in its own clock domain.

It is designed as a low-latency shared scratchpad memory for:

DMA engines

AI / ML accelerator cores

Multi-clock SoC subsystems

Each AXI port connects directly to one side of the memory without requiring any explicit CDC logic between ports.

2. Key Features
✔ True Dual-Port, Multi-Clock Operation

Port 0: AXI-MM Slave in dma_clk domain

Port 1: AXI-MM Slave in core_clk domain

Fully independent read and write paths per port

No cross-domain handshake or FIFO required

Intended to infer FPGA True Dual-Port BRAM (TDP RAM)

Each port behaves as a standalone AXI slave connected to a shared memory array.

✔ AXI4 Memory-Mapped Interface

Each port implements a complete AXI4-MM slave interface:

AW, W, B, AR, R channels

Byte-wise write enable via WSTRB

AXI burst support (configurable; see Parameters)

AXI response signaling (OKAY / SLVERR)

One AXI master per port is assumed. Arbitration between multiple masters must be handled externally.

✔ Simulation-Oriented Safety Checks (Non-Synthesizable)

The following mechanisms are intended for verification and debug only and may be excluded or simplified in synthesis:

Write-Write conflict detection

Detects same-byte writes from both ports in the same cycle

Read-After-Write forwarding (cross-port)

Ensures deterministic read behavior in simulation

Starvation monitoring

Warns if one port is permanently blocked by the other

✔ Parameterized Design
Parameter	Description
DATA_WIDTH	Data width per word (32 / 64 / 128 bits)
ADDR_WIDTH	AXI address width
DEPTH_WORDS	Memory depth in words
ID_WIDTH	AXI transaction ID width
3. Architecture Overview
                +-------------------------------+
   dma_clk ---> |  AXI-MM Slave Port 0          |
                |    (frontend logic)           |
                +---------------+---------------+
                                |
                                | Port 0 Access
                                v
                      +-------------------+
                      | True Dual-Port    |
                      | BRAM Memory       |
                      | (byte-addressable)|
                                ^
                                |
                +---------------+---------------+
   core_clk --> |  AXI-MM Slave Port 1          |
                |    (frontend logic)           |
                +-------------------------------+


The memory array is implemented as a byte-addressable structure:

logic [7:0] mem_byte [0:DEPTH_BYTES-1];


This enables:

Byte-granular WSTRB writes

Per-byte conflict detection

Clean inference of true dual-port BRAM resources

4. Multi-Clock Behavior
✔ Independent Clock Domains

dma_clk drives Port 0

core_clk drives Port 1

Clocks may be unrelated in frequency and phase

No explicit CDC logic is implemented between the ports.

✔ Memory Coherency Model

This design assumes a True Dual-Port RAM primitive where:

Each port has its own clock

The memory hardware resolves internal read/write timing

On FPGAs, this maps naturally to vendor-provided TDP BRAM blocks.

Important note:
Cross-port read/write ordering is deterministic only within the guarantees provided by the underlying RAM primitive and the implemented forwarding logic (if enabled in simulation).

✔ Hazard Handling Rules
Condition	Handling
Write-After-Write (same byte, same cycle)	Detected → SLVERR (simulation)
Read-After-Write (cross-port)	Forwarded data returned (simulation)
Starvation	Warning issued after configurable timeout

These checks are intended to catch system-level integration bugs early.

5. Design Assumptions

This module assumes:

AXI masters follow the AXI4 protocol correctly

Proper VALID/READY handshakes

Well-formed bursts (no malformed AxLEN)

WSTRB aligns with DATA_WIDTH

One AXI master per port

Clock assumptions:

dma_clk and core_clk are stable

No excessive jitter or glitching

6. Design Guarantees

This module guarantees:

Correct dual-port shared-memory semantics

Independent AXI-MM operation per port

Deterministic behavior within the defined hazard rules

No explicit CDC paths between clock domains

Fully synthesizable RTL (excluding optional debug logic)

7. Integration Guide
7.1 Typical DMA + Accelerator Integration
       External DRAM
           |
       +-----------+
       | AXI DMA   |
       +-----------+
              |
              | AXI-MM (dma_clk)
              v
        +----------------+
        |  Port 0        |
        |  AXI BRAM IP   |
        |                |
        |                | AXI-MM (core_clk)
        |                v
        |         Accelerator Core
        +----------------+

Port 0 (dma_clk)

Typical usage:

DMA engines (MM2S / S2MM)

CPU or SoC AXI masters

Port 1 (core_clk)

Typical usage:

Accelerator reads (inputs / weights)

Intermediate result storage

Partial accumulation buffers

7.2 Addressing Scheme

AXI addresses are byte addresses

Internal word index calculation:

WORD_INDEX = AXI_ADDR >> $clog2(DATA_WIDTH / 8)


Example (DATA_WIDTH = 64):

AXI Address = 0x20
WORD_INDEX = 0x20 >> 3 = 0x4

8. Error Conditions
Condition	Detection	Response
Same-byte write conflict	Yes	SLVERR + sim error
Burst crosses memory boundary	Optional	SLVERR
Misaligned AXI address	Optional	SLVERR
Port starvation	Yes	Simulation warning
9. Recommended Use Cases

This BRAM is well suited for:

Small tensor tiles

Weight blocks

Line buffers

Sliding-window storage

DMA ↔ Core clock decoupling

Common targets:

CNN / RNN / Transformer accelerators

Systolic arrays

MAC clusters

10. Possible Future Extensions

ECC / SECDED

Parity per byte

AXI QoS or priority support

Performance counters

Burst repacking / prefetch buffers

11. License

MIT License