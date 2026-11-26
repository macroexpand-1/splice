# Tasks and Routing

A task is the unit splice routes and scores: one request, job, or message, wrapped in `with-task`.
This chapter covers the shims that do the routing, how a task's route is chosen, what a task reports, and the call sites a shim cannot reach.

## Shims

`install` replaces each patched function and method with a shim.
A shim holds the old and the new code and sends each call to one of them.
On each call it looks up the route the current task is pinned to for this set, `:new` or `:old`.

On rollback the old code goes back, and on promotion the new code takes over.
After either, no shim remains, and calls pay no routing cost.
How each kind of shim is built is under [Shim Mechanics](#shim-mechanics).

## Tasks

```lisp
(splice:with-task (:id (order-id order))
  (price-order order)
  (apply-discount order)
  (total-invoice order))
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `:id` | A fresh integer from a counter | The task's identity, for routing and the audit log |
| `:swallow-errors` | `nil` | When true, an error ends the task and `with-task` returns `nil` |

`with-task` returns the values of its body.
An error in the body is always scored as a failure.
Without `:swallow-errors`, it then propagates.

`*task-id*` holds the current task's id, and `nil` outside a task.
A `with-task` nested inside another is a separate task with its own id, pins, and outcome.

## Route Choice

When a task starts, it pins one route for every active set.
A set is active while it is in a canary stage, promoting, rolling back, or frozen.

| Set State | Route Pinned |
| --- | --- |
| A canary stage such as `:canary-25` | `:new` or `:old` by a draw |
| `:promoting` or `:swapping` | `:new` |
| `:rolling-back`, `:restoring`, or `:frozen` | `:old` |

The draw is a deterministic hash of the task id and the set name (see [The Draw](#the-draw)).
That gives it three properties:

- Across many distinct ids the draws spread close to uniformly over 0 to 99, so a 25% stage routes about a quarter of tasks to new code.
- The same id and set name give the same draw in any image, so the audit log can be checked offline.
- A task on new code at one stage stays on new code at every later, larger stage.

Reusing one id for many tasks gives them all the same route.
Pass an id that differs per task, or leave `:id` out.

### Pinning

A pin lasts for the task's whole life.
A task sees only old or only new code from a set, even when the stage changes or a rollback starts mid-task.
A rollback waits for the tasks pinned to new code to finish before it restores old code; see [The Lifecycle](lifecycle.md).

A set that becomes active after a task started has no pin for that task, so the task gets old code from it.
Code outside any task, such as a background thread or a REPL call, gets old code from every set until promotion.
After promotion the new code is the global definition, so everyone gets it.

### Reading the Route

| Function | Takes | Returns |
| --- | --- | --- |
| `current-route` | A set name | `:new` or `:old` for the current task |
| `task-route-for` | A `patch-set` object | `:new` or `:old` for the current task |

Both return `:old` outside a task, and for a set the task holds no pin on.
`current-route` signals `unknown-patch-set` for a name nothing registered.

```lisp
(splice:with-task (:id 42)
  (splice:current-route 'flat-rate-shipping))
;; => :NEW or :OLD, the same answer every time for id 42
```

## Outcomes

When a task ends, `with-task` reports one outcome to every set it pinned.
An outcome is two facts: whether the task failed, and its latency.

The task failed when an error reached `with-task` from its body.
An error the body handles itself is not a failure.
An error counts even when a handler outside `with-task` later recovers from it.

Latency is the body's run time in milliseconds.

Outcomes on old code feed the control baseline.
Outcomes on new code feed the stage's tests and may move the set to its next stage, promotion, or rollback.
The tests themselves are covered in [Canary Statistics](canary-statistics.md).

Every 50th task with an integer id writes its pins to [The Audit Log](audit-log.md).

### Reporting Directly

```lisp
(splice:report-outcome set route failure-p latency-ms)
```

`report-outcome` is what `with-task` calls for each pin.
A harness that scores work outside `with-task` can call it directly.
`set` is a `patch-set` object, `route` is `:new` or `:old`, and `latency-ms` is a real number.
It returns `:continue` when nothing changed, otherwise `:advanced`, `:promoting`, `:rolling-back`, or `:frozen`.

## Paired Fallback

With `:paired-fallback t`, a function shim catches an error from new code and reruns the call on old code with the same arguments.
The caller gets the old code's values and never sees the error.

The set still scores the task as a failure on new code.
Other sets the task pinned see the task's real outcome, which is a success when nothing else failed.
The error is audited as a canary anomaly, and `canary-anomaly` is signaled once per task per set.

Paired fallback has limits:

- It applies to function clauses only; method shims never fall back.
- It reruns the call; it does not undo what the new code did before the error.
- A storage condition, such as heap exhaustion, also arms the set's hard trigger, so the set rolls back at the next reported outcome.

Without paired fallback, an error from new code is noted the same way and keeps unwinding into the task.

### Retrying on Old Code

`with-task` also offers the `fallback-to-old` restart around its body.
Invoking it reruns the whole body with every pinned set routed to old code.

```lisp
(handler-bind ((error (lambda (e)
                        (declare (ignore e))
                        (let ((restart (find-restart 'splice:fallback-to-old)))
                          (when restart (invoke-restart restart))))))
  (splice:with-task (:id (order-id order))
    (process-order order)))
```

The task is still scored as a failure, on the routes it was pinned to before the rerun.
Its latency covers both runs.
Unlike paired fallback, this restart covers methods and the whole body, and works for any set.

## Bypassed Call Sites

A shim works because callers look up the function's global definition at each call.
A call site that skips that lookup reaches whatever code it was compiled or bound against.

| Call Site | What It Calls |
| --- | --- |
| A caller that inlined the function | The inlined old body, forever |
| A call inside one block-compiled unit | A direct local call to the old code |
| A local function from `flet` or `labels` | Itself; it cannot be patched |
| A function object saved before `install` | The old function |
| A call rewritten by a compiler macro | Whatever the expansion calls |

A saved function object is something like `#'price-order` stored in a table.

Do not inline, block-compile, or wrap in `flet` or `labels` any function you may need to patch.
Pass functions by name, as `'price-order`, where you keep them in data, so each call looks up the current definition.

Registration vetoes a function that is proclaimed `inline` or `maybe-inline` now.
It cannot see a caller compiled while the function was proclaimed inline and later redeclared.

## Details

### Shim Mechanics

| Patched Thing | Shim | On Rollback | On Promotion |
| --- | --- | --- | --- |
| Function | A closure stored as the global definition | The old function object goes back | The new function becomes the definition |
| Method | A method with the same specializers, replacing the old one | The old method object is added back | A method that calls the new code replaces the shim |

A function shim for a fixed argument count is compiled once per count.
A function with `&optional`, `&rest`, or `&key` gets a slower shim that goes through `apply`.

### The Draw

Splice hashes the string `"<task-id>|<set-name>"` with SHA-256.
It reads the first eight hex digits as an integer and takes it mod 100.
The task goes to `:new` when that number is below the stage's percentage.
The function is `draw-route` in `src/router.lisp` (internal).

### Latency and Sampling

Latency is measured on the raw monotonic clock.
It excludes pinning, the sampling audit entry, and releasing pins.

The sampled pins are written as a `:task-sample` entry.
