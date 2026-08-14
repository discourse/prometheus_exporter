# Transport benchmark

Run the end-to-end benchmark from a clean checkout with:

```sh
bundle install
RECORDS=10000 RUNS=3 bundle exec ruby -Ilib bench/bench.rb
```

It reports enqueue time and enqueue-to-final-client-acknowledgement time for each run. The timer stops only after the client has read the final HTTP response, not when the collector first sees the record. Each record is JSON-serialized, sent as its own HTTP request, acknowledged, and processed by the collector. The client reuses its persistent HTTP/1.1 connection when `Net::HTTP` determines that reuse is safe. The server asks the operating system for a port by binding directly to port `0`.

For a reproducible comparison:

1. Use separate worktrees for the revisions being compared.
2. Run the same Ruby version, dependency lock, `RECORDS`, and `RUNS` in each worktree.
3. Run on the same otherwise-idle host; record CPU, operating system, Ruby, Puma, TLS, and network setup.
4. Include warm-up runs, then report every measured run and the aggregation method rather than selecting a single result.
5. For cross-protocol comparisons, use a benchmark driver appropriate to each revision and keep the generated record and collector work equivalent.

A quick smoke run is:

```sh
RECORDS=10 RUNS=1 bundle exec ruby -Ilib bench/bench.rb
```

## 3.0 transport comparison

Measured on 2026-07-23 using Ruby 3.4.10 with YJIT disabled, Puma 8.0.2, WEBrick 1.9.2, Linux, an Intel i9-14900K, loopback networking, no TLS, and approximately 255-byte JSON records. Each result is the median of seven measured runs after two warm-up runs.

| Stack | Median throughput | Measured range | CPU per metric |
| --- | ---: | ---: | ---: |
| 2.3 client and WEBrick server, long-lived chunked POST | 14,285 metrics/s | 12,831–15,207 | 94.1 µs |
| 3.0 client and Puma server, one POST per metric | 12,363 metrics/s | 7,286–12,889 | 81.0 µs |

The Puma transport was 13.5% slower by median throughput in the full client/server benchmark while using 13.9% less total CPU per metric. An isolated transport benchmark which reproduced the old client's four socket writes per chunk measured 15,817 metrics/s for WEBrick versus 13,193 metrics/s for Puma requests, a 16.6% throughput reduction.

A mixed deployment has a separate and much larger effect. The 3.0 client talking to the old WEBrick server measured only 24 requests/s over a persistent connection. WEBrick writes the response headers and two-byte `OK` body separately; Nagle's algorithm and delayed acknowledgements then introduce an approximately 41 ms stall per request. Returning an empty response body removes that stall, but released 2.x servers return `OK`. This is why the README recommends upgrading the exporter server before its producers.
