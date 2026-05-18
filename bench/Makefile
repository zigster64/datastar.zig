all:
	@echo Timing of Building Binaries ...
	time zig build -Doptimize=ReleaseFast -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-fast
	time zig build -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-debug
	@echo
	@echo Timing of Building zio variant ...
	time zig build -Dio=zio -Doptimize=ReleaseFast -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-zio-fast
	time zig build -Dio=zio -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-zio-debug
	@echo
	@echo Results from build ...
	@ls -ltra bench-zig-0.16-*
	@echo
	@echo "To run Zig (Io.Threaded) : ./bench-zig-0.16-fast"
	@echo "To run Zig (zio)         : ./bench-zig-0.16-zio-fast"

zio:
	@echo Building zio variants only ...
	time zig build -Dio=zio -Doptimize=ReleaseFast -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-zio-fast
	time zig build -Dio=zio -freference-trace=6
	@mv zig-out/bin/bench bench-zig-0.16-zio-debug

clean:
	@echo Cleaning Up ...
	rm -rf zig-out .zig-cache bench-zig-0.16-*
