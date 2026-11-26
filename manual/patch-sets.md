# Patch Sets

A patch set is one change made of new functions, methods, and class shapes that canary, promote, or roll back together.
This chapter covers the `defpatch-set` macro, its clauses and options, the checks that run at registration, and contracts.

## A Small Set

This set patches one function and guards it with one contract.

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
```

`defpatch-set` builds the set and calls `register-patch-set` on it, which returns the set.
`install` runs the contracts, puts the shims in place, and enters the first ramp stage.
Calls made inside `with-task` then route to old or new code; see [Tasks and Routing](tasks-and-routing.md).
Stages, promotion, and rollback are covered in [The Lifecycle](lifecycle.md).

## Syntax

```lisp
(splice:defpatch-set name (&key description ticket ramp paired-fallback
                                alpha beta min-effect stage-limit)
  clause*)
```

`name` is a symbol and is not evaluated.
It names the set in the registry, the audit log, and the routing hash.

The option list is not evaluated as a whole, but each option value is an evaluated form.
That is why a ramp is written `:ramp '(50 100)`, with the quote.
An unknown clause kind signals an error when the macro expands.

## Clauses

| Clause | Replaces | Notes |
| --- | --- | --- |
| `(:function name lambda)` | The global function `name` | Any form returning a function |
| `(:method (gf class...) lambda)` | The primary method of `gf` on those classes | One class per required parameter |
| `(:class name &key ...)` | The direct slots of class `name` | See [Class Migration](class-migration.md) |
| `(:contract name :check thunk)` | Nothing | A gate at install and during the canary |

A set may hold any number of each clause.
Clauses of one kind keep their declaration order.

### Function Clauses

The function must be fbound when the set registers.
Its new implementation must accept every call the old one accepts; see [Registration Checks](#registration-checks).
The `lambda` form is evaluated, so any form returning a function works.

### Method Clauses

The method clause names a generic function and its specializer classes:

```lisp
(:method (print-total order stream)
 (lambda (order stream)
   (multiple-value-bind (dollars cents)
       (floor (slot-value order 'amount-minor-units) 100)
     (format stream "$~d.~2,'0d" dollars cents))))
```

A primary method with exactly those specializers must already exist.
The new lambda receives one argument per specializer.
A method shim never falls back to old code, even with `:paired-fallback t`.

Method clauses get the existence check only.
No lambda-list, overlap, or inlining check runs on them.

### Contract Clauses

`:check` is a form that returns a function of no arguments.
The check passes when that function returns true.
It fails when it returns `nil` or signals an error.
See [Contracts](#contracts).

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `:description` | `nil` | Free text for the audit log |
| `:ticket` | `nil` | A ticket or change reference for the audit log |
| `:ramp` | `'(5 25 100)` | Percent of tasks on new code, one per stage |
| `:paired-fallback` | `nil` | When true, a failing new function call reruns on old code |
| `:alpha` | `0.01d0` | Chance of a spurious rollback across the whole ramp |
| `:beta` | `0.05d0` | Chance of missing harm of size `:min-effect` in a stage |
| `:min-effect` | `0.3d0` | Smallest rise in the event rate worth catching, as a fraction |
| `:stage-limit` | `40000` | New-code observations a stage may take before it times out |

The rules each option must meet:

- `:ramp` is a non-empty list of numbers, each above 0 and at most 100, strictly rising.
  The last stage need not be 100.
- `:alpha` is a real number strictly between 0 and 1.
- `:beta` is one of `0.2d0`, `0.1d0`, `0.05d0`, or `0.01d0`, written as a double float.
  A single float such as `0.05` is vetoed.
- `:min-effect` is a positive real.
  At `0.3d0` the stage is sized to catch a new-code event rate 1.3 times the control rate.
- `:stage-limit` is a positive integer.
  A stage that reaches it without a verdict freezes the set.

How `:alpha`, `:beta`, and `:min-effect` size each stage is in [Canary Statistics](canary-statistics.md).
Paired fallback is described in [Tasks and Routing](tasks-and-routing.md#paired-fallback).

## Registration Checks

Registration runs these checks, and the first one to fail vetoes the set.

| Check | Veto Kind | Fails When |
| --- | --- | --- |
| Name | `:static-name-in-use` | An unfinished set of the same name is past registered |
| Existence | `:static-missing` | A function, generic function, class, or method is missing |
| Options | `:invalid-option` | An option breaks a rule in [Options](#options) |
| Overlap | `:static-overlap` | Another unfinished set patches one of the same functions |
| Lambda list | `:static-arity` | The new function refuses a call the old one accepts |
| Inlining | `:static-inlining` | The function is proclaimed `inline` or `maybe-inline` |

A missing function here means one that is not fbound.
A set is finished once it is `:rolled-back`, `:promoted`, or `:vetoed`.
A same-named set that is still registered or finished is replaced by the new declaration.
The overlap check compares function clauses only; two sets may name the same method or class.

The exact lambda-list rules are under [Lambda-List Coverage](#lambda-list-coverage).

### What a Veto Does

A veto sets the state to `:vetoed`, writes an audit entry, and signals `patch-vetoed`.

| Reader | Returns |
| --- | --- |
| `patch-vetoed-contract` | The veto kind from the table above, or the failing contract's name |
| `patch-vetoed-detail` | One line of text naming the problem |
| `splice-condition-patch-set` | The vetoed set |

A vetoed set stays in the registry, so `find-patch-set` returns it.
The one exception is a name-in-use veto: that set is never stored, and the live one is left alone.

## Contracts

A contract is a check of the new code that runs outside any task.
It runs at two points.

| When | Effect of a Failure |
| --- | --- |
| At `install`, before any shim exists | The set is vetoed; class shapes revert; nothing is installed |
| Every 200th new-code observation in a stage | A rollback, or a freeze if the set is lossy |

At `install` every contract runs in declaration order.
The first failure signals `patch-vetoed` with the contract's name.
Class clauses apply their combined shape before the contracts run, so a check can read added slots.

During a canary the interval counts new-code observations within the current stage.
The count starts over at each stage.
The interval is not an option.

Inside a check, a plain call to a patched function reaches old code, because the check is not in a task.
Call `(splice:new 'name)` to get the set's new implementation of `name`:

```lisp
(:contract old-and-new-agree
 :check (lambda ()
          (= (shipping-cost 3)
             (funcall (splice:new 'shipping-cost) 3))))
```

`new` covers function clauses only.
It signals an error when `name` is not patched by the set, or when called outside a check.

Keep runtime checks short, and do not open `with-task` inside one (see [Runtime Checks and the Lock](#runtime-checks-and-the-lock)).

## Registry API

| Symbol | Kind | Description |
| --- | --- | --- |
| `defpatch-set` | Macro | Builds a set from clauses and registers it; returns the set |
| `register-patch-set` | Function | `(register-patch-set set)` runs the checks and stores `set`; returns it |
| `find-patch-set` | Function | `(find-patch-set name)` returns the set, or `nil` when none is registered |
| `unregister-patch-set` | Function | `(unregister-patch-set name)` removes the registry entry |
| `patch-set` | Type | The structure type of a set |
| `patch-set-name` | Accessor | The set's name symbol |
| `patch-set-state` | Accessor | The lifecycle state keyword, such as `:registered` or `:canary-25` |
| `patch-set-description` | Accessor | The `:description` string, or `nil` |
| `new` | Function | Inside a contract check, the set's new implementation of a function |

`defpatch-set` is the way to build a set.
Operator functions such as `install` and `roll-back` take a name or a set.
A name nothing registered signals `unknown-patch-set`.

`unregister-patch-set` only removes the entry.
It does not look at the state, remove shims, or restore code.
A live set that is unregistered stops pinning new tasks, so its shims send every call to old code.
Use it on finished sets.

## Details

### Check Order

`register-patch-set` in `src/patch.lisp` runs the registration checks in the order of the table, from name to inlining.

### Lambda-List Coverage

The lambda-list check reads both lambda lists and reduces each to a call shape: required count, positional count, and what may follow.
The new function covers the old one when all of these hold:

- It requires no more arguments than the old one.
- With no `&rest` or `&key`, it takes at least as many positional arguments, and the old one has no `&rest` or `&key` either.
- With `&rest` and no `&key`, it accepts anything past its required arguments.
- With `&key`, against an old function with neither `&rest` nor `&key`, it takes at least as many positional arguments.
- With `&key`, against an old function with `&key`, its keywords start at the same position as the old one's.
  It must also accept every keyword the old one names, or declare `&allow-other-keys`.
  If the old one declares `&allow-other-keys`, so must the new one.
- With `&key`, it never covers an old function with `&rest` and no `&key`.

A lambda list that cannot be read also vetoes, with `:static-arity`.
SBCL drops lambda lists from code compiled with `(debug 0)`.

### The Beta Table

`:beta` must be `=` to a key of the internal `*power-z-scores*` table.
A single float such as `0.05` is not `=` to `0.05d0`, which is why it is vetoed.

### Audit Entries

`:description` and `:ticket` are recorded in the `:patch-registered` audit entry.

A veto writes a `:contract-result` audit entry with `:verdict :veto`.

Every contract result is audited with its phase, `:pre-flight` or `:runtime`.

### Runtime Checks and the Lock

The runtime contract interval is the internal slot `runtime-contract-interval`.

Runtime checks run while splice holds the set's lock.
Pinning the set takes that same lock, which is why a check must not open `with-task`.

### Internal Constructor

The constructor for a `patch-set` is internal, so `defpatch-set` is the way to build one.
