# Hardware Notes

## Slot Assignments

| Slot | Card | Purpose |
|------|------|---------|
| 0 | Garrett's Workshop 128K | Persistent IP config storage (optional) |
| 2 | Uthernet II (W5100S) | TCP/IP networking |
| 3 | Videx Ultraterm Rev C | 80-column terminal display |

These slot assignments are **hardcoded** in the assembly source. The Uthernet II base address is `$C0A4` (Slot 2) and the Ultraterm CRTC is at `$C0B0` (Slot 3). Changing slots requires updating all hardware constants.

## Tested Configurations

- **Apple II Rev 3** — Primary development target. NMOS 6502 (no `BRA`, no `STZ`, no `PHX`/`PLX`).
- **Apple IIe** — Also works. The 65C02 instructions are intentionally avoided for Rev 3 compatibility.
- **AppleWin** — Used for development and testing before deploying to real hardware.

## W5100 Register Map (Uthernet II, Slot 2)

| Apple II Address | W5100 Function |
|---|---|
| `$C0A4` | Mode Register (write `$80` to reset, `$03` for indirect+auto-increment) |
| `$C0A5` | IDM Address Register High |
| `$C0A6` | IDM Address Register Low |
| `$C0A7` | IDM Data Port |

The code uses indirect mode with auto-increment. After writing the address to AR0/AR1, sequential reads/writes to the data port automatically advance through memory.

## Videx Ultraterm (Slot 3)

| Apple II Address | Function |
|---|---|
| `$C0B0` | CRTC 6845 Register Select |
| `$C0B1` | CRTC 6845 Data |
| `$C0B2` | Mode Control Port — write `($D0 \| bank)` to select 256-byte page |
| `$C300` | Bank-in / Init (JSR to initialize 80x24 mode) |
| `$CC00` | Screen RAM base (256 bytes visible per bank, 8 banks) |

Screen memory is **banked** — the 80×24 display (1920 characters) spans 8 banks of 256 bytes each. To write a character, you first select the correct bank via the Mode Control Port, then write to the offset within `$CC00–$CCFF`.

## Garrett's Workshop 128K (Slot 0)

Used only for persistent IP configuration storage:

| Address | Purpose |
|---|---|
| `$D000–$D003` | Saved server IP (4 bytes) |
| `$D004–$D005` | Magic number (`$A5`, `$5A`) — indicates valid config |

The language card soft-switches (`$C083` read twice to enable R/W, `$C082` to restore ROM) gate access to this memory.

## The `$C800` Bus Conflict

The Apple II has a single shared expansion ROM space at `$C800–$CFFF`. Both the Uthernet II and the Videx Ultraterm map their firmware here. Accessing one card's I/O can silently bank in that card's ROM, displacing the other.

**The fix**: Before any Videx screen writes after network I/O, the code executes:
```
BIT $CFFF       ; Release the $C800 space
BIT $C300       ; Re-bank the Videx Ultraterm
```

This is done on every iteration of the async chat loop.

## ROMX Compatibility

ROMX replaces the Apple II's keyboard and video I/O vectors with its own firmware hooks. These conflict with Uthernet II slot I/O. The `START` routine neutralizes this:

```
JSR $FE89       ; SETKBD — force keyboard to motherboard ROM
JSR $FE93       ; SETVID — force video to motherboard ROM
```

The HGR2 boot screen also includes a deliberate keyboard debounce delay at startup to absorb any phantom keypresses from ROMX's menu system.
