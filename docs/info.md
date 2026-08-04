## How it works

ZIRH is a radiation-hardening experiment SoC on SKY130. A TMR-protected SERV
(RV32I, bit-serial) core runs housekeeping firmware from mask ROM, controls
the peripherals over a lightweight bus, and streams SEU statistics out as
UART telemetry.

## Block Diagram

```
                 ┌─────────────────────────────────────────────────┐
                 │                 tt_um_hma_zirh                  │
  clk ──►┌───────┴──────┐                                          │
  rst_n─►│ zirh_clk_rst │ (TMR)                                    │
         └───────┬──────┘                                          │
                 │ div. clk                                        │
   ┌─────────────┴───────────── zirh_bus (Wishbone-lite) ────────┐ │
   │        │         │        │        │       │        │       │ │
┌──┴───┐ ┌──┴───┐ ┌───┴──┐ ┌───┴───┐ ┌──┴──┐ ┌──┴───┐ ┌──┴────┐  │ │
│ SERV │ │ ROM  │ │ RAM  │ │RS422/ │ │ CAN │ │ SPW  │ │ NPU   │  │ │
│(TMR) │ │(mask)│ │+ECC  │ │UART   │ │ctrl │ │lite  │ │int8MAC│  │ │
└──────┘ └──────┘ └──────┘ └──┬────┘ └──┬──┘ └──┬───┘ └───────┘  │ │
                              │         │       │                │ │
   ┌──────────────┐  ┌────────┴─────┐   │       │                │ │
   │ zirh_seu_mon │  │ zirh_sram_dut│   ▼       ▼                │ │
   │ FF chains,   │  │ OpenRAM macro│  CAN_TX  SPW_DOUT/SOUT     │ │
   │ counters     │  │ + scan FSM   │  CAN_RX  SPW_DIN/SIN       │ │
   └──────────────┘  └──────────────┘                            │ │
                 └───────────────────────────────────────────────┘ │
                 └─────────────────────────────────────────────────┘
```

## Memory Map

| Base       | Size | Block         | Notes                          |
|------------|------|---------------|--------------------------------|
| 0x0000_0000| 2 KB | ROM           | firmware (mask ROM, case-gen)  |
| 0x0000_1000| 256B | RAM           | ECC-protected DFF RAM          |
| 0x0000_2000| 32B  | UART/RS422    | data, status, baud div         |
| 0x0000_2100| 64B  | CAN           | ctrl, status, TX/RX buffers    |
| 0x0000_2200| 64B  | SpaceWire     | link ctrl/status, data         |
| 0x0000_2300| 64B  | NPU           | weights, activations, result   |
| 0x0000_2400| 64B  | SEU monitor   | counters, inject, mode         |
| 0x0000_2500| 64B  | SRAM DUT      | scan ctrl, flip count/addr log |

## How to test

(reset → HEARTBEAT toggles → telemetry frames on TLM_TX @115200 8N1 ...)
