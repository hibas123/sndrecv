.PHONY: default run

default: sndrecv

sndrecv: sndrecv.zig
		zig build-exe -lc -lpulse -I /usr/include sndrecv.zig

run: sndrecv
		./sndrecv