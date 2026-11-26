# Primer

This primer explains the ideas behind splice and walks through its demo.
It assumes you know Common Lisp, but nothing about splice or canary releases.

## The Idea

Lisp lets you redefine a function in a running image.
On a production server that is risky.
A redefinition takes effect for every caller at once.
Nothing checks whether the new code is worse, and nothing records what changed.
If several functions must change together, callers can briefly see a mix of old and new.

Services built on files and processes solved these problems with release tooling.
A canary sends a small share of traffic to the new build, compares it with the old one, and rolls back on harm.
Splice applies the same idea to the unit Lisp changes, the definition.
What it deploys is a set of functions, methods, and class shapes.

Unlike a canary of whole processes, old and new code run in the same image, at the same moment, under the same load.
The old code is a true control group, so the comparison is close to a controlled experiment.

## The Vocabulary

**Patch set.**
A named group of changes that must go together: new function bodies, new methods, class reshapes, and contracts that check the new code.
You declare one with `defpatch-set`.
See [Patch Sets](patch-sets.md).

**Shim.**
While a set is live, each patched function is replaced by a shim that holds both the old and the new code.
The shim sends each call to one of them.
After promotion the shims are gone, so a promoted set costs nothing per call.

**Task.**
One logical unit of work, such as handling one request, marked with `with-task`.
A task is what splice routes and scores.

**Route.**
Which side a task runs for a given set: `:old` or `:new`.
A task gets its route when it starts and keeps it for its whole life, so it sees all-old or all-new code.
The route comes from a hash of the task id and the set name, so it is uniform but repeatable.
Code outside any task runs old code until promotion.
See [Tasks and Routing](tasks-and-routing.md).

**Stage and ramp.**
The ramp is the list of traffic percentages a set moves through, `(5 25 100)` by default.
Each entry is a stage.
A stage ends one of three ways: the test rejects, the stage passes its budget, or it times out.

**Verdict.**
At each stage, a sequential test compares the tasks on new code with the tasks on old code.
It looks at two signals: failures, and how often a task runs slower than the old code's 95th percentile.
It only looks for harm.
A stage passes when it has seen enough new-code tasks to rule out the smallest harm you asked it to catch.
See [Canary Statistics](canary-statistics.md).

**Promotion.**
After the last stage passes, splice waits for tasks still pinned to old code to finish.
Then it installs the new definitions and removes the shims.

**Rollback.**
New tasks go to old code at once, and tasks already on new code finish.
Splice then restores the original definitions and migrates class instances back.

**Freeze.**
The ramp stops with both versions live, and a person decides what happens next.
Splice freezes on its own when the evidence can't be trusted, for example when the old code itself starts failing.
See [The Lifecycle](lifecycle.md).

## The Demo

The repository ships an example service in `examples/orders`.
It processes synthetic orders: price, discount, invoice.
You can inject faults into it to see how splice reacts.

Its patch set is called `currency-migration`.
It moves order money from float dollars to exact integer cents.
That one change touches four kinds of code at once:

- Three functions: `price-order`, `apply-discount`, and `total-invoice`.
- One method: `print-total` on `order` and `stream`.
- One class: `order` gains the slot `amount-minor-units` and loses `float-total`.
- Three contracts: the invoice is exact, a discount is conserved, and old and new totals agree to the cent.

The pieces depend on each other.
A new `total-invoice` reads `amount-minor-units`, which only the new `price-order` writes.
A task that ran the new `price-order` and then the old `total-invoice` would get a wrong answer.
Pinning each task to one route prevents that.

Run the demo from the repository root:

```sh
sbcl --non-interactive --load examples/orders/scripts/demo.lisp
```

It runs three scenarios against one audit log.

### Splice In

The first scenario installs the clean patch set and drives order tasks through it.

```
final state: PROMOTED after 257640 tasks
lifecycle:   REGISTERED -> STAGED -> CANARY-5 -> CANARY-25 -> CANARY-100 -> PROMOTING -> SWAPPING -> PROMOTED
post-promotion order total: 5397 cents (exact rational math)
```

`install` ran the three contracts first.
If any had failed, the set would have been vetoed and nothing installed.

Then the set moved through its stages.
At 5%, one task in twenty ran new code.
The 5% stage needs the most tasks: it must see enough new-code tasks to rule out harm, and only one in twenty is new.
At the default settings that is 9,793 new-code tasks, close to 200,000 tasks in all.

At 100% there is no old code left to compare against.
There, splice compares the new code's failure rate with the old code's recent history, and skips latency.

`PROMOTING` is the drain: splice waited for every task pinned to old code to finish.
`SWAPPING` installed the new definitions and removed the shims.
After that, an order's total is exact: 5397 cents.

The class changed differently from the functions.
A class can't have two shapes per task, so `order` took a combined shape for every instance as soon as the set was installed.
Each instance migrated forward the first time it was touched, and a journal recorded what it held before.
New code also wrote the float total through, so old-route tasks still read a correct `float-total` during the canary.
See [Class Migration](class-migration.md).

### Splice Out

The second scenario installs the same set with a latent fault: the new code fails, but only for orders with the `VIP` discount code.

```
final state: ROLLED-BACK after 487 tasks
lifecycle:   REGISTERED -> STAGED -> CANARY-5 -> ROLLING-BACK -> RESTORING -> ROLLED-BACK
SPRT rejected after 34 canary observations
reverse migration: ((JOURNAL-EXACT 28 SYNTHESIZED 32 OLD-BORN-UNCHANGED 415))
rollback exactness: (FDEFINITIONS-EQ T CLASS-SHAPE-ORIGINAL T SNAPSHOT-RESTORED 40 SNAPSHOT-TOTAL 40)
post-rollback order total: $53.97 (float world restored; class has no minor-units slot: T)
```

The failure test rejected after 34 scored observations, still in the 5% stage.
Most customers never ran the faulty code.

Rollback undid all of it:

- The function definitions are `eq` to the originals.
- The `order` class has its original shape.
- Instances migrated forward were migrated back.
  28 came back exactly from the journal.
  32 were created under the new shape, so their old values were rebuilt with the backward migration.
  415 were never migrated and needed nothing.

### Trace

The third scenario closes the log and checks it.

```
hash chain intact over 5770 entries: T
state reconstructed from log matches live image: T
tampered copy detected: intact=NIL, chain breaks at seq 42
```

Every registration, stage change, verdict, and rollback went into the audit log.
Each entry carries the hash of the one before, and each is fsynced before splice moves on.
`verify-audit-chain` walks the chain.
`verify-reconstruction` rebuilds the expected code state from the log alone and compares it with the live image.
Changing one entry in a copy breaks the chain at that entry.
See [The Audit Log](audit-log.md).

## Writing Your Own

A patch set of your own needs three things:

1. A `defpatch-set` form naming the functions, methods, and classes it changes, with contracts if you have checks worth running first.
2. Your application's units of work wrapped in `with-task`, so splice can route and score them.
3. A call to `install`.

The [README](../README.md) has a complete small example.
Before using splice on real code, read [Limitations](limitations.md): some kinds of method and class can't be patched yet, and inlined call sites bypass the shims.

## Where to Go Next

- [Patch Sets](patch-sets.md): every clause and option.
- [Tasks and Routing](tasks-and-routing.md): how tasks are pinned and what they report.
- [The Lifecycle](lifecycle.md): states, decision points, and operator restarts.
- [Canary Statistics](canary-statistics.md): the test, its budget, and how to choose its options.
- [Class Migration](class-migration.md): reshaping classes and migrating instances.
- [The Audit Log](audit-log.md): format, durability, and verification.
- [Cluster Rollouts](cluster.md): one set across several images.
