CPPFLAGS:=-I./lua/src
CFLAGS:=--std=c99 -g -Wall -O2 -fPIC

.PHONY: default clean linux-readline lua-linux-readline macosx lua-macosx

default:
	@echo "Please do 'make PLATFORM' where PLATFORM is one of these:"
	@echo "  linux-readline linux-noreadline macosx"

clean:
	cd lua/src && $(MAKE) clean
	rm -f ./runtime/*.o ./runtime/*.a

linux-readline:   runtime/pallenelib.a lua-linux-readline
linux-noreadline: runtime/pallenelib.a lua-linux-noreadline
macosx:           runtime/pallenelib.a lua-macosx

lua-linux-readline:
	cd lua/src && $(MAKE) linux-readline

lua-linux-noreadline:
	cd lua/src && $(MAKE) linux-noreadline

lua-macosx:
	cd lua/src && $(MAKE) macosx

runtime/pallene_core.o: runtime/pallene_core.c runtime/pallene_core.h

runtime/pallenelib.a: runtime/pallene_core.o
	$(AR) rc $@ $^
	ranlib $@
