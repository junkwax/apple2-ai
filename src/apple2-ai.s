; ============================================================
;  APPLE ][ AI

;  Target: Apple II (NMOS 6502) | Assembler: ca65
;  Uthernet II Slot 2 / Videx Ultraterm Slot 3 / Garrett's 128K Slot 0
;
; HARDWARE CONSTANTS (VIDEX ULTRATERM MANUAL):
;   CRTC select  : $C0B0
;   CRTC data    : $C0B1
;   Mode Control : $C0B2  write ($D0 | bank) to select 256-byte page
;   Screen base  : $CC00  
;   Init         : JSR $C300 
;
; BUILD:
;   ca65 src/apple2-ai.s -o build/apple2-ai.o
;   ld65 -C apple2chat.cfg build/apple2-ai.o -o build/APPLE2AI.BIN
; ============================================================

        .org $0800

; ============================================================
;  Zero Page Definitions
; ============================================================
PTR_LO      = $00
PTR_HI      = $01
ROW         = $02
COL         = $03
BRIGHT      = $04
GIDX        = $05
WAVE_PHASE  = $06
FRAME       = $07
TMP         = $08
PHASE_BASE  = $09
GLYPH_BASE  = $0A   
COL_OFFSET  = $0B   
SHAD_LO     = $0C
SHAD_HI     = $0D
ROW17       = $0E
PTR_LO_BASE = $0F

H0          = $10
H1          = $11
H2          = $12
H3          = $13
H4          = $14
H5          = $15
H6          = $16
H7          = $17

ESTATE      = $18   ; 0=RAIN 1=REVEAL 2=DRAIN 3=HOLD
RAIN_TMR    = $19   
REVEAL_CNT  = $1A   
FADE_TIMER  = $1E   
MAX_BRIGHT  = $1F   

; ============================================================
;  Hardware Constants
; ============================================================
KBD         = $C000
KBDCLR      = $C010
TXTCLR      = $C050
TXTSET      = $C051
MIXCLR      = $C052
PAGE1       = $C054   ; <-- FIXED: Restored PAGE1 definition
PAGE2       = $C055
HIRES       = $C057

HGR_PAGE    = $2000
GRID_W      = 40
GRID_H      = 24
DIM_MASK    = $55
SENTINEL    = $FF   

; Configuration
TEXT_ROW    = 1     
TEXT_LEN    = 11    
TEXT_COL0   = 14   
REVEAL_ALL  = 11    
RAIN_DELAY  = 5   ; ~12 seconds of full rain
FADE_SPEED  = 7   ; Higher = slower drain

BRIGHT_BUF  = $6000
REVEAL_BUF  = $6400   

; ── Videx Ultraterm hardware (SLOT 3) ─────────────────────────
CRTC_SEL        = $C0B0    ; 6845 register select
CRTC_DAT        = $C0B1    ; 6845 register data
ULTRA_MCP       = $C0B2    ; Mode Control Port
ULTRA_BANKIN    = $C300    ; read/JSR here to init / bank in $CC00 space
ULTRA_DISP      = $CC00    ; screen RAM base address
ULTRA_MCP_MASK  = $D0      ; MPBANK($80) | MPVIDEO($40) | MPADDR($10)

; ── Uthernet II (Slot 2) ──────────────────────────────────────

WBASE           = $C0A4    ; W5100 Mode Register (slot 2)
W_IDM_AR0       = $C0A5    ; Address register high byte
W_IDM_AR1       = $C0A6    ; Address register low byte
W_IDM_DR        = $C0A7    ; Data port

; ── Garrett's 128K language card (Slot 0) ─────────────────────
LC_RD2_WE       = $C083
LC_ROM_WP       = $C082
LC_CONFIG_IP    = $D000
LC_CONFIG_MG    = $D004

; ── W5100 protocol constants ──────────────────────────────────
SCMD_OPEN       = $01
SCMD_CONNECT    = $04
SCMD_SEND       = $20
SCMD_RECV       = $40
SOCK_INIT       = $13
SOCK_ESTAB      = $17
TX_BASE_HI      = $40
RX_BASE_HI      = $60

; ── Apple II ROM ──────────────────────────────────────────────
HOME            = $FC58
COUT            = $FDED
RDKEY           = $FD0C
VTAB_ROM        = $FC22


; ── Zero page ─────────────────────────────────────────────────
ZP_COL    = $E0
ZP_TMP    = $E1
ZP_LO     = $E2
ZP_HI     = $E3
ZP_SLO    = $E4
ZP_SHI    = $E5
NET_LO    = $E6
NET_HI    = $E7
TMP_A     = $08
TMP_B     = $09
TMP_C     = $0A
IP_ACC    = $0B   ; READ_IP_UT octet accumulator
SRV_IP    = $10   ; 4 bytes
UT_ROW    = $14
UT_COL    = $15
FRAME_LO  = $16
FRAME_HI  = $17
CDOWN     = $18   ; Config countdown
CHAT_ROW  = $18   ; Aliased with CDOWN (Chat history row: 0-22)
CHAT_COL  = $19   ; Chat history col: 0-79
INPUT_COL = $1A   ; User typing col: 2-79
SCRL_LO   = $1B   ; Used in ULTRA_SCROLL only
SCRL_HI   = $1C
TX_IDX    = $1D   ; Outgoing chat buffer index
RX_CNT_HI = $1E   ; Async network receive counter High
RX_CNT_LO = $1F   ; Async network receive counter Low

; ── Column state arrays ───────────────────────────────────────
HEAD    = $0200   ; 80 bytes (use 40 for ULTRATERM_RAIN=0)
WAIT    = $0250
SPD     = $02A0
TRL     = $02F0
TXBUF   = $6500   ; Safely moved to high RAM to hold 160 chars


; ============================================================
;  Entry Point & State Machine
; ============================================================
START:
        ; 0. SANITIZE THE ROMX AND HARDWARE ENVIRONMENT
        sei                     ; Disable any interrupts
        cld                     ; Clear decimal mode
        jsr  $FE89              ; SETKBD: Force Apple II ROM Keyboard
        jsr  $FE93              ; SETVID: Force Apple II ROM Video
        
        ; --- NEW: THE DIRTY RESTART SANITIZER ---
        sta  $C000              ; Turn OFF 80STORE (Forces $2000 writes to Main RAM)
        sta  $C00C              ; Turn OFF 80-Column display
        
        ; Reset standard Apple II text window bounds
        lda  #0
        sta  $20                ; WNDLFT
        sta  $22                ; WNDTOP
        lda  #40
        sta  $21                ; WNDWDTH
        lda  #24
        sta  $23                ; WNDBTM
        jsr  HOME               ; Wipe the text page clean so no garbage bleeds
        ; ----------------------------------------

        ; 1. THE "GHOST FINGER" DEBOUNCE DELAY
        ldx  #$FF
@DELAY_OUTER:
        ldy  #$FF
@DELAY_INNER:
        sta  $C010              ; Clear Keyboard Strobe (KBDCLR)
        dey
        bne  @DELAY_INNER
        dex
        bne  @DELAY_OUTER       

        ; 2. PREP MEMORY IN THE BACKGROUND
        ; This runs HGR_CLEAR, wiping the graphics RAM while
        ; it's still hidden from view.
        jsr  INIT_ALL

        ; 3. FORCIBLY SCRUB AND FLIP THE VIDEO HARDWARE
        ; Now that memory is clean ($00), we instantly cut to black.
        sta  $C00C              ; Turn OFF 80-Column Mode
        bit  $C056              ; Turn OFF Lo-Res
        bit  $C057              ; Turn ON Hi-Res
        bit  $C054              ; Turn ON Page 1 (Graphics at $2000)
        bit  $C050              ; Turn ON Graphics Mode 
        bit  $C052              ; <--- CHANGED: Turn OFF Mixed Mode (Full Screen Rain)

MAIN_LOOP:
        lda  KBD                
        bpl  @NO_KEY            
        sta  KBDCLR             
        jmp  EXIT
@NO_KEY:

        lda  ESTATE
        cmp  #3
        beq  @HOLD_STATE
        jmp  DO_RAIN_FRAME      


@HOLD_STATE:
        ; 1. Flip hardware switches to Full-Screen Text Mode
        sta  TXTSET     ; $C051 - Turn ON Text Mode
        sta  PAGE1      ; $C054 - Switch to Page 1
        
        ; 2. Restore the full 24-row text window
        lda  #0
        sta  $22        ; WNDTOP = 0 (Start at row 0)
        
        jmp  CONFIG_SCREEN


; ============================================================
;  Main Effect Loop (Rain, Reveal, and Drain)
; ============================================================
DO_RAIN_FRAME:
        lda  ESTATE
        bne  @CHECK_DRAIN
        lda  RAIN_TMR
        beq  @TMR_DONE
        dec  RAIN_TMR
        bne  @CHECK_DRAIN
@TMR_DONE:
        lda  #1
        sta  ESTATE
        jmp  @START_LOOP

@CHECK_DRAIN:
        lda  ESTATE
        cmp  #2
        bne  @START_LOOP
        
        lda  MAX_BRIGHT
        bne  @DO_FADE
        
        ; The screen is fully dark. Wait for a cinematic beat.
        inc  REVEAL_CNT
        lda  REVEAL_CNT
        cmp  #10            ; <--- WAS 45. Cuts the dead-air delay before the boot screen!
        bcc  @START_LOOP
        
        ; Delay finished. Transition to HOLD.
        lda  #3
        sta  ESTATE
        jmp  @START_LOOP

@DO_FADE:
        dec  FADE_TIMER
        bne  @START_LOOP
        lda  #FADE_SPEED
        sta  FADE_TIMER
        dec  MAX_BRIGHT
        jmp  @START_LOOP

@CLEANUP_CHECK:
        inc  REVEAL_CNT 
        lda  REVEAL_CNT
        cmp  #40       ; Wait for last trails to finish falling
        bcc  @START_LOOP
        lda  #3         ; Freeze on APPLE ][ AI
        sta  ESTATE

@START_LOOP:
        lda  #<BRIGHT_BUF
        sta  SHAD_LO
        lda  #>BRIGHT_BUF
        sta  SHAD_HI

        ldy  #0
RS_ROW_LOOP:
        sty  ROW
        lda  ROW_17_TBL,y
        sta  ROW17
        lda  CELL_LO_TBL,y
        sta  PTR_LO_BASE
        lda  CELL_HI_TBL,y
        sta  PTR_HI
        lda  ROW_X8_TBL,y
        tax
        lda  CELL_HI8_TBL+0,x
        sta  H0
        lda  CELL_HI8_TBL+1,x
        sta  H1
        lda  CELL_HI8_TBL+2,x
        sta  H2
        lda  CELL_HI8_TBL+3,x
        sta  H3
        lda  CELL_HI8_TBL+4,x
        sta  H4
        lda  CELL_HI8_TBL+5,x
        sta  H5
        lda  CELL_HI8_TBL+6,x
        sta  H6
        lda  CELL_HI8_TBL+7,x
        sta  H7

        ldx  #0

RS_COL_LOOP:
        stx  COL
        lda  FRAME
        asl
        asl
        asl                 ; <--- ADD THIS THIRD ASL! It doubles the rain speed.
        sta  TMP
        lda  COL_29_TBL,x
        tay
        lda  SINE_TABLE,y
        clc
        adc  TMP
        sta  PHASE_BASE
        lda  PHASE_BASE
        sec
        sbc  ROW17
        
        cmp  TAIL_LEN_TBL,x     
        bcs  @W_E      
        
        cmp  #41
        bcs  @W_D
        cmp  #11
        bcs  @W_M
        lda  #3
        jmp  @W_OK
@W_M:   lda  #2
        jmp  @W_OK
@W_D:   lda  #1
        jmp  @W_OK
@W_E:   lda  #0
@W_OK:  sta  BRIGHT

        ; DRAIN LOGIC: Cap brightness if in State 2
        lda  ESTATE
        cmp  #2
        bne  @SHADOW_CHECK
        lda  BRIGHT
        cmp  MAX_BRIGHT
        bcc  @SHADOW_CHECK
        lda  MAX_BRIGHT
        sta  BRIGHT

@SHADOW_CHECK:
        ldy  #0
        lda  (SHAD_LO),y        
        cmp  #SENTINEL
        bne  @NOT_F
        jmp  DRAW_FROZEN_LETTER 
@NOT_F:
        cmp  BRIGHT
        bne  @CHANGED
        jmp  CELL_SKIP_NODRAW
@CHANGED:
        lda  BRIGHT
        sta  (SHAD_LO),y

        ; REVEAL LOGIC
        lda  ESTATE
        cmp  #1
        bne  @SKIP_REV
        lda  ROW
        cmp  #TEXT_ROW
        bne  @SKIP_REV
        lda  BRIGHT
        cmp  #3
        bne  @SKIP_REV
        ldx  COL
        cpx  #TEXT_COL0
        bcc  @SKIP_REV
        cpx  #TEXT_COL0 + TEXT_LEN
        bcs  @SKIP_REV
        
        txa
        sec
        sbc  #TEXT_COL0
        tay                     
        lda  REVEAL_BUF,y
        bne  @SKIP_REV
        
        lda  #1
        sta  REVEAL_BUF,y
        inc  REVEAL_CNT
        ldy  #0
        lda  #SENTINEL
        sta  (SHAD_LO),y
        
        lda  REVEAL_CNT
        cmp  #REVEAL_ALL
        bne  @SKIP_REV
        
        lda  #2
        sta  ESTATE ; Switch to DRAIN
        lda  #FADE_SPEED
        sta  FADE_TIMER
        lda  #3
        sta  MAX_BRIGHT
        lda  #0
        sta  REVEAL_CNT 

@SKIP_REV:
        jmp  DO_CELL_DRAW

DRAW_FROZEN_LETTER:
        ldx  COL
        txa
        sec
        sbc  #TEXT_COL0
        tay                     
        lda  TEXT_GLYPH_IDX,y
        asl                 ; Multiply by 8 for font data
        asl
        asl
        sta  GIDX
        
        lda  COL
        ; --- NO ASL HERE! Text is now tightly packed ---
        clc
        adc  PTR_LO_BASE
        sta  PTR_LO
        jsr  DRAW_LETTER_HEAD
        jmp  CELL_ADVANCE

CELL_SKIP_NODRAW:
        inc  SHAD_LO
        bne  @C1
        inc  SHAD_HI
@C1:    ldx  COL
        inx
        cpx  #GRID_W
        beq  @RN
        jmp  RS_COL_LOOP
@RN:    jmp  RS_ROW_NEXT_RAIN

DO_CELL_DRAW:
        lda  COL
        ; --- NO ASL HERE! Grid is 1 byte wide ---
        sta  COL_OFFSET
        lda  PTR_LO_BASE
        clc
        adc  COL_OFFSET
        sta  PTR_LO
        
        ldx  COL
        lda  COL_7_TBL,x
        sta  GLYPH_BASE
        clc
        adc  ROW
        sta  TMP
        
        lda  BRIGHT
        cmp  #3
        bne  @G1
        lda  TMP
        clc
        adc  FRAME
        sta  TMP
@G1:    lda  TMP
        and  #$0F
        asl
        asl
        asl
        sta  GIDX
        
        lda  BRIGHT
        asl
        tax
        jsr  DO_DISPATCH

CELL_ADVANCE:
        inc  SHAD_LO
        bne  @C2
        inc  SHAD_HI
@C2:    ldx  COL
        inx
        cpx  #GRID_W
        bne  @C_CONT
        jmp  RS_ROW_NEXT_RAIN
@C_CONT: jmp  RS_COL_LOOP

RS_ROW_NEXT_RAIN:
        ldy  ROW
        iny
        cpy  #GRID_H
        beq  @RD
        jmp  RS_ROW_LOOP
@RD:    inc  FRAME
        jmp  MAIN_LOOP

; ============================================================
;  Subroutines: Initialization & System
; ============================================================
INIT_ALL:
        lda  #0
        sta  FRAME
        sta  ESTATE
        sta  REVEAL_CNT
        sta  MAX_BRIGHT
        lda  #RAIN_DELAY
        sta  RAIN_TMR
        ldx  #0
        lda  #0
@C:     sta  REVEAL_BUF,x
        inx
        cpx  #TEXT_LEN
        bne  @C
        jsr  INIT_SHADOW
        jsr  HGR_CLEAR
        rts

INIT_SHADOW:
        lda  #<BRIGHT_BUF
        sta  PTR_LO
        lda  #>BRIGHT_BUF
        sta  PTR_HI
        lda  #0
        tay
        ldx  #4         ; Clear 4 memory pages
@LOOP:  sta  (PTR_LO),y
        iny
        bne  @LOOP
        inc  PTR_HI
        dex
        bne  @LOOP
        rts

HGR_CLEAR:
        lda  #$20       ; <-- WAS $40
        sta  PTR_HI
        lda  #$00
        sta  PTR_LO
        tay
@P:     lda  #$00
@L:     sta  (PTR_LO),y
        iny
        bne  @L
        inc  PTR_HI
        lda  PTR_HI
        cmp  #$40       ; <-- WAS $60
        bcc  @P
        rts

EXIT:   
        bit  TXTSET
        bit  PAGE1
        jmp  $E003

DO_DISPATCH:
        lda  DRAW_DISPATCH,x
        sta  PATCH_ADDR
        lda  DRAW_DISPATCH+1,x
        sta  PATCH_ADDR+1

PATCH_OP: jmp $0000
PATCH_ADDR = PATCH_OP + 1

UPDATE_SPINNER:
        inc  SPIN_TICK
        lda  SPIN_TICK
        lsr                 
        lsr
        lsr
        and  #$03           
        tax
        lda  SPINNER_CHARS,x
        
        ; Draw directly to Row 21, Col 79 (Bank 6, offset $DF)
        ldy  #$DF           
        bit  $C300
        pha
        lda  #$06           ; Select Bank 6
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        pla
        sta  ULTRA_DISP,y   
        rts

; ============================================================
;  Drawing Subroutines
; ============================================================
DRAW_LETTER_HEAD:
        ldx  GIDX
        lda  LETTER_DATA,x
        ldy  #0
        sta  (PTR_LO),y
        inx
        .repeat 7, i
        lda  H1+i
        sta  PTR_HI
        lda  LETTER_DATA,x
        sta  (PTR_LO),y
        inx
        .endrepeat
        lda  H0
        sta  PTR_HI
        rts

DRAW_DISPATCH: 
        .word DRAW_ERASE, DRAW_DIM, DRAW_MED, DRAW_HEAD

DRAW_ERASE:
        ldy  #0
        lda  #0
        sta  (PTR_LO),y
        .repeat 7, i
        lda  H1+i
        sta  PTR_HI
        ldy  #0
        lda  #0
        sta  (PTR_LO),y
        .endrepeat
        lda  H0
        sta  PTR_HI
        rts

DRAW_DIM:
        ldx  GIDX
        lda  FONT_DATA,x
        and  #DIM_MASK
        ldy  #0
        sta  (PTR_LO),y
        inx
        .repeat 7, i
        lda  H1+i
        sta  PTR_HI
        lda  FONT_DATA,x
        and  #DIM_MASK
        ldy  #0
        sta  (PTR_LO),y
        inx
        .endrepeat
        lda  H0
        sta  PTR_HI
        rts

DRAW_MED:
        ldx  GIDX
        lda  FONT_DATA,x
        ldy  #0
        sta  (PTR_LO),y
        inx
        .repeat 7, i
        lda  H1+i
        sta  PTR_HI
        lda  FONT_DATA,x
        ldy  #0
        sta  (PTR_LO),y
        inx
        .endrepeat
        lda  H0
        sta  PTR_HI
        rts

DRAW_HEAD:
        ldy  #0
        lda  #$7F
        sta  (PTR_LO),y
        .repeat 7, i
        lda  H1+i
        sta  PTR_HI
        ldy  #0
        lda  #$7F
        sta  (PTR_LO),y
        .endrepeat
        lda  H0
        sta  PTR_HI
        rts
; ============================================================
;  Data Tables
; ============================================================

SPINNER_CHARS: .byte '|', '/', '-', '\'
SPIN_TICK:     .byte 0

CELL_LO_TBL:  
        .repeat 24, i
        .byte <(HGR_PAGE + ((i / 8) * $28) + ((i .mod 8) * $80))
        .endrepeat

CELL_HI_TBL:  
        .repeat 24, i
        .byte >(HGR_PAGE + ((i / 8) * $28) + ((i .mod 8) * $80))
        .endrepeat

CELL_HI8_TBL: 
        .repeat 24, i
        .repeat 8, s
        .byte >(HGR_PAGE + ((i / 8) * $28) + ((i .mod 8) * $80) + (s * $0400))
        .endrepeat
        .endrepeat

ROW_X8_TBL:   
        .repeat 24, i
        .byte <(i * 8)
        .endrepeat

DYN_PORT:
        .byte $00

SPEED_TBL:
        .byte 0,0,1,0,0,2,0,0,0,0, 0,0,0,0,1,0,0,0,2,0
        .byte 0,0,0,0,0,0,1,0,0,0, 0,2,0,0,0,0,0,0,0,1



TAIL_LEN_TBL:
        ; Columns 0-9 (Thin out the left background by alternating 0s)
        .byte 119, 0, 255, 0, 136, 0, 0, 0, 119, 0
        
        ; Columns 10-19 (Columns 14-19 MUST HAVE RAIN for the left half of the logo!)
        .byte 102, 0, 68, 0, 238, 85, 102, 136, 153, 68
        
        ; Columns 20-29 (Columns 20-24 MUST HAVE RAIN for the right half of the logo!)
        .byte 136, 85, 102, 255, 68, 0, 153, 0, 136, 0
        
        ; Columns 30-39 (Thin out the right background by alternating 0s)
        .byte 0, 0, 119, 0, 153, 0, 0, 0, 119, 0

COL_7_TBL:    
        .repeat 40, i          ; <--- Change this from 20 to 40
        .byte <(i * 7)
        .endrepeat

COL_29_TBL:
        .byte 23, 184, 91, 244, 45, 112, 203, 12, 156, 78
        .byte 219, 67, 134, 2, 198, 88, 145, 39, 172, 251
        .byte 14, 99, 210, 55, 128, 7, 189, 42, 233, 80
        .byte 115, 204, 33, 170, 5, 144, 255, 62, 101, 222

ROW_17_TBL:   
        .repeat 24, i
        .byte <(i * 17)
        .endrepeat

SINE_TABLE:
        .byte 128,131,134,137,140,143,146,149,152,156,159,162,165,168,171,174
        .byte 176,179,182,185,188,191,193,196,199,201,204,206,209,211,213,216
        .byte 218,220,222,224,226,228,230,232,234,236,237,239,241,242,243,245
        .byte 246,247,248,249,250,251,252,253,253,254,254,255,255,255,255,255
        .byte 255,255,255,255,255,255,254,254,253,253,252,251,250,249,248,247
        .byte 246,245,243,242,241,239,237,236,234,232,230,228,226,224,222,220
        .byte 218,216,213,211,209,206,204,201,199,196,193,191,188,185,182,179
        .byte 176,174,171,168,165,162,159,156,152,149,146,143,140,137,134,131
        .byte 128,124,121,118,115,112,109,106,103,99,96,93,90,87,84,81
        .byte 79,76,73,70,67,64,62,59,56,54,51,49,46,44,42,39
        .byte 37,35,33,31,29,27,25,23,21,19,18,16,14,13,12,10
        .byte 9,8,7,6,5,4,3,2,2,1,1,0,0,0,0,0
        .byte 0,0,0,0,0,0,1,1,2,2,3,4,5,6,7,8
        .byte 9,10,12,13,14,16,18,19,21,23,25,27,29,31,33,35
        .byte 37,39,42,44,46,49,51,54,56,59,62,64,67,70,73,76
        .byte 79,81,84,87,90,93,96,99,103,106,109,112,115,118,121,124

FONT_DATA:
        .byte $3E, $22, $22, $22, $22, $22, $3E, $00 ; Box
        .byte $3F, $20, $10, $08, $04, $02, $3F, $00 ; Z
        .byte $0E, $00, $1C, $00, $38, $00, $00, $00 ; Mi
        .byte $1E, $20, $1E, $20, $20, $10, $0C, $00 ; Hi
        .byte $3E, $10, $08, $24, $12, $08, $04, $00 ; Nu
        .byte $08, $00, $3E, $08, $08, $04, $04, $00 ; Wa
        .byte $3E, $10, $08, $24, $22, $22, $00, $00 ; Su
        .byte $3E, $20, $10, $08, $04, $04, $04, $00 ; Seven
        .byte $22, $22, $3E, $22, $3E, $22, $22, $00 ; Ho
        .byte $12, $12, $1E, $12, $12, $10, $08, $00 ; Ke
        .byte $10, $18, $14, $12, $3E, $10, $10, $00 ; Four
        .byte $1E, $20, $10, $08, $04, $02, $3E, $00 ; Two
        .byte $22, $14, $08, $14, $22, $22, $00, $00 ; Me
        .byte $3E, $02, $1E, $20, $20, $10, $0E, $00 ; Five
        .byte $1E, $02, $1E, $02, $1E, $00, $00, $00 ; Yo
        .byte $3E, $00, $3E, $08, $04, $02, $00, $00 ; Ra

LETTER_DATA:
        ; 0: A (Thin)
        .byte %00001000, %00010100, %00100010, %00111110, %00100010, %00100010, %00100010, $00
        ; 1: P (Thin)
        .byte %00001110, %00010010, %00010010, %00001110, %00000010, %00000010, %00000010, $00
        ; 2: L (Thin)
        .byte %00000010, %00000010, %00000010, %00000010, %00000010, %00000010, %00011110, $00
        ; 3: E (Thin)
        .byte %00011110, %00000010, %00000010, %00001110, %00000010, %00000010, %00011110, $00
        ; 4: Space
        .byte $00, $00, $00, $00, $00, $00, $00, $00
        ; 5: ] (Bold)
        .byte %00111110, %00110000, %00110000, %00110000, %00110000, %00110000, %00111110, $00
        ; 6: [ (Bold)
        .byte %00111110, %00000110, %00000110, %00000110, %00000110, %00000110, %00111110, $00
        ; 7: I (Thin)
        .byte %00011100, %00001000, %00001000, %00001000, %00001000, %00001000, %00011100, $00

TEXT_GLYPH_IDX:
        ; APPLE ][ AI
        .byte 0, 1, 1, 2, 3, 4, 5, 6, 4, 0, 7


; ── 40-col screen row tables (ULTRATERM_RAIN=0) ───────────────
ROWLO:
        .byte $00,$80,$00,$80,$00,$80,$00,$80
        .byte $28,$A8,$28,$A8,$28,$A8,$28,$A8
        .byte $50,$D0,$50,$D0,$50,$D0,$50,$D0

ROWHI:
        .byte $04,$04,$05,$05,$06,$06,$07,$07
        .byte $04,$04,$05,$05,$06,$06,$07,$07
        .byte $04,$04,$05,$05,$06,$06,$07,$07

; ── Ultraterm linear position tables ─────────────────────────
UTROWPOS_LO:
        .byte $00,$50,$A0,$F0,$40,$90,$E0,$30
        .byte $80,$D0,$20,$70,$C0,$10,$60,$B0
        .byte $00,$50,$A0,$F0,$40,$90,$E0,$30

UTROWPOS_HI:
        .byte $00,$00,$00,$00,$01,$01,$01,$02
        .byte $02,$02,$03,$03,$03,$04,$04,$04
        .byte $05,$05,$05,$05,$06,$06,$06,$07

; ── 40-col character set (64 entries) ─────────────────────────
CSET:
        .byte $C1,$C2,$C3,$C4,$C5,$C6,$C7,$C8
        .byte $C9,$CA,$CB,$CC,$CD,$CE,$CF,$D0
        .byte $D1,$D2,$D3,$D4,$D5,$D6,$D7,$D8
        .byte $D9,$DA,$B0,$B1,$B2,$B3,$B4,$B5
        .byte $B6,$B7,$B8,$B9,$A1,$A2,$A3,$A4
        .byte $A5,$A6,$A7,$A8,$A9,$AA,$AB,$AC
        .byte $AD,$AE,$AF,$BA,$BB,$BC,$BD,$BE
        .byte $BF,$C0,$DB,$DC,$DD,$DE,$DF,$A0


; ── Default server IP ─────────────────────────────────────────
DEFAULT_IP:
        .byte 192,168,1,100

LOCAL_IP:   
        .byte 192,168,1,50   ; An unused IP on your local home network
LOCAL_GW:   
        .byte 192,168,1,1    ; Your physical home router's IP

; ── 40-col strings ────────────────────────────────────────────
STR40_BANNER:
        .byte " ",$0D
        .byte "  UTHERNET II PROXY IP ",$0D
        .byte "  =========================",$0D
        .byte " ",$0D
        .byte 0
STR40_SRV:
        .byte "  NEW IP: ",0
STR40_INST:
        .byte "  [RETURN] ACCEPT  [E] EDIT  TIME: ",0
STR40_EDIT:
        .byte $0D,"  SERVER IP: ",0
STR40_CONN:
        .byte "  CONNECTING...",0
STR40_FAIL:
        .byte "  TCP CONNECT FAILED.",$0D
        .byte "  PROXY RUNNING ON SERVER?",$0D
        .byte "  SERVER IP CORRECT?",$0D
        .byte "  UTHERNET II IN SLOT 2?",$0D
        .byte 0

; ── Ultraterm strings ─────────────────────────────────────────
STRU_BANNER:
        .byte " ",$0D
        .byte "  APPLE ][ AI TERMINAL",$0D
        .byte "  =========================",$0D
        .byte " ",$0D
        .byte 0
STRU_SRV:
        .byte "  SERVER IP: ",0
STRU_INST:
        .byte "  [RETURN] ACCEPT  [E] EDIT  TIME: ",0
STRU_EDIT:
        .byte $0D,"  NEW IP : ",0
STRU_CONN:
        .byte "  CONNECTING...",0
STRU_FAIL:
        .byte "  TCP CONNECT FAILED.",$0D
        .byte "  PROXY RUNNING ON SERVER?",$0D
        .byte "  SERVER IP CORRECT?",$0D
        .byte "  UTHERNET II IN SLOT 2?",$0D
        .byte 0
STRU_HELLO:
        .byte 0
STRU_PROMPT:
        .byte "> ",0
STRU_YOU:
        .byte "YOU: ",0
STRU_AI:
        .byte " ",0
STRU_DISC:
        .byte $0D,"[DISCONNECTED]",0

REDRAW_LOGO:
        ldy  #TEXT_ROW
        lda  CELL_LO_TBL,y
        sta  PTR_LO_BASE
        lda  CELL_HI_TBL,y
        sta  PTR_HI
        lda  ROW_X8_TBL,y
        tax
        lda  CELL_HI8_TBL+0,x
        sta  H0
        lda  CELL_HI8_TBL+1,x
        sta  H1
        lda  CELL_HI8_TBL+2,x
        sta  H2
        lda  CELL_HI8_TBL+3,x
        sta  H3
        lda  CELL_HI8_TBL+4,x
        sta  H4
        lda  CELL_HI8_TBL+5,x
        sta  H5
        lda  CELL_HI8_TBL+6,x
        sta  H6
        lda  CELL_HI8_TBL+7,x
        sta  H7

        ldx  #0
@RL_LOOP:
        stx  ZP_TMP
        lda  TEXT_GLYPH_IDX,x
        asl                 ; Multiply by 8 for font data
        asl
        asl
        sta  GIDX
        
        txa
        clc
        adc  #TEXT_COL0
        ; --- NO ASL HERE! Text is now tightly packed ---
        clc
        adc  PTR_LO_BASE
        sta  PTR_LO
        jsr  DRAW_LETTER_HEAD
        
        ldx  ZP_TMP
        inx
        cpx  #TEXT_LEN
        bcc  @RL_LOOP
        rts


; ============================================================
;  CONFIG SCREEN
; ============================================================

CONFIG_SCREEN:
        jsr  LOAD_CONFIG        ; <--- ADD THIS LINE
        lda  #5
        sta  CDOWN

CFG_REDRAW:
        jsr  HOME
        lda  #3
        jsr  VTAB_ROM
        lda  #<STR40_BANNER
        sta  NET_LO
        lda  #>STR40_BANNER
        sta  NET_HI
        jsr  PRINT40
        lda  #<STR40_SRV
        sta  NET_LO
        lda  #>STR40_SRV
        sta  NET_HI
        jsr  PRINT40
        jsr  PRINT_IP_40
        lda  #<STR40_INST
        sta  NET_LO
        lda  #>STR40_INST
        sta  NET_HI
        jsr  PRINT40
        lda  CDOWN
        clc
        adc  #$B0
        jsr  COUT

        ldy  #250
CFG_OUTER:
        ldx  #0
CFG_INNER:
        lda  KBD
        bmi  CFG_GOT_KEY
        inx
        bne  CFG_INNER
        dey
        bne  CFG_OUTER

        dec  CDOWN
        lda  CDOWN
        bne  CFG_REDRAW
        jmp  DO_CONNECT

CFG_GOT_KEY:
        bit  KBDCLR
        and  #$DF
        cmp  #$C5           ; 'E' | $80
        beq  CFG_EDIT
        jmp  DO_CONNECT

CFG_EDIT:

        jsr  HOME
        lda  #<STR40_EDIT
        sta  NET_LO
        lda  #>STR40_EDIT
        sta  NET_HI
        jsr  PRINT40
        jsr  READ_IP_40

        jsr  SAVE_CONFIG
        lda  #5
        sta  CDOWN
        jmp  CFG_REDRAW

; ============================================================
;  DO_CONNECT  with W5100 diagnostic display
; ============================================================

DIAG_HDR:   .byte " UTHERNET II INTERFACE ",0
DIAG_BR:    .byte " =====================",0
DIAG_RST:   .byte " 1. W5100 RESET...",0
DIAG_VER:   .byte " 2. VERSION REG...",0
DIAG_MODE:  .byte " 3. INDIRECT MODE...",0
DIAG_SIP:   .byte " 4. SOURCE IP...",0
DIAG_SOCK:  .byte " 5. SOCKET OPEN...",0
DIAG_CONN:  .byte " 6. TCP CONNECT...",0
DIAG_OK:    .byte "OK",0
DIAG_FAIL:  .byte "FAIL",0
DIAG_VER_EXP: .byte " (EXPECT $03)",0
DIAG_MYIP:  .byte "   APPLE II IP: ",0
DIAG_SRVIP: .byte "   SERVER IP  : ",0
DIAG_ANY:   .byte "   PRESS ANY KEY",0

DO_CONNECT:

        jsr  HOME

        ; --- YOU NEED THIS BLOCK TO PRINT THE HEADER ---
        lda  #<DIAG_HDR
        sta  NET_LO
        lda  #>DIAG_HDR
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL
        ; -----------------------------------------------

        lda  #<DIAG_MYIP
        sta  NET_LO
        lda  #>DIAG_MYIP
        sta  NET_HI
        jsr  DIAG_PRINT
        
        lda  LOCAL_IP+0       ; <-- CHANGED
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  LOCAL_IP+1       ; <-- CHANGED
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  LOCAL_IP+2       ; <-- CHANGED
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  LOCAL_IP+3       ; <-- CHANGED
        jsr  DIAG_DEC
        jsr  DIAG_NL

        lda  #<DIAG_SRVIP
        sta  NET_LO
        lda  #>DIAG_SRVIP
        sta  NET_HI
        jsr  DIAG_PRINT

        jsr  PRINT_IP_40

        jsr  DIAG_NL

        ; ── 1: Reset W5100 
        lda  #<DIAG_RST
        sta  NET_LO
        lda  #>DIAG_RST
        sta  NET_HI
        jsr  DIAG_PRINT

        lda  #$80
        sta  WBASE              
        ldy  #0
        ldx  #0
DIAG_DLY:
        inx
        bne  DIAG_DLY
        iny
        bne  DIAG_DLY

        lda  #<DIAG_OK
        sta  NET_LO
        lda  #>DIAG_OK
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL

        ; ── 2: Check version register 
        lda  #<DIAG_VER
        sta  NET_LO
        lda  #>DIAG_VER
        sta  NET_HI
        jsr  DIAG_PRINT

        lda  #$03
        sta  WBASE
        lda  #$00
        sta  W_IDM_AR0
        lda  #$39
        sta  W_IDM_AR1
        lda  W_IDM_DR           
        sta  TMP_A

        lda  #'$'
        jsr  DIAG_PUTC
        lda  TMP_A
        jsr  PRINT_HEX_BYTE
        lda  #<DIAG_VER_EXP
        sta  NET_LO
        lda  #>DIAG_VER_EXP
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL

        ; ── 3: Indirect mode 
        lda  #<DIAG_MODE
        sta  NET_LO
        lda  #>DIAG_MODE
        sta  NET_HI
        jsr  DIAG_PRINT
        lda  #<DIAG_OK
        sta  NET_LO
        lda  #>DIAG_OK
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL

        ; ── 4: Full W5100 init 
        lda  #<DIAG_SIP
        sta  NET_LO
        lda  #>DIAG_SIP
        sta  NET_HI
        jsr  DIAG_PRINT

        jsr  W5100_INIT

        lda  #$00
        sta  W_IDM_AR0
        lda  #$0F
        sta  W_IDM_AR1
        lda  W_IDM_DR
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  W_IDM_DR
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  W_IDM_DR
        jsr  DIAG_DEC
        lda  #'.'
        jsr  DIAG_PUTC
        lda  W_IDM_DR
        jsr  DIAG_DEC
        jsr  DIAG_NL

        ; ── 5: Socket open 
        lda  #<DIAG_SOCK
        sta  NET_LO
        lda  #>DIAG_SOCK
        sta  NET_HI
        jsr  DIAG_PRINT

        inc  DYN_PORT       ; <--- FIX: Increment the Source Port!

        lda  #$04
        sta  W_IDM_AR0
        lda  #$00
        sta  W_IDM_AR1
        lda  #$01
        sta  W_IDM_DR

        lda  #$04
        sta  W_IDM_AR0
        lda  #$04
        sta  W_IDM_AR1
        lda  #$C0           ; High Byte: Start at Port 49152 ($C000)
        sta  W_IDM_DR
        lda  DYN_PORT       ; Low Byte: Increments on every connection
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_OPEN
        sta  W_IDM_DR

        ldx  #200
DIAG_SK_WAIT:
        jsr  READ_S0_SR
        cmp  #SOCK_INIT
        beq  DIAG_SOCK_OK
        dex
        bne  DIAG_SK_WAIT

        jsr  READ_S0_SR
        sta  TMP_A
        lda  #'$'
        jsr  DIAG_PUTC
        lda  TMP_A
        jsr  PRINT_HEX_BYTE
        lda  #<DIAG_FAIL
        sta  NET_LO
        lda  #>DIAG_FAIL
        sta  NET_HI
        jsr  DIAG_PRINT
        jmp  DIAG_DONE

DIAG_SOCK_OK:
        lda  #<DIAG_OK
        sta  NET_LO
        lda  #>DIAG_OK
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL

        ; ── 6: TCP connect 
        lda  #<DIAG_CONN
        sta  NET_LO
        lda  #>DIAG_CONN
        sta  NET_HI
        jsr  DIAG_PRINT

        lda  #$04
        sta  W_IDM_AR0
        lda  #$0C
        sta  W_IDM_AR1
        lda  SRV_IP+0
        sta  W_IDM_DR
        lda  SRV_IP+1
        sta  W_IDM_DR
        lda  SRV_IP+2
        sta  W_IDM_DR
        lda  SRV_IP+3
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$10
        sta  W_IDM_AR1
        lda  #$13
        sta  W_IDM_DR
        lda  #$88
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_CONNECT
        sta  W_IDM_DR

        ldx  #0
        ldy  #10
DIAG_CONN_WAIT:
        jsr  READ_S0_SR
        cmp  #SOCK_ESTAB
        beq  DIAG_CONN_OK
        sta  TMP_A
        inx
        bne  DIAG_CONN_WAIT
        lda  #'.'
        jsr  DIAG_PUTC
        dey
        bne  DIAG_CONN_WAIT

        jsr  READ_S0_SR
        sta  TMP_A
        lda  #' '
        jsr  DIAG_PUTC
        lda  #'S'
        jsr  DIAG_PUTC
        lda  #'T'
        jsr  DIAG_PUTC
        lda  #'='
        jsr  DIAG_PUTC
        lda  #'$'
        jsr  DIAG_PUTC
        lda  TMP_A
        jsr  PRINT_HEX_BYTE
        lda  #<DIAG_FAIL
        sta  NET_LO
        lda  #>DIAG_FAIL
        sta  NET_HI
        jsr  DIAG_PRINT
        jmp  DIAG_DONE

DIAG_CONN_OK:
        lda  #<DIAG_OK
        sta  NET_LO
        lda  #>DIAG_OK
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  DIAG_NL
        jsr  DIAG_NL

        jmp  DIAG_GO_CHAT

DIAG_DONE:
        jsr  DIAG_NL
        jsr  DIAG_NL
        lda  #<DIAG_ANY
        sta  NET_LO
        lda  #>DIAG_ANY
        sta  NET_HI
        jsr  DIAG_PRINT
        jsr  RDKEY
        jsr  HOME
        rts

; ============================================================
;  ASYNC SPLIT-SCREEN EVENT LOOP
; ============================================================

DIAG_GO_CHAT:
        jsr  BOOTSTRAP_ULTRATERM
        
        lda  #$0A           
        sta  CRTC_SEL
        lda  #$60           
        sta  CRTC_DAT
        lda  #$0B           
        sta  CRTC_SEL
        lda  #$08           
        sta  CRTC_DAT

        ; ── NEW: Start Chat at Row 0 (Top Left) ──
        lda  #0
        sta  CHAT_ROW
        lda  #0
        sta  CHAT_COL
        
        jmp  CHAT_INIT

CHAT_INIT:
        lda  #$FF
        sta  UI_NET_STATE   ; Force the HUD to draw on the very first loop!
        
        lda  #0
        sta  TX_IDX
        sta  TXBUF
        sta  RX_CNT_HI
        sta  RX_CNT_LO
        
        jsr  CLEAR_CHAT_AREA    ; <--- ADD THIS LINE TO WIPE THE SRAM GARBAGE!
        
        jsr  DRAW_INPUT_PROMPT

ASYNC_CHAT_LOOP:
        ; ── 1. PULSE CHECK: IS SOCKET ALIVE? ─────────────────
        lda  #$04
        sta  W_IDM_AR0
        lda  #$03           ; S0_SR
        sta  W_IDM_AR1
        lda  W_IDM_DR
        
        cmp  #$17           ; ESTABLISHED
        beq  SOCKET_OK      ; <--- Removed @
        cmp  #$1C           ; CLOSE_WAIT
        beq  DO_SERVER_DISC
        cmp  #$00           ; CLOSED
        beq  DO_SERVER_DISC
        jmp  SKIP_SPINNER   ; <--- Removed @

DO_SERVER_DISC:
        lda  #0             ; 0 = Offline
        jsr  DRAW_NET_STATUS
        jmp  CHAT_DISC      ; Trigger disconnect logic

SOCKET_OK:                  ; <--- Removed @
        lda  #1             ; 1 = Online
        jsr  DRAW_NET_STATUS
        jsr  UPDATE_SPINNER
SKIP_SPINNER:               ; <--- Removed @

        ; ── 2. CHECK NETWORK FOR INCOMING DATA ───────────────
        lda  #$04
        sta  W_IDM_AR0
        lda  #$26           ; S0_RX_RSR
        sta  W_IDM_AR1
        lda  W_IDM_DR
        sta  RX_CNT_HI
        lda  W_IDM_DR
        sta  RX_CNT_LO
        
        ora  RX_CNT_HI
        beq  CHECK_KBD

        ; ── DATA RECEIVED ────────────────────────────────────
        lda  CHAT_ROW
        sta  UT_ROW
        lda  CHAT_COL
        sta  UT_COL
        
        jsr  TRR_READ_BLOCK 
        
        lda  UT_ROW
        sta  CHAT_ROW
        lda  UT_COL
        sta  CHAT_COL
        
        ; Restore input cursor
        lda  #21
        sta  UT_ROW
        lda  INPUT_COL
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        jmp  CHECK_KBD

CHECK_KBD:
        lda  KBD            
        bmi  @KBD_PRESSED
        jmp  ASYNC_CHAT_LOOP

@KBD_PRESSED:
        bit  KBDCLR         
        
        cmp  #$9B               ; ESC key ($1B + $80)
        beq  @DO_EXIT
        
        cmp  #$83               ; Ctrl-C (Legacy fallback)
        bne  @NOT_EXIT
@DO_EXIT:
        jmp  CHAT_EXIT
@NOT_EXIT:
        
        cmp  #$8D               ; Return
        bne  @NOT_RETURN
        jmp  HANDLE_RETURN
@NOT_RETURN:
        
        cmp  #$88               ; Backspace (left arrow)
        bne  @NOT_BS
        jmp  HANDLE_BS
@NOT_BS:
        cmp  #$FF               ; Delete key
        bne  @NOT_DEL
        jmp  HANDLE_BS
@NOT_DEL:

        cmp  #$A0               ; Ignore control keys
        bcs  @IS_PRINTABLE
        jmp  ASYNC_CHAT_LOOP
@IS_PRINTABLE:
        
        and  #$7F           
        ldx  TX_IDX
        cpx  #77                ; Single line: 77 chars max ("> " + 77 + cursor = 80)
        bcc  @STORE_CHAR
        jmp  ASYNC_CHAT_LOOP

@STORE_CHAR:
        sta  TXBUF,x        
        inc  TX_IDX
        sta  TMP_C          

        ; ── ECHO AT ROW 21 ──
        lda  #21            ; <--- CHANGED FROM 23
        sta  UT_ROW
        lda  INPUT_COL
        sta  UT_COL
        
        lda  TMP_C          
        jsr  ULTRA_PUTC
        
        lda  UT_COL
        sta  INPUT_COL
        jmp  ASYNC_CHAT_LOOP

HANDLE_RETURN:
        ldx  TX_IDX
        bne  @DO_RET
        jmp  ASYNC_CHAT_LOOP  
@DO_RET:
        lda  #0
        sta  TXBUF,x          ; Null-terminate the string

        ; 1. WIPE THE CHAT AREA CLEAN (Rows 0-19)
        jsr  CLEAR_CHAT_AREA
        
        ; ── REDRAW THE [ONLINE] STATUS ──
        lda  #$FF
        sta  UI_NET_STATE
        
        ; 2. WIPE THE TYPING LINE AND REDRAW STATUS HUD
        jsr  DRAW_INPUT_PROMPT
        
        ; 3. PRINT THE USER'S QUESTION AT THE VERY TOP
        lda  #0
        sta  UT_ROW
        lda  #0
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        
        lda  #<STRU_YOU
        sta  NET_LO
        lda  #>STRU_YOU
        sta  NET_HI
        jsr  ULTRA_PRINT
        
        lda  #<TXBUF
        sta  NET_LO
        lda  #>TXBUF
        sta  NET_HI
        jsr  ULTRA_PRINT
        
        ; 4. SET THE CURSOR TO ROW 2 FOR THE AI RESPONSE
        lda  #2
        sta  UT_ROW
        lda  #0
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        
        ; Save the Chat Cursor so the network loop knows where to start drawing
        lda  UT_ROW
        sta  CHAT_ROW
        lda  UT_COL
        sta  CHAT_COL
        
        ; 5. TRANSMIT TO THE PYTHON PROXY
        jsr  TCP_SEND_LINE
        bcs  CHAT_DISC
        
        ; 6. RESET TYPING BUFFERS
        lda  #0
        sta  TX_IDX
        sta  TXBUF
        sta  RX_CNT_HI
        sta  RX_CNT_LO
        
        jmp  ASYNC_CHAT_LOOP

HANDLE_BS:
        ldx  TX_IDX
        bne  @DO_BS
        jmp  ASYNC_CHAT_LOOP   

@DO_BS:
        dex
        stx  TX_IDX
        
        dec  INPUT_COL
        lda  #21            ; <--- CHANGED FROM 23
        sta  UT_ROW
        lda  INPUT_COL
        sta  UT_COL
        
        jsr  ULTRA_SET_CURSOR
        lda  #$20           
        jsr  ULTRA_PUTC
        
        dec  UT_COL
        jsr  ULTRA_SET_CURSOR
        jmp  ASYNC_CHAT_LOOP

CHAT_DISC:
        lda  CHAT_ROW
        sta  UT_ROW
        lda  CHAT_COL
        sta  UT_COL
        lda  #<STRU_DISC
        sta  NET_LO
        lda  #>STRU_DISC
        sta  NET_HI
        jsr  ULTRA_PRINT
        jsr  RDKEY
CHAT_EXIT:
        jsr  HOME
        rts

; ── DRAW_INPUT_PROMPT: "> " on row 23, clear the line ────────
DRAW_INPUT_PROMPT:
        bit  $C300
        
        ; 1. Clear Row 21 & 22 (Bank 6, offset $90 to $FF)
        lda  #$06
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$90
@C1:    sta  ULTRA_DISP,y
        iny
        bne  @C1
        
        ; 2. Clear Row 22 end & Row 23 (Bank 7, offset $00 to $7F)
        lda  #$07
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$00
@C2:    sta  ULTRA_DISP,y
        iny
        cpy  #$80
        bcc  @C2

        ; 3. Draw Input Prompt on Row 21
        lda  #21
        sta  UT_ROW
        lda  #0
        sta  UT_COL
        lda  #'>'
        jsr  ULTRA_PUTC
        lda  #' '
        jsr  ULTRA_PUTC

        ; 4. Draw the Bottom Status Bar (Row 23 / Bank 7, offset $30)
        lda  #$07
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        ldy  #$30               
@SB_CLR:
        lda  #$A0               ; Inverse Space
        sta  ULTRA_DISP,y
        iny
        cpy  #$80
        bcc  @SB_CLR

        ldx  #0
        ldy  #$31               ; Pad by 1 space
@SB_TXT:
        lda  STATUS_TXT,x
        beq  @DONE
        ora  #$80               ; Make text inverse
        sta  ULTRA_DISP,y
        inx
        iny
        bne  @SB_TXT
@DONE:
        
        ; 5. Lock cursor back on Row 21 for typing
        lda  #2
        sta  INPUT_COL
        sta  UT_COL
        lda  #21
        sta  UT_ROW
        jsr  ULTRA_SET_CURSOR
        rts

STATUS_TXT: .byte "ESC: QUIT   RETURN: SEND",0

; ── CLEAR_CHAT_AREA: Wipe rows 1-22, preserve row 0 title ───
CLEAR_CHAT_AREA:
        bit  $C300
        ; Clear Banks 0 through 5
        ldx  #0                 
@BANK:  txa
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #0
@PAGE:  sta  ULTRA_DISP,y
        iny
        bne  @PAGE
        inx
        cpx  #6
        bcc  @BANK
        
        ; Clear Bank 6 up to offset $40 (Row 19 ends at $3F)
        lda  #$06
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$00
@B6:    sta  ULTRA_DISP,y
        iny
        cpy  #$40               ; <--- STOPS EXACTLY AT END OF ROW 19
        bcc  @B6
        rts

CLEAR_VIEWPORT:
; ── SCROLL: Move rows 2-22 up to rows 1-21, blank row 22 ────
; Source: Row 2 = Bank $00, Offset $A0
; Dest:   Row 1 = Bank $00, Offset $50
; End:    Source reaches Row 23 = Bank $07, Offset $30

        bit  $C300

        ; Source = Row 2
        lda  #$A0
        sta  TMP_A
        lda  #$00
        sta  TMP_B

        ; Dest = Row 1
        lda  #$50
        sta  SCRL_LO
        lda  #$00
        sta  SCRL_HI

@SV_LOOP:
        lda  TMP_B
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        ldy  TMP_A
        lda  ULTRA_DISP,y
        sta  TMP_C

        lda  SCRL_HI
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        ldy  SCRL_LO
        lda  TMP_C
        sta  ULTRA_DISP,y

        inc  TMP_A
        bne  @SV_S_OK
        inc  TMP_B
@SV_S_OK:
        inc  SCRL_LO
        bne  @SV_D_OK
        inc  SCRL_HI
@SV_D_OK:
        ; Stop when source reaches Row 23 (bank $07, offset $30)
        lda  TMP_B
        cmp  #$07
        bcc  @SV_LOOP
        lda  TMP_A
        cmp  #$30
        bcc  @SV_LOOP

        ; Blank row 22 (Bank 6, offsets $E0-$FF + Bank 7, offsets $00-$2F)
        lda  #$06
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$E0
@B22A:  sta  ULTRA_DISP,y
        iny
        bne  @B22A

        lda  #$07
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$00
@B22B:  sta  ULTRA_DISP,y
        iny
        cpy  #$30
        bcc  @B22B

        ; Pin cursor at row 22, col 0
        lda  #22
        sta  UT_ROW
        lda  #0
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        rts

; ============================================================
;  GRACEFUL ULTRATERM BOOTSTRAP
; ============================================================

BOOTSTRAP_ULTRATERM:
        ; 1. INVISIBLE WIPE: Scrub SRAM before CRTC turns on to prevent sync crash!
        bit  $C300              ; Secure memory bus
        ldx  #0                 ; Start at Bank 0
@BANK_LOOP:
        txa
        ora  #ULTRA_MCP_MASK    ; $D0 | bank
        sta  ULTRA_MCP          ; $C0B2
        
        lda  #$20               ; Space character
        ldy  #0                 ; 256 bytes per bank
@WIPE_LOOP:
        sta  ULTRA_DISP,y       ; Write to $CC00,y
        iny
        bne  @WIPE_LOOP
        
        inx
        cpx  #8                 ; 8 total banks
        bcc  @BANK_LOOP

        ; 2. AWAKEN THE HARDWARE safely
        lda  #$00               ; Parameter for 80x24 mode
        jsr  ULTRA_BANKIN       ; JSR $C300

        ; 3. RESET LOGICAL STATE
        lda  #0
        sta  UT_ROW
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        
        jsr  DRAW_UI_FRAMING    ; <--- ADD THIS LINE HERE!
        rts

DRAW_UI_FRAMING:
        bit  $C300

        ; ── Row 0: Title Text (Normal Video) ──
        lda  #$00
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP

        ldx  #0
@TITLE_LOOP:
        lda  UI_TITLE_TEXT,x
        beq  @ROW1
        sta  ULTRA_DISP,x
        inx
        bne  @TITLE_LOOP

@ROW1:
        ; ── Row 1: Solid Divider Line ──
        ; Row 1 lives in Bank 0, from offsets $50 to $9F
        lda  #'-'               ; Use hyphens for the divider
        ldy  #$50
@DIV_LOOP:
        sta  ULTRA_DISP,y
        iny
        cpy  #$A0               ; Stop exactly where Row 2 begins
        bcc  @DIV_LOOP
        rts

UI_TITLE_TEXT:
        .byte " APPLE ][ AI",0

DRAW_NET_STATUS:
        cmp  UI_NET_STATE
        beq  @DONE              ; Skip if the state hasn't changed!
        sta  UI_NET_STATE

        pha                     ; Save A register
        bit  $C300
        lda  #$00
        ora  #ULTRA_MCP_MASK    ; Select Bank 0 (Row 0 Title Bar)
        sta  ULTRA_MCP

        pla                     ; Restore A register
        bne  @DRAW_ON
        lda  #<STR_OFFLINE
        sta  NET_LO
        lda  #>STR_OFFLINE
        sta  NET_HI
        jmp  @DRAW
@DRAW_ON:
        lda  #<STR_ONLINE
        sta  NET_LO
        lda  #>STR_ONLINE
        sta  NET_HI
@DRAW:
        ldy  #0
        ldx  #68                ; Right-align! (Leaves 1 col padding on the edge)
@LOOP:
        lda  (NET_LO),y
        beq  @DONE
        ; ora  #$80               <--- DELETE THIS LINE!
        sta  ULTRA_DISP,x
        iny
        inx
        bne  @LOOP
@DONE:
        rts

; Status Data Variables
UI_NET_STATE: .byte $FF
STR_ONLINE:   .byte "[ONLINE]   ",0
STR_OFFLINE:  .byte "[OFFLINE]  ",0

UC_BANK:
        txa
        ora  #ULTRA_MCP_MASK  ; $D0 | bank
        sta  ULTRA_MCP
        lda  #$20
        ldy  #0
UC_FILL:
        sta  ULTRA_DISP,y
        iny
        bne  UC_FILL
        inx
        cpx  #8
        bcc  UC_BANK
        jsr  ULTRA_SET_CURSOR
        rts

ULTRA_PUTC:
        sta  TMP_C
        bit $C300
        ldx  UT_ROW
        lda  UTROWPOS_LO,x
        clc
        adc  UT_COL
        tay                 ; Y = offset into $CC00 window
        lda  UTROWPOS_HI,x
        adc  #0             ; + carry
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP      ; select bank
        lda  TMP_C
        sta  ULTRA_DISP,y   ; write char
        inc  UT_COL
        lda  UT_COL
        cmp  #80
        bcc  UPC_DONE
        lda  #0
        sta  UT_COL
        jsr  ULTRA_NEWLINE
        rts
UPC_DONE:
        jsr  ULTRA_SET_CURSOR
        rts

ULTRA_NEWLINE:
        lda  #0
        sta  UT_COL
        inc  UT_ROW
        lda  UT_ROW
        cmp  #20            ; <--- Wrap when hitting Row 20
        bcc  UNL_OK
        
        jsr  CLEAR_CHAT_AREA
        
        ; Reset cursor to top
        lda  #0
        sta  UT_ROW
        sta  UT_COL
        jsr  ULTRA_SET_CURSOR
        rts
UNL_OK:
        jsr  ULTRA_SET_CURSOR
        rts
        
US_LOOP:
        lda  TMP_B         ; <--- CHANGED
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        ldy  TMP_A         ; <--- CHANGED
        lda  ULTRA_DISP,y
        sta  TMP_C

        lda  SCRL_HI
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        ldy  SCRL_LO
        lda  TMP_C
        sta  ULTRA_DISP,y

        inc  TMP_A         ; <--- CHANGED
        bne  US_S_OK
        inc  TMP_B         ; <--- CHANGED
US_S_OK:
        inc  SCRL_LO
        bne  US_D_OK
        inc  SCRL_HI
US_D_OK:
        lda  TMP_B         ; <--- CHANGED
        cmp  #$07
        bcc  US_LOOP
        lda  TMP_A         ; <--- CHANGED
        cmp  #$30          
        bcc  US_LOOP

        ; Blank row 22 part 1: bank 6, offsets $E0-$FF
        lda  #$06
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$E0
US_BLK1:
        sta  ULTRA_DISP,y
        iny
        bne  US_BLK1

        ; Blank row 22 part 2: bank 7, offsets $00-$2F
        lda  #$07
        ora  #ULTRA_MCP_MASK
        sta  ULTRA_MCP
        lda  #$20
        ldy  #$00
US_BLK2:
        sta  ULTRA_DISP,y
        iny
        cpy  #$30
        bcc  US_BLK2
        rts

ULTRA_SET_CURSOR:
        ldx  UT_ROW
        lda  UTROWPOS_LO,x
        clc
        adc  UT_COL
        sta  TMP_A          
        lda  UTROWPOS_HI,x
        adc  #0
        sta  TMP_B          
        lda  #$0E
        sta  CRTC_SEL       ; select R14
        lda  TMP_B
        sta  CRTC_DAT       ; write high byte
        lda  #$0F
        sta  CRTC_SEL       ; select R15
        lda  TMP_A
        sta  CRTC_DAT       ; write low byte
        rts

ENABLE_CURSOR:
        lda  #$0A           ; CRTC R10: Cursor Start & Blink
        sta  CRTC_SEL
        lda  #$60           ; $60 = Fast Blink, Start on scanline 0
        sta  CRTC_DAT
        lda  #$0B           ; CRTC R11: Cursor End
        sta  CRTC_SEL
        lda  #$08           ; End on scanline 8 (Block cursor)
        sta  CRTC_DAT
        rts

ULTRA_PRINT:
UP_LP:
        ldy  #0             ; ULTRA_PUTC clobbers Y
        lda  (NET_LO),y
        beq  UP_DONE
        inc  NET_LO
        bne  UP_NHI
        inc  NET_HI
UP_NHI:
        cmp  #$0D
        bne  UP_CH
        jsr  ULTRA_NEWLINE
        jmp  UP_LP
UP_CH:
        jsr  ULTRA_PUTC
        jmp  UP_LP
UP_DONE:
        rts


; ============================================================
;  PRINT_IP / READ_IP
; ============================================================

PRINT_IP_UT:
        lda  SRV_IP+0
        jsr  PDEC_UT
        lda  #'.'
        jsr  ULTRA_PUTC
        lda  SRV_IP+1
        jsr  PDEC_UT
        lda  #'.'
        jsr  ULTRA_PUTC
        lda  SRV_IP+2
        jsr  PDEC_UT
        lda  #'.'
        jsr  ULTRA_PUTC
        lda  SRV_IP+3
        jsr  PDEC_UT
        jsr  ULTRA_NEWLINE
        rts

PDEC_UT:
        sta  TMP_A
        lda  #0
        sta  TMP_B
PDU_100:
        lda  TMP_A
        cmp  #100
        bcc  PDU_T
        sec
        sbc  #100
        sta  TMP_A
        inc  TMP_B
        jmp  PDU_100
PDU_T:
        lda  TMP_B
        beq  PDU_NH
        clc
        adc  #'0'
        jsr  ULTRA_PUTC
        lda  #1
        sta  TMP_B
PDU_NH:
        lda  #0
        sta  TMP_C
PDU_10:
        lda  TMP_A
        cmp  #10
        bcc  PDU_O
        sec
        sbc  #10
        sta  TMP_A
        inc  TMP_C
        jmp  PDU_10
PDU_O:
        lda  TMP_C
        bne  PDU_PT
        lda  TMP_B
        beq  PDU_OO
PDU_PT:
        lda  TMP_C
        clc
        adc  #'0'
        jsr  ULTRA_PUTC
PDU_OO:
        lda  TMP_A
        clc
        adc  #'0'
        jsr  ULTRA_PUTC
        rts

PRINT_IP_40:
        lda  SRV_IP+0
        jsr  PDEC40
        lda  #$AE
        jsr  COUT
        lda  SRV_IP+1
        jsr  PDEC40
        lda  #$AE
        jsr  COUT
        lda  SRV_IP+2
        jsr  PDEC40
        lda  #$AE
        jsr  COUT
        lda  SRV_IP+3
        jsr  PDEC40
        lda  #$8D
        jsr  COUT
        rts

PDEC40:
        sta  TMP_A
        lda  #0
        sta  TMP_B
PD40_100:
        lda  TMP_A
        cmp  #100
        bcc  PD40_T
        sec
        sbc  #100
        sta  TMP_A
        inc  TMP_B
        jmp  PD40_100
PD40_T:
        lda  TMP_B
        beq  PD40_NH
        clc
        adc  #$B0
        jsr  COUT
        lda  #1
        sta  TMP_B
PD40_NH:
        lda  #0
        sta  TMP_C
PD40_10:
        lda  TMP_A
        cmp  #10
        bcc  PD40_O
        sec
        sbc  #10
        sta  TMP_A
        inc  TMP_C
        jmp  PD40_10
PD40_O:
        lda  TMP_C
        bne  PD40_PT
        lda  TMP_B
        beq  PD40_OO
PD40_PT:
        lda  TMP_C
        clc
        adc  #$B0
        jsr  COUT
PD40_OO:
        lda  TMP_A
        clc
        adc  #$B0
        jsr  COUT
        rts

READ_IP_40:
        ldx  #0
        lda  #0
        sta  TMP_A
RI40_KEY:
        jsr  RDKEY
        cmp  #$8D
        bne  RI40_NR
        cpx  #3
        bne  RI40_KEY
        lda  TMP_A
        sta  SRV_IP,x
        lda  #$8D
        jsr  COUT
        rts
RI40_NR:
        cmp  #$AE
        bne  RI40_ND
        lda  TMP_A
        sta  SRV_IP,x
        lda  #$AE
        jsr  COUT
        inx
        cpx  #4
        bcs  RI40_KEY
        lda  #0
        sta  TMP_A
        jmp  RI40_KEY
RI40_ND:
        cmp  #$B0
        bcc  RI40_KEY
        cmp  #$BA
        bcs  RI40_KEY
        and  #$0F
        sta  TMP_B
        lda  TMP_A
        asl
        sta  TMP_C
        asl
        asl
        clc
        adc  TMP_C
        bcs  RI40_KEY
        clc
        adc  TMP_B
        bcs  RI40_KEY
        sta  TMP_A
        lda  TMP_B
        clc
        adc  #$B0
        jsr  COUT
        jmp  RI40_KEY

READ_IP_UT:
        ldx  #0
        lda  #0
        sta  IP_ACC
RIUT_KEY:
        lda  KBD
        bpl  RIUT_KEY
        bit  KBDCLR
        cmp  #$8D           ; Return?
        bne  RIUT_NR
        cpx  #3
        bne  RIUT_KEY
        lda  IP_ACC
        sta  SRV_IP,x
        jsr  ULTRA_NEWLINE
        rts
RIUT_NR:
        cmp  #$AE           ; '.'?
        bne  RIUT_ND
        lda  IP_ACC
        sta  SRV_IP,x
        stx  ZP_LO          ; save octet counter 
        lda  #'.'
        jsr  ULTRA_PUTC
        ldx  ZP_LO          ; restore octet counter
        inx
        cpx  #4
        bcs  RIUT_KEY
        lda  #0
        sta  IP_ACC
        jmp  RIUT_KEY
RIUT_ND:
        cmp  #$B0           ; below '0'?
        bcc  RIUT_KEY
        cmp  #$BA           ; above '9'?
        bcs  RIUT_KEY
        and  #$0F
        sta  ZP_TMP         ; ZP_TMP = digit
        lda  IP_ACC
        asl                 ; *2
        bcs  RIUT_KEY       ; overflow
        pha                 ; save *2
        asl                 ; *4
        asl                 ; *8
        bcs  RIUT_POP       ; overflow
        sta  IP_ACC         ; temp: IP_ACC = *8
        pla                 ; pull *2
        clc
        adc  IP_ACC         ; *2 + *8 = *10
        bcs  RIUT_KEY
        clc
        adc  ZP_TMP         ; + digit
        bcs  RIUT_KEY
        sta  IP_ACC
        stx  ZP_LO          ; save octet counter
        lda  ZP_TMP
        clc
        adc  #'0'
        jsr  ULTRA_PUTC     ; CLOBBERS X 
        ldx  ZP_LO          ; restore octet counter
        jmp  RIUT_KEY
RIUT_POP:
        pla                 ; clean stack
        jmp  RIUT_KEY

PRINT40:
        ldy  #0
P40_LP:
        lda  (NET_LO),y
        beq  P40_DONE
        cmp  #$0D
        bne  P40_N
        lda  #$8D
        jsr  COUT
        iny
        jmp  P40_LP
P40_N:
        ora  #$80
        jsr  COUT
        iny
        bne  P40_LP
P40_DONE:
        rts

; ============================================================
;  LOAD_CONFIG / SAVE_CONFIG  (Garrett's 128K)
; ============================================================

LOAD_CONFIG:
        lda  LC_RD2_WE
        lda  LC_RD2_WE
        lda  LC_CONFIG_MG
        cmp  #$A5
        bne  LC_DEF
        lda  LC_CONFIG_MG+1
        cmp  #$5A
        bne  LC_DEF
        lda  LC_CONFIG_IP+0
        sta  SRV_IP+0
        lda  LC_CONFIG_IP+1
        sta  SRV_IP+1
        lda  LC_CONFIG_IP+2
        sta  SRV_IP+2
        lda  LC_CONFIG_IP+3
        sta  SRV_IP+3
        lda  LC_ROM_WP
        rts
LC_DEF:
        lda  LC_ROM_WP
        lda  DEFAULT_IP+0
        sta  SRV_IP+0
        lda  DEFAULT_IP+1
        sta  SRV_IP+1
        lda  DEFAULT_IP+2
        sta  SRV_IP+2
        lda  DEFAULT_IP+3
        sta  SRV_IP+3
        rts

SAVE_CONFIG:
        lda  LC_RD2_WE
        lda  LC_RD2_WE
        lda  SRV_IP+0
        sta  LC_CONFIG_IP+0
        lda  SRV_IP+1
        sta  LC_CONFIG_IP+1
        lda  SRV_IP+2
        sta  LC_CONFIG_IP+2
        lda  SRV_IP+3
        sta  LC_CONFIG_IP+3
        lda  #$A5
        sta  LC_CONFIG_MG
        lda  #$5A
        sta  LC_CONFIG_MG+1
        lda  LC_ROM_WP
        rts

; ============================================================
;  W5100 / TCP routines
; ============================================================

W5100_INIT:
        lda  #$80
        sta  WBASE
        ldy  #0
        ldx  #0
WI_DLYX:
        inx
        bne  WI_DLYX
WI_DLYY:
        iny
        bne  WI_DLYY
        
        lda  #$03
        sta  WBASE
        lda  #$00
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  LOCAL_GW+0          ; Use LOCAL_GW, not SRV_IP
        sta  W_IDM_DR
        lda  LOCAL_GW+1
        sta  W_IDM_DR
        lda  LOCAL_GW+2
        sta  W_IDM_DR
        lda  LOCAL_GW+3
        sta  W_IDM_DR
        lda  #$00
        sta  W_IDM_AR0
        lda  #$0F
        sta  W_IDM_AR1
        lda  LOCAL_IP+0          ; Use LOCAL_IP, not SRV_IP
        sta  W_IDM_DR
        lda  LOCAL_IP+1
        sta  W_IDM_DR
        lda  LOCAL_IP+2
        sta  W_IDM_DR
        lda  LOCAL_IP+3
        sta  W_IDM_DR
        lda  #$00
        sta  W_IDM_DR
        lda  #$00
        sta  W_IDM_AR0
        lda  #$09
        sta  W_IDM_AR1
        lda  #$00
        sta  W_IDM_DR
        lda  #$08
        sta  W_IDM_DR
        lda  #$DC
        sta  W_IDM_DR
        lda  #$A2
        sta  W_IDM_DR
        lda  #$00
        sta  W_IDM_DR
        lda  #$02
        sta  W_IDM_DR

        lda  #$00
        sta  W_IDM_AR0
        lda  #$1A
        sta  W_IDM_AR1
        lda  #$55
        sta  W_IDM_DR
        lda  #$55
        sta  W_IDM_DR
        rts

TCP_CONNECT:
        lda  #$04
        sta  W_IDM_AR0
        lda  #$00
        sta  W_IDM_AR1
        lda  #$01
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$04
        sta  W_IDM_AR1
        lda  #$0F
        sta  W_IDM_DR
        lda  #$FF
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_OPEN
        sta  W_IDM_DR
        ldx  #200
TC_W1:  jsr  READ_S0_SR
        cmp  #SOCK_INIT
        beq  TC_INIT
        dex
        bne  TC_W1
        sec
        rts
TC_INIT:
        lda  #$04
        sta  W_IDM_AR0
        lda  #$0C
        sta  W_IDM_AR1
        lda  SRV_IP+0
        sta  W_IDM_DR
        lda  SRV_IP+1
        sta  W_IDM_DR
        lda  SRV_IP+2
        sta  W_IDM_DR
        lda  SRV_IP+3
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$10
        sta  W_IDM_AR1
        lda  #$13
        sta  W_IDM_DR
        lda  #$88
        sta  W_IDM_DR
        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_CONNECT
        sta  W_IDM_DR
        ldx  #0
        ldy  #77
TC_W2:  jsr  READ_S0_SR
        cmp  #SOCK_ESTAB
        beq  TC_OK
        inx
        bne  TC_W2
        dey
        bne  TC_W2
        sec
        rts
TC_OK:  clc
        rts

READ_S0_SR:
        lda  #$04
        sta  W_IDM_AR0
        lda  #$03
        sta  W_IDM_AR1
        lda  W_IDM_DR
        rts

TCP_SEND_LINE:
        ldx  #0
TSL_L:  lda  TXBUF,x
        beq  TSL_GL
        inx
        bne  TSL_L
TSL_GL: stx  TMP_A          

        lda  #$04
        sta  W_IDM_AR0
        lda  #$24
        sta  W_IDM_AR1
        lda  W_IDM_DR
        sta  ZP_LO          
        lda  W_IDM_DR
        sta  ZP_HI          

        ldx  #0
TSL_WR: cpx  TMP_A
        beq  TSL_CR
        lda  TXBUF,x
        jsr  TX_BYTE
        inx
        jmp  TSL_WR
TSL_CR: lda  #$0D           
        jsr  TX_BYTE
        lda  #$0A
        jsr  TX_BYTE

        lda  #$04
        sta  W_IDM_AR0
        lda  #$24
        sta  W_IDM_AR1
        lda  ZP_LO          
        sta  W_IDM_DR
        lda  ZP_HI
        sta  W_IDM_DR

        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_SEND
        sta  W_IDM_DR

        ldx  #200
TSL_WT: lda  #$04
        sta  W_IDM_AR0
        lda  #$01        
        sta  W_IDM_AR1
        lda  W_IDM_DR
        beq  TSL_OK      ; If 0, W5100 accepted the command
        jmp  TSL_WT      ; Poll indefinitely until ready
TSL_OK: clc
        rts
TSL_D:  sec
        rts

TX_BYTE:
        sta  TMP_C
        lda  ZP_LO
        and  #$07          
        ora  #TX_BASE_HI   
        sta  W_IDM_AR0
        lda  ZP_HI
        sta  W_IDM_AR1
        lda  TMP_C
        sta  W_IDM_DR      
        inc  ZP_HI
        bne  TXB_R
        inc  ZP_LO
TXB_R:  rts

; ============================================================
;  TRR_READ_BLOCK (Called by Async Loop when data is ready)
; ============================================================
TRR_READ_BLOCK:
        ; Get current S0_RX_RD ($0428) Read Pointer
        lda  #$04
        sta  W_IDM_AR0
        lda  #$28
        sta  W_IDM_AR1
        lda  W_IDM_DR
        sta  ZP_LO          ; High byte
        lda  W_IDM_DR
        sta  ZP_HI          ; Low byte

TRR_LOOP:
        ; Calculate physical address & read byte
        lda  ZP_LO
        and  #$07
        ora  #RX_BASE_HI
        sta  W_IDM_AR0
        lda  ZP_HI
        sta  W_IDM_AR1
        lda  W_IDM_DR
        sta  TMP_C          ; The received character

        ; Increment the logical read pointer
        inc  ZP_HI
        bne  TRR_NO_CARRY
        inc  ZP_LO
TRR_NO_CARRY:

        ; Process the character
        lda  TMP_C
        beq  TRR_SKIP_CHAR
        cmp  #$FF
        beq  TRR_SKIP_CHAR
        cmp  #$0A
        beq  TRR_LF
        cmp  #$0D
        bne  TRR_PRINT
        jmp  TRR_SKIP_CHAR
TRR_PRINT:
        jsr  ULTRA_PUTC
        jmp  TRR_SKIP_CHAR
        
TRR_LF:
        jsr  ULTRA_NEWLINE

TRR_SKIP_CHAR:
        ; Decrement the block size counter 
        lda  RX_CNT_LO
        bne  TRR_DEC_LO
        dec  RX_CNT_HI
TRR_DEC_LO:
        dec  RX_CNT_LO

        ; Loop until size hits zero
        lda  RX_CNT_HI
        ora  RX_CNT_LO
        bne  TRR_LOOP

        ; Write the final advanced pointer back to S0_RX_RD ($0428)
        lda  #$04
        sta  W_IDM_AR0
        lda  #$28
        sta  W_IDM_AR1
        lda  ZP_LO
        sta  W_IDM_DR
        lda  ZP_HI
        sta  W_IDM_DR

        ; Issue the RECV command ($40) ONCE for the entire block
        lda  #$04
        sta  W_IDM_AR0
        lda  #$01
        sta  W_IDM_AR1
        lda  #SCMD_RECV
        sta  W_IDM_DR

        rts

; ── DIAG_PRINT / DIAG_NL ─────────────────────────────────────
DIAG_PRINT:
        jsr  PRINT40
        rts

DIAG_NL:
        lda  #$8D
        jsr  COUT
        rts

DIAG_PUTC:
        ora  #$80
        jsr  COUT
        rts

DIAG_DEC:
        jsr  PDEC40
        rts

PRINT_HEX_BYTE:
        sta  TMP_A
        lsr
        lsr
        lsr
        lsr
        jsr  PRINT_HEX_NIBBLE
        lda  TMP_A
        and  #$0F
        jsr  PRINT_HEX_NIBBLE
        rts

PRINT_HEX_NIBBLE:
        cmp  #10
        bcc  PHN_DIG
        clc
        adc  #'A'-10
        jsr  DIAG_PUTC
        rts
PHN_DIG:
        clc
        adc  #'0'
        jsr  DIAG_PUTC
        rts

RND:
        lsr  ZP_SHI
        ror  ZP_SLO
        bcc  RND_DONE
        lda  ZP_SHI
        eor  #$B4
        sta  ZP_SHI
RND_DONE:
        lda  ZP_SLO
        rts