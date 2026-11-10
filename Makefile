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

.PHONY: all clean test app
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

SWIFTC   := xcrun swiftc
SDK      := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH     ?= $(shell uname -m)
SWIFTFLAGS := -parse-as-library -target $(ARCH)-apple-macos26.0 -sdk $(SDK) \
              -import-objc-header engine/include/mn.h
ENGINE_LINK := $(ENGINE_LIB) $(LDLIBS)
FSKIT_SRC := fskit/Sources/Engine.swift fskit/Sources/BlockDevice.swift fskit/Sources/Volume.swift

# Drives the FSKit volume code directly, without the FSKit daemon.
$(OUT)/volume-harness: $(FSKIT_SRC) fskit/Tests/VolumeHarness.swift $(ENGINE_LIB)
	$(SWIFTC) $(SWIFTFLAGS) $(FSKIT_SRC) fskit/Tests/VolumeHarness.swift $(ENGINE_LINK) -framework FSKit -o $@

# Lists NTFS disks the way the app sees them; `disk-probe mount-rw diskN` tries a remount.
$(OUT)/disk-probe: app/Sources/Disks.swift app/Sources/Mounter.swift app/Tests/DiskProbe.swift
	$(SWIFTC) -parse-as-library -target $(ARCH)-apple-macos26.0 -sdk $(SDK) $^ -framework DiskArbitration -framework FSKit -o $@

app:
	scripts/build-app.sh

$(NTFS3G)/lib/libntfs-3g.a:
	scripts/build-ntfs3g.sh

test: all $(OUT)/volume-harness
	tests/run-harness.sh
	python3 tests/test_cli.py
	@echo '==> again with 4 KiB block alignment (like 4Kn disks / FSKit)'
	MN_ALIGN=4096 python3 tests/test_cli.py

clean:
	rm -rf $(OUT)
