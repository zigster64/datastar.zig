# Zig 0.16-dev Benchmark

![Cyberpunk Benchmark - Sydney Graffiti - Leica M3 with infrared film](../assets/benchmarks.jpg)

To build - run `make`

That produces four binaries — two IO backends × two optimization modes:

| Binary                        | IO backend                       | Optimize       |
| ----------------------------- | -------------------------------- | -------------- |
| `bench-zig-0.16-fast`         | stdlib `Io.Threaded` (default)   | `ReleaseFast`  |
| `bench-zig-0.16-debug`        | stdlib `Io.Threaded` (default)   | `Debug`        |
| `bench-zig-0.16-zio-fast`     | [`lalinsky/zio`](https://github.com/lalinsky/zio) stackful coroutines | `ReleaseFast` |
| `bench-zig-0.16-zio-debug`    | [`lalinsky/zio`](https://github.com/lalinsky/zio) stackful coroutines | `Debug` |

On startup each binary prints its backend, e.g.:

```
IO backend: std Io.Threaded            # default build
IO backend: zio (stackful coroutines)  # -Dio=zio build
```

The backend is selected at build time via the `-Dio=` flag exposed by `build.zig`:

```bash
zig build                                            # default: -Dio=std
zig build -Dio=zio                                   # use zio
zig build -Dio=zio -Doptimize=ReleaseFast            # release build with zio
make zio                                             # only (re)build the zio variants
```

Both variants serve the same routes on `:8090` and are interchangeable from `wrk`'s point of view — they just differ in how the server's IO suspends underneath. The point of the zio variant is to measure the cost/benefit of swapping `Io.Threaded` for stackful coroutines on the same workload.

Then run the benchmark.

This benchmark is compatible with

https://github.com/zigster64/datastar.http.zig/tree/main/bench

... so it provides some numbers for comparison with the (more mature) datastar.http.zig SDK

Use `wrk -t12 -c400 -d10s http://localhost:8090/sse` to get some bench numbers

All figures below are on a lightweight Mac M2 Pro with 16GB RAM. Will add some extra rows later for Ryzen 9900x on Linux + io-uring

| Language | Test Case | Requests/sec | Latency (Avg) | Latency (Stddev) | Latency (Max) | Transfer/sec |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig 0.16 std (Debug)** | Plain HTML                    | 31,797     | 5.63ms       | 3.05ms       | 94.37ms        | **4.50 GB** |
| **Zig 0.16 std (Debug)** | **Datastar SSE** 100k payload | **27,453** | **5.57ms**  | **4.28ms**  | **74.16ms**   | 4.76 GB    |
| **Zig 0.16 std (Debug)** | SSE % performance             |            |              |              |                | 86 %        |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig 0.16 std (Fast)** | Plain HTML                    | 31,409     | 5.00ms       | 2.81ms       | 57.41ms        | **4.45 GB** |
| **Zig 0.16 std (Fast)** | **Datastar SSE** 100k payload | **14,481** | **15.27ms**  | **25.20ms**  | **516.95ms**   | 2.51 GB    |
| **Zig 0.16 std (Fast)** | SSE % performance             |            |              |              |                | 46 %        |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig 0.16 zio (Debug)** | Plain HTML                    | 32,376     | 5.68ms       | 2.68ms       | 56.07ms        | **4.58 GB** |
| **Zig 0.16 zio (Debug)** | **Datastar SSE** 100k payload | **13,706** | **17.36ms**  | **0.91ms**   | **37.32ms**    | 2.38 GB    |
| **Zig 0.16 zio (Debug)** | SSE % performance             |            |              |              |                | 42 %        |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig 0.16 zio (Fast)** | Plain HTML                    | 32,462     | 5.67ms       | 3.41ms       | 144.96ms       | **4.59 GB** |
| **Zig 0.16 zio (Fast)** | **Datastar SSE** 100k payload | **27,299** | **7.55ms**  | **8.68ms**  | **141.15ms**   | 4.73 GB    |
| **Zig 0.16 zio (Fast)** | Plain HTML 1k                 | 92,261     | 2.57ms       | 144.65µs     | 11.95ms        | 114.65 MB  |
| **Zig 0.16 zio (Fast)** | **Datastar SSE** 1k payload   | **90,979** | **2.61ms**  | **127.50µs** | **9.96ms**     | 156.52 MB  |
| **Zig 0.16 zio (Fast)** | SSE % performance (100k)      |            |              |              |                | 84 %        |
| **Zig 0.16 zio (Fast)** | SSE % performance (1k)        |            |              |              |                | 99 %        |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |

With the previous release - before the optimizations, got these figures

| Language | Test Case | Requests/sec | Latency (Avg) | Latency (Stddev) | Latency (Max) | Transfer/sec | Binary/RAM Size |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig 0.16 std (Fast)**  | Plain HTML                    | 30,799     | 10.34ms      | 9.33ms       | 259.79ms       | **4.36 GB** | 665,432   |
| **Zig 0.16 std (Fast)**  | **Datastar SSE** 100k payload | **24,750** | **17.08ms**  | **16.49ms**  | **241.07ms**   | 4.29 GB    | 665,432   |
| **Zig 0.16 std (Fast)**  | SSE % performance             |            |              |              |                | 80 %        |           |
| | | | | | | | |
| **Zig 0.16 std (Debug)** | Plain HTML                    | 31,266     | 14.39ms      | 21.59ms      | 408.34ms       | **4.43 GB** | 2,557,640 |
| **Zig 0.16 std (Debug)** | **Datastar SSE** 100k payload | **12,443** | **31.49ms**  | **36.29ms**  | **303.23ms**   | 2.16 GB    | 2,557,640 |
| **Zig 0.16 std (Debug)** | SSE % performance             |            |              |              |                | 40 %        |           |
| | | | | | | | |
| **Zig 0.16 zio (Fast)**  | Plain HTML                    | 30,641     | 8.54ms       | 3.55ms       | 46.82ms        | **4.34 GB** | 875,496   |
| **Zig 0.16 zio (Fast)**  | **Datastar SSE** 100k payload | **25,248** | **15.18ms**  | **4.30ms**   | **58.40ms**    | 4.38 GB    | 875,496   |
| **Zig 0.16 zio (Fast)**  | SSE % performance             |            |              |              |                | 82 %        |           |
| | | | | | | | |
| **Zig 0.16 zio (Debug)** | Plain HTML                    | 30,696     | 8.43ms       | 5.53ms       | 102.03ms       | **4.35 GB** | 3,208,744 |
| **Zig 0.16 zio (Debug)** | **Datastar SSE** 100k payload | **11,811** | **33.25ms**  | **3.05ms**   | **63.09ms**    | 2.05 GB    | 3,208,744 |
| **Zig 0.16 zio (Debug)** | SSE % performance             |            |              |              |                | 39 %        |           |
| | | | | | | | |


Older benchmark numbers on a different day / different setup. Useful for comparison within the same set of runs, but
dont expect to make useful comparisons between different test runs.

| Language | Test Case | Requests/sec | Latency (Avg) | Transfer/sec | Binary/RAM Size |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Zig-0.15.2** | Plain HTML | 39,654 | 5.50ms | **5.61 GB** | 533,672 |
| **Zig-0.15.2** | **Datastar SSE** 100k payload | **23,777** | **15.99ms** | 4.12 GB | 12.7 MB  |
| **Zig-0.15.2** | SSE % performance | |  | 73 % | |
| | | | | | |
| **Zig 0.16-dev** | Plain HTML | 41,606 | 4.28ms | **5.89 GB** | 487,976 |
| **Zig 0.16-dev** | **Datastar SSE** 100k payload | **28,275** | **11.50ms** | 4.90 GB | 21.5 MB  |
| **Zig 0.16-dev** | SSE % performance | |  | 67  % | |
| | | | | | |
| **Zig 0.16-dev Fibers** | Plain HTML | 40,243 | 137.6us | **5.70 GB** | 665,896 |
| **Zig 0.16-dev Fibers** | **Datastar SSE** 100k payload | **26,996** | **237.5us** | 4.68 GB | 17.1 MB  |
| **Zig 0.16-dev Fibers** | SSE % performance | |  | 67  % | |
| | | | | | |
| **Rust** | Plain HTML | 38,201 | 5.13ms | **5.41 GB** | 1,845,936 |
| **Rust** | **Datastar SSE** 100k payload | **20,943** | **11.43ms** | 3.63 GB | 40.2 MB |
| **Rust** | SSE % performance | |  | 67 % | |
| | | | | | |
| **Go** | Plain HTML (no log)| 30,484 | 8.76ms | 4.32 GB | 7,995,922 |
| **Go** | Plain HTML | 23,730 | 11.89ms | 3.36 GB | 7,995,922 |
| **Go** | Datastar SSE 100k payload | 9,758 | 33.72ms | 1.69 GB | 43.8 MB |
| **Go** | SSE % performance | |  | 50 % | |
| | | | | | |
| **Bun** | Plain HTML (no Log) | 28,667 | 8.30ms | 4.06 GB | n/a |
| **Bun** | Plain HTML | 12,664 | 18.81ms | 1.79 GB | n/a |
| **Bun** | Datastar SSE (100k w/ Log) | 3,733 | 63.7ms | 662.85 MB | 32.3 MB |
| **Bun** | SSE % performance | |  | 36 % | |

# Why is SSE slower than straight HTML ?

Combination of things

- The SSE version has some CPU and Memory Allocation overhead to split up 100k of HTML into SSE event stream format, and apply chunked encoding.
- The behaviour of HTTP/1.1 keepalives with text/event-stream + chunked encoding.

With text/event-stream - when a browser sees a response of this type, with chunked encoding, it will consider that the current Tcp/IP connection 
is in use, so will route further requests through a new connection. With straight text/html + known content-length, browsers will exploit the 
HTTP/1.1 keepalive protocol to stream additional requests onto the existing network connection. So there is definitely some extra network overhead there. 
Exactly how much, I dont know.

I dont know if `wrk` conforms to that, or not either.

Would have to do some serious instrumenting to find out where the time is spent, but its probably a combination of all of the above.

The fact that its consistent across the board will different languages and SDKs suggests the numbers are pretty correct though.

# Peak RSS / allocation

`zig build peak-rss` (from the repo root) isolates each `(mode × placement × size)` in its own child process and reports:

| column | meaning |
| --- | --- |
| `rss_delta` | `ru_maxrss` after framing minus after fragment touch |
| `req_bytes` | bytes requested through a counting allocator during framing |
| `arena_cap` | `ArenaAllocator.queryCapacity` growth during framing |

Modes: `ladder` (Allocating from zero in the arena), `alloc` (`patchElementsAlloc`), `stream` (`patchElements` into a discarding writer).

On the measured 4.7 MB in-arena shape, streaming requests **0** framing bytes; the ladder still requests ~12× the fragment.
