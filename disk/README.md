# Disk Image Files

## STARTUP

The `STARTUP` file is an Applesoft BASIC program that auto-runs `APPLE2AI.BIN`:

```basic
10  PRINT CHR$(4);"BRUN APPLE2AI.BIN"
```

When placed on a DOS 3.3 or ProDOS disk as the `STARTUP` (or `HELLO`) program, the Apple II will automatically launch the chat client on boot.

## Building a Disk Image

### Using CiderPress (Windows)

1. Open CiderPress and create a new **DOS 3.3** disk image (140K `.dsk`).
2. Add `APPLE2AI.BIN` as type **B** (Binary), load address **$0800**.
3. Add `STARTUP` as type **A** (Applesoft BASIC).
4. In disk options, set `STARTUP` as the boot program.

### Using AppleCommander (Cross-platform)

```bash
# Create a blank DOS 3.3 disk
java -jar AppleCommander.jar -d33 apple2ai.dsk

# Add the binary (type B, address $0800)
java -jar AppleCommander.jar -p apple2ai.dsk APPLE2AI.BIN B 0x0800 < build/APPLE2AI.BIN

# Add the startup program
java -jar AppleCommander.jar -p apple2ai.dsk STARTUP A < disk/STARTUP
```

### Using `ac` (AppleCommander CLI)

```bash
ac -d33 apple2ai.dsk
ac -p apple2ai.dsk CHATV8.BIN B 0x0800 < build/APPLE2AI.BIN
```

## Transfer Methods

- **ADTPro** — Serial or ethernet transfer to real hardware
- **FloppyEmu** — Copy `.dsk` to SD card
- **BOOTI** — USB-based disk emulator
- **ROMX** — Load binary directly from ROMX SD card menu
