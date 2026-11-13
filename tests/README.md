# Validation Suite

## Build

(Requires Zig 0.17)

```
zig build
```
This will build the validation-test program

## Run Backend for Testing

```
./zig-out/bin/validation-test
```
This will run a server on port 7331 that exersizes the backend for the validation suite

## Run test client to hit the valiation suite backend

(Requires Go)

```
go run github.com/starfederation/datastar/sdk/tests/cmd/datastar-sdk-tests@latest
```
This will run the official Datastar SDK tester against the Zig SDK validation suite

# Local Stress Testing

You can use the Lua script in here to get summary stats for running wrk against an SSE endpoint
that otherwise isnt reported by wrk

`wrk -t1 -c100 -s ./tests/sse-test.lua -d10s http://localhost:8082/cats`
