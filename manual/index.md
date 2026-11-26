# The Splice Manual

The manual documents splice one subsystem at a time.
If you are new to splice, read the [Primer](primer.md) first; it introduces the vocabulary these chapters use.

## Chapters

| Chapter | What It Covers |
|---|---|
| [Primer](primer.md) | The ideas and vocabulary, worked through the orders demo |
| [Patch Sets](patch-sets.md) | Declaring a set with `defpatch-set`: its clauses, options, and the checks at registration |
| [Tasks and Routing](tasks-and-routing.md) | `with-task`, how a task is pinned to old or new code, shims, and paired fallback |
| [The Lifecycle](lifecycle.md) | States, stages, promotion, rollback, freezing, decision points, and operator restarts |
| [Canary Statistics](canary-statistics.md) | The mixture SPRT, its two signals, the stage budget, and how to choose `alpha`, `beta`, and `min-effect` |
| [Class Migration](class-migration.md) | Reshaping a class, migrating instances forward and back, and sealing |
| [The Audit Log](audit-log.md) | The log format, the hash chain, fsync and checkpoints, resuming after a crash, and verification |
| [Cluster Rollouts](cluster.md) | Rolling one set out across several images, a prototype |
| [Limitations](limitations.md) | What splice does not do |

## Reading Order

The chapters follow a patch set's life.
Patch Sets and Tasks and Routing cover what you write.
The Lifecycle and Canary Statistics cover what splice does with it.
Class Migration and The Audit Log cover what changes in the image and how it is recorded.

## Conventions

Symbols are in the `splice` package unless a chapter says otherwise; the cluster chapter uses `splice/cluster`.
Only exported symbols are API.
Where a chapter mentions an internal function, it says so.
Code is cited by file and the name it defines, such as `register-patch-set` in `src/patch.lisp`.
