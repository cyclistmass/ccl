# wb-bench.lisp — multi-thread microbenchmarks for the arm64 write barrier

This is the harness behind the numbers in the `stlxr` write-barrier pull
request. It is here so those numbers can be checked on other hardware rather
than taken on trust.

It needs nothing but a built CCL. No build system, no scripts, no configuration.

## Running it

```
$ ./arm64cl --image-name arm64-boot.image < wb-bench.lisp
```

Every line it prints starts with `P| `. Two kinds:

```
P| BENCH=WB-1T-YOUNG NT=1 REP=3 NS=14500000 OPS=1000000 NSOP=14.5
P| SUMMARY BENCH=WB-1T-YOUNG NT=1 REPS=5 MEDIAN_NSOP=14.5 SPREAD_PCT=3.3
```

`NSOP` is nanoseconds per operation. Read the `SUMMARY` lines; the per-rep
lines are there so you can see the spread rather than trust a median.

It ends with `P| DONE wb-bench`. If that line is missing the run did not finish
and nothing above it is a complete result.

## What each bench measures

| bench | what it exercises |
|---|---|
| `WB-1T-YOUNG` | storing a young pointer into an old object: the memoize path |
| `WB-2T-NEAR` | the same, two threads hitting adjacent refbits words |
| `WB-2T-FAR` | the same, two threads far apart in the bitmap |
| `WB-1T-OLD`, `WB-1T-FIXNUM` | stores that exit BEFORE the memoize loop |
| `ALLOC-*` | allocation, one and two threads |
| `LOCK-*` | `with-lock-grabbed`, contended and not |
| `ATOMIC-*` | `atomic-incf`, including a deliberate false-sharing case |
| `SEM-PINGPONG` | semaphore round trip |

Only the first three rows can move when the memoize loops change. Everything
else is a control, and the two `WB-1T-OLD` / `WB-1T-FIXNUM` rows are the
sharpest ones: they are the same store path up to the point where it decides no
memoize is needed.

## Reading it — three things that cost us real time

**1. Compare absolute nanoseconds, not percentages.** A barrier costs a fixed
number of cycles, so removing one is a constant ns saving on the paths that ran
it. `WB-1T-FIXNUM` runs at about 1.2 ns, which is three or four cycles and close
to the timer's resolution, so one quantum there reads as 15 percent while the
same quantum on the 14.5 ns memoize bench reads as 1.4 percent. Judged in
percent, the controls look like they moved more than the thing under test, and a
real effect reads as drift. In nanoseconds the controls sit inside 0.2 ns and
the effect is unambiguous.

**2. Interleave the arms, and run each at least twice.** A single A-then-B pass
cannot separate an effect from a machine that got faster between runs. Run
A, B, A, B and require both A→B steps to agree. If they disagree it was drift.

**3. Check that the two builds really differ.** Verify the kernel binary's md5
changes between arms. A build system that decides the sources are unchanged will
happily hand the same binary to both halves, and then the patch looks inert and
the benchmark looks noisy. This bit us twice: once when the second arm reused
the first arm's binary, and once more after a fix that turned out not to cover
the case where the request was a superset of what the binary was built with.

## Reporting a number

State the machine and the clock, because nanoseconds mean nothing without them.
Ours: Neoverse V3, CPU part `0xd84`, two cores, clock measured at 3.29 GHz with
the PMU cycle counter over a three-second spin, so one cycle is 0.304 ns. That
is what makes 14.5 ns and 47.7 cycles the same statement.

## Caveat

These are microbenchmarks. They measure the cost of one operation in a loop,
which is the right instrument for "what does this instruction sequence cost" and
the wrong one for "is the system faster". They also cannot certify a
memory-ordering change in either direction; only reasoning about the algorithm
can do that.
