# MAC_NTFS: engine library + CLI.
# Run scripts/build-ntfs3g.sh once first to build libntfs-3g.

NTFS3G   := build/ntfs-3g/prefix
OUT      := build/out

CC       ?= clang
CFLAGS   ?= -O2 -g
CFLAGS   += -std=gnu11 -Wall -Wextra -Wno-unused-parameter
# libntfs-3g's public headers expect these autoconf results.
NTFSDEFS := -DHAVE_STDINT_H=1 -DHAVE_SYS_TYPES_H=1 -DHAVE_STDIO_H=1 \
            -DHAVE_SYS_PARAM_H=1 -DHAVE_STDLIB_H=1 -DHAVE_STRING_H=1 -DHAVE_ERRNO_H=1 -DHAVE_SYS_STAT_H=1
CPPFLAGS += -Iengine/include -I$(NTFS3G)/include $(NTFSDEFS)
LDLIBS   += $(NTFS3G)/lib/libntfs-3g.a -framework CoreFoundation

ENGINE_SRC := $(wildcard engine/src/*.c)
ENGINE_OBJ := $(ENGINE_SRC:engine/src/%.c=$(OUT)/engine/%.o)
ENGINE_LIB := $(OUT)/libmn.a

.PHONY: all clean test
all: $(OUT)/macntfs $(OUT)/test-set-dirty

$(OUT)/engine/%.o: engine/src/%.c engine/include/mn.h $(NTFS3G)/lib/libntfs-3g.a
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(ENGINE_LIB): $(ENGINE_OBJ)
	@rm -f $@
	ar rcs $@ $^

$(OUT)/macntfs: cli/macntfs.c $(ENGINE_LIB)
	@mkdir -p $(dir $@)
	$(CC) -Iengine/include $(CFLAGS) $< $(ENGINE_LIB) $(LDLIBS) -o $@

$(OUT)/test-set-dirty: tests/set-dirty.c $(NTFS3G)/lib/libntfs-3g.a
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(LDLIBS) -o $@

$(NTFS3G)/lib/libntfs-3g.a:
	scripts/build-ntfs3g.sh

test: all
	python3 tests/test_cli.py -v

clean:
	rm -rf $(OUT)
