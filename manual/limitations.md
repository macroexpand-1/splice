# Limitations

This chapter lists what splice does not do.
Most items link to the chapter that covers the area.

## Platform

- **SBCL only.**
  Splice calls into SBCL's own modules (`sb-mop`, `sb-thread`, `sb-alien`, `sb-kernel`, and `sb-int`).
  No other implementation is supported.
- **SBCL 2.6.6 or later.**
  CI runs the full suite on SBCL 2.6.9 (the oldest version it tests) and on Arch Linux's current SBCL.
  The CI workflow names 2.6.6 as the floor.
  It is the first release where `fdefinition` returns a trace's wrapper and `sb-ext:unencapsulated-function` unwraps it.

## Patch Sets

- **Methods take required arguments only.**
  A method shim is a `defmethod` over the required parameters, one per specializer.
  On a generic function with optional, keyword, or rest arguments, that method is not congruent, and install signals.
- **A failed method shim leaves install half done.**
  Function shims go in before method shims, so they stay in place, routing to old code.
  The set stays in its installing state, and `roll-back` refuses it.
  See [The Lifecycle](lifecycle.md).
- **No method qualifiers.**
  A method clause names a generic function and specializers only.
  So an `:around`, `:before`, or `:after` method can't be patched.
- **`call-next-method` fails on the old route.**
  The old method is called with no next methods, so an old method that calls `call-next-method` signals.
  The internal `old-method-callable` in `src/patch.lisp` does this.
- **Method shims never fall back.**
  Paired fallback covers function shims only.
  An error in a new method is noted as an anomaly and keeps unwinding.
- **One in-flight set per function.**
  A set that patches a function another unfinished set already patches is vetoed at registration.
- **Unreadable lambda lists are vetoed.**
  The arity check needs both lambda lists.
  A function whose lambda list SBCL can't report (as `(debug 0)` code may be) can't be patched.
- **Variadic shims are slower.**
  A function with optional, keyword, or rest arguments gets a shim that uses `&rest` and `apply` on every call.
- **Some call sites bypass shims.**
  A function proclaimed `inline` is vetoed at registration.
  Callers that skip the global function cell still bypass the shim: block-compiled call sites, and local functions from `flet` and `labels`.
  See [Patch Sets](patch-sets.md).

## Class Migration

- **Subclasses are not migrated.**
  Migration hooks look up the instance's exact class name.
  A subclass instance inherits the new slots but gets no forward or backward migration.
  Registration does not refuse such a class.
- **The shape changes for every instance at once.**
  The whole class takes the union shape at install, and the final shape at promotion.
  Only behavior is canaried; old-routed and new-routed tasks see the same slots.
- **Rollback restores the journal.**
  A journaled instance gets back the old-slot values snapshotted at its forward migration.
  So writes to those slots after migration are lost, and added slots are dropped.
  See [Class Migration](class-migration.md).

## Tasks and Routing

- **Work outside `with-task` never canaries.**
  Outside a task, every shim routes to old code, and no outcome is reported.
- **Nested tasks can mix routes.**
  The inner task gets its own id and its own pins.
  So it can draw a different route from the outer task for the same set.
- **A fallback retry can see mixed versions at promotion.**
  The `fallback-to-old` restart reruns the task with every pin set to `:old`.
  Once promotion swaps a function, though, its old code is no longer reachable through its name.
  See [Tasks and Routing](tasks-and-routing.md).

## Canary Statistics

- **Error power is low at a low base rate.**
  Stage budgets are sized for the latency test, not the error test.
  In a simulation with default options, a 1.3x error increase on a 1% base rate was caught in about half of whole sessions.
  See [Canary Statistics](canary-statistics.md) for the per-stage numbers.
- **No latency test at 100%.**
  A 100% stage has no control arm, so only its error test runs.
  Its budget is a soak sized like a one-sample latency test.
- **Observations are treated as exchangeable.**
  The tests assume each observation is drawn the same way as the others.
  Real traffic is bursty and correlated in time.
  See [Canary Statistics](canary-statistics.md).

## Restarts

- **Promoted patches do not survive a restart.**
  Splice changes the running image, not the source files it was loaded from.
  Reloading those files brings the old code back, so the change belongs in source before the next restart.

## Cluster

- **The cluster is a prototype.**
  It has no heartbeats, no message authentication, and no gate on promotion.
  A malformed message can kill a member.
  The pooled test can reject a healthy cluster more often than alpha.
  See [Cluster Rollouts](cluster.md#known-gaps) for the full list.
- **Loopback only.**
  The TCP transport binds and connects to `127.0.0.1`, so every image runs on one machine.
- **Specs carry functions, classes, and contracts.**
  A cluster spec has no method patches and no minimum effect, so members use the default.

## Audit Log

- **The head is not anchored off the host.**
  The checkpoint sits beside the log.
  Someone with write access to the host can rewrite both into a chain that verifies.
- **macOS `fsync` leaves the drive cache unflushed.**
  Splice calls plain `fsync`, which on macOS leaves data in the drive's write cache.
  See [The Audit Log](audit-log.md).
