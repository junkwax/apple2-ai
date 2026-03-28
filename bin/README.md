# Pre-Built Binaries

Ready-to-run binaries — no cc65 toolchain required.

## Files

| File | Load Address | Description |
|------|-------------|-------------|
| `APPLE2AI.BIN` | `$0800` | Full client: HGR2 boot screen → diagnostics → Ultraterm chat |

## Usage

Transfer `APPLE2AI.BIN` to your Apple II and run:

```
BRUN APPLE2AI.BIN
```

Or set up auto-boot with the `STARTUP` program from `disk/`.

## Loading with CiderPress / AppleCommander

When adding to a disk image, set the file type to **B** (Binary) with load address **$0800** (`2048` decimal).

## Building from Source

If you'd rather compile from source:

```
make
```

The freshly built binary will be in `build/APPLE2AI.BIN`.
