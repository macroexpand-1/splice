# Canary Statistics

Each canary stage runs sequential tests that look only for harm from the new code, on errors and on latency.
This chapter explains what is scored, how a stage rejects or passes, what the defaults cost in traffic, and where the tests are weak.
The formulas and internals are in [Details](#details).

## What Is Scored

Every task that runs inside `with-task` reports one outcome to each patch set it is pinned to.
Pinning is covered in [Tasks and Routing](tasks-and-routing.md).
An outcome carries the route (`:old` or `:new`), whether the task failed, and its latency in milliseconds.

Tasks on both routes are scored.
The old route is the control arm, and the new route is the treatment arm.
A task fails when it raises an error.
New code that failed and fell back to old code still counts as a failure on the new route, even though the caller got an answer.

## Two Signals

Each stage runs one test per signal.

| Signal | An Event Is | Below 100% | At 100% |
| --- | --- | --- | --- |
| Errors | A failed task | Which arm the failure landed in | Against the control failure rate |
| Latency | A task slower than the control p95 | Which arm the slow task landed in | No test |

Below 100% both tests are two-sample; at 100% the error test is one-sample.
The error test runs from the first observation.
The latency test starts once 30 control tasks have been seen.

## When a Stage Rejects

Below 100%, each test asks which arm each event landed in.
If the new code is no worse, the new arm's share of events matches its share of traffic.
At a 5% stage, about 5% of failures should come from new code.
A stage rejects when the new arm takes clearly more than its share.

Tasks without an event are ignored.
A burst that hits both arms, such as a wave of upstream timeouts, moves both arms together, so the share does not move.
The test counts only harm, so it never rejects because the new code is better.

Splice checks the verdict after every observation, and that does not inflate the false-reject rate.
The set's `alpha` caps the chance of any spurious rollback over the whole session.

At 100% there is no control arm.
The error test then compares new-arm failures with the control failure rate from earlier stages.
There is no latency test at 100%; [The One-Sample Test](#the-one-sample-test) explains why.

## When a Stage Passes

A stage passes after it scores its budget of new-arm observations without a reject.
There is no early accept on strong evidence of no harm.
New-arm observations do not count toward the budget until the latency test starts.

The budget is sized on latency.
It is the number of new-arm observations needed to catch a slowdown of exactly `min-effect` with probability `1 - beta`.

A stage that reaches `stage-limit` new-arm observations (40,000 by default) without passing ends in a stage timeout.
A stage timeout freezes the set by default.
See [The Lifecycle](lifecycle.md) for what each verdict does.

## What the Defaults Cost

These budgets come from `stage-budget`, evaluated in SBCL:

| Options | Budgets per Stage |
| --- | --- |
| Defaults | 9,793 / 12,463 / 9,937 |
| Defaults with min-effect 1.0 | 1,100 / 1,413 / 1,152 |
| Ramp `(50 100)` with min-effect 3.0 | 357 / 201 |

The defaults are ramp `(5 25 100)`, alpha 0.01, beta 0.05, and min-effect 0.3.

The budget counts new-arm observations, not tasks.
At a 5% stage, 9,793 new-arm observations take about 196,000 tasks.

## Choosing Options

Each option trades traffic for sensitivity.
All of them are set per set in `defpatch-set` (see [Patch Sets](patch-sets.md)).

- `min-effect` is the smallest slowdown or error increase worth catching, as a fraction: 0.3 means 1.3x.
  Raising it shrinks budgets fast, as the table shows.
- `alpha` is the chance of rolling back healthy code over the whole session.
  Lowering it raises the threshold and the budgets, but only through a logarithm.
- `beta` is the chance of passing a stage that is exactly `min-effect` worse on latency.
  Lowering it raises the budgets.
- `ramp` sets the stages.
  A small first stage limits exposure but needs many more tasks to fill its budget.
  Each extra stage also raises every test's threshold, since `alpha` is split across more stages.
- `stage-limit` must sit well above the largest budget.
  Unscored observations count toward the limit but not toward the budget.

For a service with little traffic, a short ramp and a large `min-effect` keep a rollout to a few hundred tasks per stage.
The cost is that only gross regressions are caught.

## Limitations

**Low error power at low base rates.**
The budget is sized on latency, whose event rate is 5%.
Failures are much rarer, so the error test sees few events in the same budget.
In a simulation of the error test alone with default options, a 1.3x error increase on a 1% base rate was caught in about 15% of 5% stages.
The same simulation caught it in 17% of 25% stages, 24% of 100% stages, and about half of whole sessions.

**Exchangeable observations.**
The tests treat observations as exchangeable, while real traffic is bursty and correlated.
A burst that hits one arm more than the other can push the test toward a reject.
One customer whose tasks happen to route new is such a burst.

**No latency guard at 100%.**
A slowdown that only appears at full traffic is not caught by the canary.

**A stale error null at 100%.**
The 100% error test compares against control traffic from earlier stages.
A shift in the base error rate between periods can look like harm or hide it.

## Why Not Wald's SPRT

Wald's sequential probability ratio test compares two fixed hypotheses.
For a canary that means guessing the baseline error rate and naming one specific bad rate for each stage.
Its error bounds assume the baseline holds for the whole stage.

Real traffic has bursts: an upstream outage raises the error rate for minutes.
A burst within a stage looks like harm to Wald's test, and its bounds no longer hold.

The mixture test takes its baseline from the control arm, measured on the same traffic at the same moment.
A burst that hits both arms equally moves nothing, because the test only asks which arm each event landed in.
It spreads its weight over a range of harm ratios instead of naming one.
Its bound holds under continuous monitoring.

## Details

### Scoring

A fallback from new code to old code never counts against `:old`.
Latency is the task body's own time.
The timer stops before the task releases its pins, so time spent waiting on the set lock is not counted.

### The Latency Threshold

The latency threshold is the 95th percentile of control latencies.
It comes from a ring of the last 5,000 control tasks (`*null-ring-size*`, internal).
The threshold is fixed once per stage, on the first observation after the ring holds 30 samples.
Until then the latency test does not exist.

### The Mixture Test

Both two-sample tests share one null: the new code is no worse, so an event is equally likely per task on either arm.
Under that null, the share of events that land on the new arm equals the new arm's traffic share.
An event on the new arm is a hit; an event on the control arm is a miss.

The test compares "no harm" against eight harm ratios at once.
With `m` the set's `min-effect`, the ratios are `(1+m)^(j/2)` for `j` from 1 to 8.
At the default `m = 0.3` they run from about 1.14 to 2.86, and the second one is exactly 1.3.
For a null share `s` and ratio `r`, the hit probability under harm is `s*r / (1 - s + s*r)`.

The test's statistic is the average of the eight likelihood ratios, kept as log odds:

```
LR_r      = (p_r / s)^hits * ((1 - p_r) / (1 - s))^misses
log odds  = log( mean of LR_r over the eight ratios )
reject    when log odds >= log(2k / alpha)
```

### The Reject Threshold

Here `alpha` is the set's whole false-rollback budget and `k` is the number of ramp stages.
A session runs at most two tests per stage, so each test gets `alpha/(2k)`.
By the union bound, the chance of any spurious rollback in the session stays at most `alpha`.
With the defaults (`alpha` 0.01, three stages) a test rejects when the mixture's likelihood ratio reaches 600.

The bound holds however often the test is looked at.
This is the anytime-valid property proved by Lindon and Malek for the point null (see [References](#references)).
Splice's mixture is its own extension of their test: a discrete mixture over harm ratios only.

### The One-Sample Test

At 100% the error test is one-sample: each new-arm observation is a hit if it failed and a miss otherwise.
Its null share is the control failure rate over the 5,000-task ring, floored at 0.001.
While the ring holds fewer than 30 samples, the null share is 0.001.
The same mixture and threshold apply.

There is no latency test at 100%, because its null would have to come from an earlier period of traffic.
For the same code, the latency tail of tiny tasks drifts by up to 2x between periods.
That drift is larger than the effect the test looks for, so a one-sample latency test would roll back healthy code.

### The Budget Formula

The budget is sized on the latency signal, where the event rate is 5% on the control arm by construction.
It is the smallest `n` at which the min-effect component of the mixture crosses the reject threshold with probability `1 - beta`, by a normal approximation:

```
n * mean - z * sqrt(n * variance) >= log(2k / alpha) + log 8
```

- `mean` and `variance` are the per-observation drift of the log likelihood ratio at ratio `1 + m`.
- `z` is the one-sided normal quantile for `beta`.
- `log 8` pays for that component carrying one eighth of the mixture's weight.

`beta` must be one of 0.2, 0.1, 0.05, or 0.01; any other value signals an error.
The 100% stage has no latency test, so its budget is a soak of the size a one-sample latency test would need.

## API

These functions are exported for anyone who wants to run the test outside a rollout.

| Function | Purpose |
| --- | --- |
| `make-mixture-test` | Build a test |
| `mixture-observe` | Fold in one observation and return the verdict |
| `mixture-verdict` | Return `:reject` or `:continue` |
| `mixture-log-odds` | Return the current log odds |
| `stage-budget` | Return a stage's budget of new-arm observations |

`(make-mixture-test kind null-share &key alpha stage-count min-effect)` builds a test.
`kind` is `:two-sample` or `:one-sample`.
For `:two-sample`, `null-share` is the new arm's traffic share; for `:one-sample`, it is the control event rate.
`null-share` must lie strictly between 0 and 1.
`alpha` is the whole session's, and `stage-count` must be a positive integer.

`(mixture-observe test route event-p)` takes `:new` or `:old` as the route and returns the verdict after the observation.

`(stage-budget fraction &key alpha stage-count beta min-effect)` takes the stage's percentage.

```lisp
(let ((test (splice:make-mixture-test :two-sample 0.05d0
                                      :alpha 0.01d0 :stage-count 3 :min-effect 0.3d0)))
  (splice:mixture-observe test :new t)     ; => :continue
  (splice:mixture-log-odds test))

(splice:stage-budget 5 :alpha 0.01d0 :stage-count 3 :beta 0.05d0 :min-effect 0.3d0)
;; => 9793
```

## References

Michael Lindon and Alan Malek, "Anytime-Valid Inference for Multinomial Count Data", [arXiv 2011.03567v2](https://arxiv.org/abs/2011.03567v2).
Section 2 gives the mixture and its `1/u` bound.
Section 3 shows why the arm an event lands in ignores a shared, time-varying rate.
The pinned citation is [Lindon and Malek 2020](../docs/reference/external/lindon-malek-2020-anytime-valid-multinomial.md).

Michael Lindon, Chris Sanden, and Vaché Shirikian, "Rapid Regression Detection in Software Deployments Through Sequential Testing", KDD 2022.
It is the canary-testing context for splice's verdicts.
The pinned citation is [Lindon et al. 2022](../docs/reference/external/lindon-2022-rapid-regression-detection.md).

The harm-only discrete mixture and the stage budget's normal approximation are splice's own.
