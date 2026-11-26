# Class Migration

A `:class` clause changes a class's slots as part of a patch set, and can reverse the change on rollback.
This chapter covers the clause, the combined shape a class takes during the canary, how instances migrate each way, and sealing.
Journal internals, audit entries, and freeze reasons are in [Details](#details).

## The Class Clause

```lisp
(:class name
 :add-slots (slot-spec...)
 :drop-slots (slot-name...)
 :migrate-forward function
 :migrate-backward function
 :lossy boolean)
```

| Key | Evaluated | Meaning |
| --- | --- | --- |
| `:add-slots` | No | New slots, as `defclass`-style specs |
| `:drop-slots` | No | Old slots the new shape drops |
| `:migrate-forward` | Yes | Fills the new slots when an old instance first migrates |
| `:migrate-backward` | Yes | Rebuilds a new-code instance's old slots on rollback |
| `:lossy` | Yes | True when the reversal can lose data |

Write the slot lists without a quote; the macro quotes them.
An added slot may use `:initform`, `:initarg`, `:reader`, `:writer`, `:accessor`, and `:type`.
Any other slot option signals an error at `install`.

Both migration functions may be omitted; then that step only changes the shape.
The forward function is called as `(f instance old-values)`, and `old-values` holds the bound direct slots of the old shape.
The backward function is called as `(f instance added-values)`, and `added-values` holds the added slots' values.
Each values argument is a property list keyed by slot name symbol, not by keyword.

## Worked Example

The orders example in `examples/orders/` moves an `order` from a float dollar total to integer minor units.
Its `currency-migration` set in `examples/orders/src/flagship.lisp` is built with internal constructors.
The `defpatch-set` form below declares the same set; the method clause and the contracts are left out for space.

```lisp
(defun forward-migration (instance old-values)
  (setf (slot-value instance 'amount-minor-units)
        (round (* 100 (rational (or (getf old-values 'float-total) 0))))))

(defun backward-migration (instance new-values)
  (setf (slot-value instance 'float-total)
        (/ (or (getf new-values 'amount-minor-units) 0) 100.0)))

(splice:defpatch-set currency-migration
    (:description "orders: float dollars to rational minor units"
     :ticket "SPLICE-42")
  (:function price-order #'new-price-order)
  (:function apply-discount #'new-apply-discount)
  (:function total-invoice #'new-total-invoice)
  (:class order
   :add-slots ((amount-minor-units :initform 0))
   :drop-slots (float-total)
   :migrate-forward #'forward-migration
   :migrate-backward #'backward-migration))
```

The new functions write the minor units.
They also write through to the float total while that slot exists.
That keeps old code correct for tasks routed to old code, which still read the float total.
The example's versions of the two migration functions also inject faults for its demo; the ones above leave that out.

## The Combined Shape

At install, the class is redefined with its old direct slots plus the added ones.
Dropped slots stay in this shape until promotion.

The shape changes for everyone at once: every instance, every task, and code outside any task.
Only behavior canaries per task.
Old code keeps working because no slot it reads is gone.
New code must keep the old slots correct if old code is still reading them, as the write-through above does.

## Forward Migration

An instance made before install migrates on its first slot access after the redefinition.
Whichever code touches it first triggers the migration, on either route or outside any task.
Splice saves the old slot values, then runs the forward function.
Instances created during the canary already have the combined shape, so they never migrate forward.

### Migration Failure

An error in the forward function signals `migration-failure` to the code that touched the instance.
The set rolls back at the next outcome reported on either route.
A lossy set freezes instead; see [Lossy Reversals](#lossy-reversals).

| Reader | Returns |
| --- | --- |
| `migration-failure-instance` | The instance that failed |
| `migration-failure-direction` | `:forward` or `:backward` |
| `migration-failure-cause` | The original error |

## Rollback

Rollback gives the class back its original direct slots and superclasses.
Then splice touches every instance it tracked, so each one reverses now rather than on next access.

| Instance | Reversal | Report Key |
| --- | --- | --- |
| Migrated forward | Saved slot values restored | `:journal-exact` |
| Created by new code during the canary | Backward function runs | `:synthesized` |
| Created by old code during the canary | Added slots dropped, nothing more | `:old-born-unchanged` |

A restored slot gets the value it held at first touch.
Any write to that slot during the canary, from either route, is overwritten.
An error in the backward function freezes the set for an operator.

`reverse-migration-report` returns the counts from the set's last completed rollback.
After the orders demo's faulty session, it returns:

```lisp
(splice:reverse-migration-report 'currency-migration)
;; => ((:JOURNAL-EXACT 28 :SYNTHESIZED 32 :OLD-BORN-UNCHANGED 415))
```

The list holds one property list per class clause, in declaration order.
Before any rollback completes, it returns `:not-rolled-back`.

## Lossy Reversals

Set `:lossy t` when the backward function cannot rebuild the old slots exactly.
Then no automatic trigger rolls the set back; each one freezes the set instead.

An operator can still roll it back in three ways:

- `roll-back`.
- `(unfreeze name :rollback)`.
- The `roll-back-patch` restart.

Operator commands are covered in [The Lifecycle](lifecycle.md).

## Promotion and Sealing

Promotion applies the final shape: the old direct slots, minus the dropped ones, plus the added ones.
Every migrated or canary-created instance takes the final shape now.
A promoted set cannot be rolled back; `roll-back` signals `illegal-transition`.

Splice keeps the saved slot values after promotion, and they hold strong references.
Every instance they cover stays reachable until rollback or `seal-patch` releases it.

| Function | Returns |
| --- | --- |
| `(seal-patch name &key operator)` | `:sealed` or `:no-change` |
| `(migration-journal-count &optional class-name)` | Count of journal entries |

`seal-patch` returns `:no-change` when the set is already sealed, and refuses unless the set is `:promoted`.
`migration-journal-count` counts entries for `class-name`, or for every class when it is omitted.

## Limits

- Migration is keyed on the instance's exact class.
  Subclass instances inherit the combined shape, but are never migrated, journaled, or reversed.
  Registration does not refuse a class that has subclasses.
- Only direct slots and direct superclasses are captured and restored.
  Inherited slots are neither journaled nor restored.
- The overlap check covers functions only, so two unfinished sets may both name the same class.

Other limits of splice as a whole are in [Limitations](limitations.md).

## Details

### Install

The class is redefined at `install`, before contracts run.
An added slot whose name matches an existing slot is ignored.

### The Migration Journal

The saved slot values live in the migration journal, keyed by the instance.
Each forward migration runs in this order:

1. The bound old direct slots are copied into the migration journal, keyed by the instance.
2. `:migrate-forward` runs with those values.
3. An `:instance-migration` entry is written to [The Audit Log](audit-log.md).

Splice records which route created each instance made during the canary.
`:new` marks it canary-born; `:old`, or no task, marks it old-born.

On rollback, once every tracked instance has reversed, the class's journal entries are released.
On promotion, splice touches every instance in the journal or the canary population.
The population is released; the journal is kept.
`seal-patch` releases the kept journal entries and audits the release.

### Failure Bookkeeping

An error in `:migrate-forward` is audited and arms the set's hard trigger.

After reversing the instances, rollback reads the image back.
It confirms every function, method, and class is in its old form.
A failed confirmation freezes the set for an operator, as an error in `:migrate-backward` does.
The freeze reason starts with `:rollback-failure`, and a `:rollback-failed` audit entry names the cause.

### Lossy Freezes

On a lossy set, these triggers freeze the set: an SPRT reject, a failing runtime contract, a migration failure, or a storage condition.
The freeze reason is `(:lossy-reversal-needs-human :trigger trigger)`.
