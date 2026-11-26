# Splice

Splice rolls out a code change inside a running SBCL image the way a canary release rolls out a new build.

You group the functions, methods, and classes that must change together into a patch set.
Splice installs it beside the old code and gives each task either all-old or all-new code, never a mix.
The share of tasks on new code ramps up in stages: 5%, then 25%, then 100% by default.
At each stage, a sequential test compares failures and latency on new code against old code running at the same moment.
If the new code does worse, splice rolls it back, including any class instances it migrated.
Otherwise it promotes the new code and removes its own shims.
Every step is written to a hash-chained, fsynced log, and the image's code state can be rebuilt from that log alone.

## Example

```lisp
(defun shipping-cost (weight-kg)
  (* 4 weight-kg))

(splice:defpatch-set flat-rate-shipping
    (:description "Flat rate for parcels under 2 kg"
     :ramp '(50 100)
     :min-effect 3d0)
  (:function shipping-cost
   (lambda (weight-kg)
     (if (< weight-kg 2) 5 (* 4 weight-kg))))
  (:contract never-negative
   :check (lambda () (<= 0 (funcall (splice:new 'shipping-cost) 1)))))

(splice:install 'flat-rate-shipping)

;; Your application marks each unit of work as a task.
(loop for id from 1 to 2000
      do (splice:with-task (:id id)
           (shipping-cost (mod id 5))))

(splice:patch-set-state (splice:find-patch-set 'flat-rate-shipping))
;; => :PROMOTED
```

Here is what happens:

1. `defpatch-set` registers the set and checks that the new function accepts every call the old one did.
2. `install` runs the contract `never-negative`.
   A failing contract vetoes the set, and nothing is installed.
3. Half the tasks run the new `shipping-cost` and half run the old one.
   Each task's outcome feeds the test.
4. Once the 50% stage has seen enough tasks without harm, all traffic moves to new code.
   At 100%, splice watches the error rate against the old code's history.
5. When that stage passes, splice waits for tasks still on old code to finish, then installs the new definition for good.

The example uses a short ramp and a large `min-effect`, so it only looks for a 4x slowdown or worse and finishes in about a thousand tasks.
The defaults look for a 1.3x harm and need far more traffic.
[Canary Statistics](manual/canary-statistics.md) gives the cost in tasks.

The test suite runs this example as `a-declared-set-ramps-and-promotes` in `test/integration/lifecycle.lisp`.
Like any statistical test, it can reject healthy code: at `alpha` 0.01, about one run in a hundred rolls back.

## How It Compares

### Process Deploys

Rolling, blue-green, and canary releases are schedules for replacing processes.
They differ in how many processes are replaced and in what order.
In each, a built artifact goes out, and a process running the old one goes away.

Much of standard practice follows from that.
Services are kept stateless partly because their processes are disposable.
Warmup, connection draining, and cache priming exist because every deploy is a cold start.
Canaries compare hosts, because a host is the smallest thing that can run a different version.

Splice changes definitions inside one running process.
The process stays up, and its objects stay in memory and change shape in place.

That also gives a cleaner experiment.
A host-level canary compares two machines that differ in hardware, cache warmth, neighbors, and the traffic the balancer sends them.
Splice runs old and new code in the same process, at the same moment, under the same load, and splits traffic per task.
If the old code itself starts failing, splice freezes the set rather than blame the new code.

| | Blue-Green | Canary Release | Feature Flag | Splice |
|---|---|---|---|---|
| What Changes | A whole fleet | A whole build, on some hosts | A code path written in advance | Functions, methods, and classes, written after deploy |
| Where Traffic Splits | Load balancer | Load balancer or host | A branch the author planned | A shim splice installs |
| Unit of Traffic | Request to a host | Request to a host | Request or user | Task, pinned for its whole life |
| Live State | Lost or rebuilt at cutover | Lost or rebuilt per host | Untouched | Kept; objects migrate forward, and back on rollback |
| Who Decides It Is Healthy | A person or a dashboard | Metrics against a threshold | A person | A sequential test against the old code beside it |
| Rollback | Switch back to the old fleet | Redeploy | Turn the flag off | Restore the old definitions and migrate objects back |

Splice does not touch external state.
A database schema change still needs the usual expand-and-contract steps.

### Live Patching

Other runtimes can change code while they run, but none of them gate the change on evidence.

- [Erlang/OTP](https://www.erlang.org/doc/system/code_loading.html) keeps two versions of a module, and fully qualified calls reach the newer one.
  Loading a third version kills any process still running the oldest.
  There is no canary or health check, and a downgrade is a human decision.
- The JVM's HotSwap changes method bodies only, with no new fields or methods.
  JRebel adds a layer of indirection to allow more, but it is a development tool, without a canary, rollback, or audit trail.
- Smalltalk redefines a class and migrates every live instance at once.
  The migration is eager and global, and there is no way back.
- Kernel live patching ([Ksplice](https://pdos.csail.mit.edu/papers/ksplice:eurosys.pdf), kpatch, kGraft, and [livepatch](https://docs.kernel.org/livepatch/livepatch.html)) is the closest.
  It applies patches that span many functions coherently, and livepatch moves each task to the new code at a safe point.
  Splice uses the same per-task model, and its migration journal borrows the idea of Ksplice's shadow data structures.
  Deciding whether a kernel patch is healthy is still up to a person.

None of these combine coherent change across many definitions, a statistical gate, reversible instance migration, and a log the image's state can be rebuilt from.
Common Lisp makes all four possible in a library.
Function definitions, CLOS class redefinition, and the condition system are all specified and programmable.

## Why Splice

The canary test is an anytime-valid mixture SPRT.
Its false-alarm bound holds however often you look at it.
It needs no guessed baseline, because the old code is the baseline.

A thread inside `with-operator-decisions` stops at each decision point, such as a reject or a stage timeout, and asks.
The set freezes, and the debugger offers restarts to roll back, freeze, promote anyway, or let splice decide.

The audit log survives a crash.
Each entry is fsynced and checkpointed, and a torn last line is cut and recorded when the log resumes.

## Requirements

- SBCL 2.6.6 or later.
  CI runs SBCL 2.6.9 and the current Arch Linux release.
- The core system `splice` loads no libraries beyond SBCL itself.
- The tests need [FiveAM](https://github.com/lispci/fiveam).
- The TCP cluster transport needs `sb-bsd-sockets`, which ships with SBCL.

## Getting Started

Splice is not in Quicklisp.
Clone the repository and load its system definition:

```lisp
(require :asdf)
(asdf:load-asd #p"/path/to/splice/splice.asd")
(asdf:load-system "splice")
```

Run the unit tests from the repository root:

```sh
sbcl --non-interactive --eval '(require :asdf)' \
     --eval '(asdf:load-asd (truename "splice.asd"))' \
     --eval '(asdf:test-system "splice")'
```

Run every check (unit, integration, cluster, and the demo) the way CI does, which also compiles the criteria without running them:

```sh
sbcl --non-interactive --load test/check.lisp
```

Each check runs in a fresh SBCL with a deadline, and the run stops at the first failure.

The criteria are a report, not a check.
They measure detection rates over 100 sessions per fault class and the shim's cost per call, so their numbers move with chance and with the machine.
A full run takes about 35 minutes on a CI runner, so they stay out of the CI on each push.
The `criteria` workflow runs them on `main` every Monday and on demand (`gh workflow run criteria --ref <branch>`).
It fails on a missed criterion and uploads `examples/orders/artifacts/criteria-report.md` either way.
Run them locally, in about 15 minutes on an Apple-silicon Mac, with:

```sh
sbcl --non-interactive --eval '(require :asdf)' \
     --eval '(asdf:load-asd (truename "splice.asd"))' \
     --eval '(asdf:load-asd (truename "examples/orders/splice-orders.asd"))' \
     --eval '(asdf:test-system "splice-orders/criteria")'
```

## The Demo

`examples/orders` is a synthetic order service with injectable faults.
Its patch set, `currency-migration`, moves order money from float dollars to exact integer cents.
It replaces three functions and a method, and reshapes the `order` class.

```sh
sbcl --non-interactive --load examples/orders/scripts/demo.lisp
```

The demo runs three scenarios:

1. Splice in: the clean set ramps through 5%, 25%, and 100%, and is promoted.
2. Splice out: a fault that fires only for VIP orders is caught mid-ramp.
   The set is rolled back, and every migrated `order` instance is migrated back.
3. Trace: the audit log's chain verifies, the state rebuilt from the log matches the image, and a tampered copy is detected.

The [Primer](manual/primer.md) walks through it.

## Documentation

- [Primer](manual/primer.md): the ideas and vocabulary, worked through the orders demo.
  Start here.
- [The Manual](manual/index.md): one chapter per subsystem, with the API, options, and defaults.
- [Limitations](manual/limitations.md): what splice does not do.

## Main Limitations

- SBCL only; splice relies on SBCL internals for shims, class changes, and fsync.
- A method patch can't replace a method on a generic function with `&optional`, `&key`, or `&rest` arguments, and can't carry qualifiers such as `:around`.
- A class patch migrates instances of the named class only.
  Instances of its subclasses inherit the new slots but are never migrated forward or back.
- Call sites that are inlined, block-compiled, or inside `flet` and `labels` bypass the shims.
- Promotion changes the image, not your source files.
  A restart that reloads the source brings the old code back.
- The multi-image cluster layer is a prototype, with no message authentication and no heartbeats.

## License

BSD 2-Clause; see [LICENSE](LICENSE).
