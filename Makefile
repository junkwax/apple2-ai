CA65  = ca65
LD65  = ld65
CFG   = apple2chat.cfg

SRCDIR  = src
BLDDIR  = build

SRC  = $(SRCDIR)/apple2-ai.s
OBJ  = $(BLDDIR)/apple2-ai.o
BIN  = $(BLDDIR)/APPLE2AI.BIN

.PHONY: all clean

all: $(BIN)

$(BLDDIR):
	mkdir -p $(BLDDIR)

$(OBJ): $(SRC) | $(BLDDIR)
	$(CA65) $< -o $@

$(BIN): $(OBJ) $(CFG)
	$(LD65) -C $(CFG) $< -o $@

clean:
	rm -rf $(BLDDIR)
