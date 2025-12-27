# Zig 0.16-dev Benchmark

To build - run `make`

Then run the benchmark

This benchmark is compatible with

https://github.com/zigster64/datastar.http.zig/tree/main/bench

... so it provides some numbers for comparison with the (more mature) datastar.http.zig SDK

Use `wrk -t12 -c400 -d10s http://localhost:8090/sse` to get some bench numbers
