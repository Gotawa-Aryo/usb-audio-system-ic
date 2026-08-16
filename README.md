# USB Audio System IC

Single-chip USB-to-audio interface for the SSCS Chipathon 2026, targeting the GlobalFoundries 180nm MCU PDK (gf180mcuD). The chip enumerates as a USB Audio Class 1.0 device over full speed (12 Mbps) and converts the received stereo stream into a 1-bit delta-sigma bitstream for an external analog front end.

Team XLR8. Top module `ic_top_usb_audio`.

## Attribution

The main reference for this project is WangXuan95's FPGA-USB-Device, https://github.com/WangXuan95/FPGA-USB-Device (Apache-2.0).

Our code is still using their work. The USB full-speed device core is theirs, and `usb_audio_top.v` is their audio top with an async FIFO read port added on our side. The USB string descriptors in `usb_audio_top.v` still report "github.com/WangXuan95" and "FPGA-USB-audio" because we have not replaced them yet. We are on our way to a custom device, so the next iterations replace the borrowed core and its descriptors with our own USB front end.

| Module | Origin |
|--------|--------|
| `usbfs_bitlevel.v` | FPGA-USB-Device |
| `usbfs_core_top.v` | FPGA-USB-Device |
| `usbfs_packet_rx.v` | FPGA-USB-Device |
| `usbfs_packet_tx.v` | FPGA-USB-Device |
| `usbfs_transaction.v` | FPGA-USB-Device |
| `usb_audio_top.v` | FPGA-USB-Device, extended with the async FIFO read side |
| `async_fifo.v` | XLR8 |
| `oversampling_trigger.v` | XLR8 |
| `first_order_dfe.v` | XLR8 |
| `rtl_adder_block.v`, `rtl_difference_block.v`, `rtl_digital_shifter.v` | XLR8 |
| `ic_top_usb_audio.v` | XLR8 |

The repository infrastructure (Nix flake, LibreLane slots, padring, Makefile) is a fork of the wafer-space `gf180mcu-project-template` with Juan Moya's workshop padring. See `CREDITS.md`, `NOTICE`, and `AUTHORS.md` for the per-artifact attribution.

## Signal path

USB D+/D- go into the full-speed core, decoded samples land in an async FIFO, and a 48 kHz trigger drains the FIFO into a first-order delta-sigma modulator that drives one output pin.

- USB full speed (12 Mbps), UAC 1.0, stereo 16-bit at 48 kHz
- VID and PID both 0xFB9A, isochronous IN endpoint 0x82 (192 byte packets, 2 channels x 2 bytes x 48 samples) and isochronous OUT endpoint 0x01
- Async FIFO 32 bits wide (16-bit left plus 16-bit right), 16 entries, gray-code pointers with 2-flop synchronizers
- Sample trigger from the 60 MHz clock divided by 1250, giving 48 kHz
- First-order delta-sigma modulator on an 18-bit accumulator, oversampling ratio 1250
- `bitstream_out` is 1 bit and drives an off-chip low-pass filter, buffer, and power amplifier

### Pins

| Pin | Direction | Function |
|-----|-----------|----------|
| `clk60mhz` | input | 60 MHz clock source, required by the USB core |
| `reset_n` | input | active-low external reset |
| `usb_dp`, `usb_dn` | inout | USB D+ and D- |
| `usb_dp_pull` | output | drives D+ through a 1.5k resistor for full-speed detection |
| `bitstream_out` | output | 1-bit delta-sigma output to the AFE |

## Physical implementation

Hardened with LibreLane 3.0.4 on gf180mcuD, standard cell library `gf180mcu_fd_sc_mcu7t5v0`, routing on Metal2 through Metal5, single 5.0 V VDD/VSS domain.

| Metric | Value |
|--------|-------|
| Die area | 1436 x 1454 um (2.09 mm2) |
| Core utilization | 62.8% |
| Standard cells | 46,420 |
| Total instances | 101,777 (including fill, decap, and tap) |
| Routed wirelength | 2.23 m |
| Total power | 33.8 mW |
| Magic DRC | 0 violations |
| Routing DRC | 0 violations |
| LVS | 0 mismatches |
| GDS XOR difference | 0 |
| Hold worst slack | +8.94 ns |

Signoff views are committed under `layout/`, including GDS, DEF, LEF, SPICE, powered netlist, SPEF and SDF for 9 corners, and a rendered PNG in `layout/render/`.

## Known issues

- Setup timing fails at the three slow corners, worst slack -1.30 ns at `max_ss_125C_4v50`. The typical and fast corners pass at +3.34 ns and +5.31 ns.
- 16,411 max-slew and 196 max-cap violations remain open.
- 2 nets still report antenna violations.
- `ic_top_usb_audio.v` ties the USB core `rstn` to `1'b1`, so `reset_n` reaches only the FIFO read side, the trigger, and the modulator. The USB block does not reset with the rest of the chip.
- The FIFO write side runs on the same 60 MHz clock as the read side at this level, so the clock-domain crossing is present in the RTL but not yet exercised.

## Build

The digital core layout under `layout/` was hardened from `src/config.json`, which is a standalone LibreLane configuration with `DESIGN_NAME` set to `ic_top_usb_audio`. It does not run from this repository's Makefile.

The Makefile drives the padring template flow, which builds `chip_top` rather than the digital core.

```bash
nix-shell
make clone-pdk
SLOT=workshop make librelane
```

Other useful targets are `make sim` (cocotb RTL simulation), `make librelane-klayout` (open the last run in KLayout), and `make render-image`. See `docs/reproducing-native.md` and `docs/reproducing-docker.md`.

## LVS

`lvs_config.json` at the repository root configures the chipathon KLayout LVS flow. It compares `layout/gds/ic_top_usb_audio.gds` against the powered netlist `layout/pnl/ic_top_usb_audio.pnl.v`. The design is flat with no macros, so the flatten, abstract, and ignore lists are empty. `info.yaml` points at this file.

## Repository layout

```
.
|-- lvs_config.json                 # chipathon LVS flow config
|-- info.yaml                       # chipathon project metadata
|-- src/
|   |-- config.json                 # LibreLane config for the digital core
|   |-- digital_design/             # USB audio RTL (13 Verilog files)
|   |-- chip_top.sv                 # padring template top
|   |-- chip_core.sv                # padring template core
|   `-- slot_defines.svh            # slot pad counts
|-- layout/                         # signoff views for ic_top_usb_audio
|-- librelane/                      # padring flow config and slot definitions
|-- ip/                             # wafer-space ID and logo macros
|-- scripts/                        # padring, image render, docker launcher
|-- cocotb/                         # RTL and gate-level testbench
`-- docs/                           # padring slot spec and reproduction guides
```

## License

Apache-2.0. See `LICENSE` for the full text and `NOTICE` for third-party attribution.
