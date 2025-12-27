all:
	@echo Timing of Building Binaries ...
	time zig build -Doptimize=ReleaseFast -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16
	@echo
	@echo Results from build ...
	@ls -ltra bench-zig-0.16
	@echo
	@echo "To run Zig  : ./bench-zig-0.16"

clean:
	@echo Cleaning Up ...
	rm -rf zig-out .zig-cache bench-zig-0.16
