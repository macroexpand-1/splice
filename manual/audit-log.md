# The Audit Log

Splice records every lifecycle step in an append-only file, one entry per line.
Each entry is chained to the one before it by SHA-256.
The log can be verified offline, resumed after a crash, and folded back into the code state the image should be running.

## Quick Start

This is the shape of `examples/orders/scripts/demo.lisp`, trimmed to the log calls.

```lisp
(splice:delete-audit-log *log-path*)   ; start from nothing
(splice:open-audit-log *log-path*)     ; refuses a path that already holds a log

;; ... register, install, canary, promote or roll back ...

(splice:close-audit-log)

(multiple-value-bind (ok entry-count) (splice:verify-audit-chain *log-path*)
  (format t "hash chain intact over ~a entries: ~a~%" entry-count ok))

(multiple-value-bind (ok mismatches state) (splice:verify-reconstruction *log-path*)
  (declare (ignore state))
  (format t "state reconstructed from log matches live image: ~a~a~%"
          ok (if mismatches (format nil " (~a)" mismatches) "")))
```

The demo then tampers with a copy of the log.
It shows that `verify-audit-chain` reports the seq where the chain breaks.

## Writing a Log

- `open-audit-log` starts a new log at a path and makes it the open log.
  It refuses a path that already holds a file and points at `resume-audit-log`.
- `audit` appends one entry and returns its seq.
  With no log open, it returns `:unlogged`.
- `close-audit-log` closes the open log.
- `delete-audit-log` deletes a log and its checkpoint file.

The open log is held in `*audit-log*`.

## Resuming After a Crash

Call `resume-audit-log` on the same path to continue a log after a crash or restart.
It verifies the log first, then repairs what a crash can leave or refuses.

- A crash mid-write can leave a torn last line.
  Resume cuts it and records the cut in the log.
- Resume refuses any damage a crash can't explain, such as a missing log or a synced line that no longer reads.
- A log with no checkpoint file is refused until an operator vouches for it with `anchor-audit-log`.

Every resume writes a boot entry recording the image that resumed.
[Resume Decisions](#resume-decisions) has the full table.

## Verifying a Log

`verify-audit-chain` reads a log offline and reports whether its chain holds.
It returns whether the chain is intact, how many entries it verified, the seq where it broke, and a reason.

`verify-reconstruction` rebuilds the code state from the log and compares it with the live image.
It is meant for the image that wrote the log.
`reconstruct-state` returns the rebuilt state without comparing it.

## Guarantees

- `audit` returns only after its entry is on disk.
- `audit` is safe to call from several threads.
- After one write fails, every later `audit` signals, so no entry is ever written past the gap.
- The chain detects an edited, reordered, dropped, or truncated entry.

## What It Doesn't Cover

- The chain does not detect a rewrite of the whole log.
  The head hash lives only in the checkpoint file on the same host.
  Anyone with write access to that host can rewrite the log and the checkpoint together into a chain that verifies.
  Anchoring the head somewhere outside the host is left to the operator.
- On macOS, `fsync` does not flush the drive's own write cache.
  That takes `F_FULLFSYNC`, which splice does not call.
  So a power loss there can still lose entries that `audit` reported written.

See [Limitations](limitations.md) for the rest of what splice does not do.

## Details

### Source Files

The code lives in `src/audit.lisp`.
`verify-reconstruction` is in `src/lifecycle.lisp`, and the hash is in `src/sha256.lisp`.

### Functions

| Function | Behavior |
| --- | --- |
| `open-audit-log path` | Starts a new log, writes a checkpoint at seq 0, and sets `*audit-log*` |
| `resume-audit-log path` | Repairs or refuses an existing log, writes a `:boot` entry, and returns the log |
| `close-audit-log` | Closes the log and checkpoint, then sets `*audit-log*` to `nil` |
| `delete-audit-log path` | Deletes the log and checkpoint; returns `:deleted` or `:absent` |
| `audit event &rest fields` | Appends one entry and returns its seq, or `:unlogged` |
| `anchor-audit-log path` | Checkpoints the end of an unanchored log; returns the anchored seq |
| `*audit-log*` | The open log, or `nil` |

`open-audit-log` writes no entry.
It also refuses when the log is gone but its checkpoint remains, since that is what a deleted log looks like.
`close-audit-log` closes the log and its checkpoint under the log's lock.
`anchor-audit-log` refuses a chain that doesn't verify.

### Entry Format

Each line is one plist, printed readably with `*print-pretty*` off and `*package*` bound to `splice`.
Every entry starts with the same five fields, in this order.

| Field | Value |
| --- | --- |
| `:seq` | Entry number, from 1, rising by one per entry |
| `:ts` | UTC wall clock to the millisecond, ISO 8601 |
| `:prev-hash` | Hex SHA-256 of the previous line, or `"genesis"` |
| `:boot-id` | First 12 hex characters of the image's boot id |
| `:event` | Keyword naming what happened |

A timestamp looks like `"2026-11-25T14:03:07.412Z"`.
The previous line's hash is lowercase hex of that line's text, and `"genesis"` marks the first entry.
Event names include `:patch-registered`, `:install`, and `:promotion`.

The event's own fields follow as a plist.
A line looks like this (fields after `:event` shortened):

```lisp
(:SEQ 1 :TS "2026-11-25T14:03:07.412Z" :PREV-HASH "genesis" :BOOT-ID "5c1e0a9b27d4" :EVENT :PATCH-REGISTERED :PATCH-SET CURRENCY-MIGRATION ...)
```

The boot id is a SHA-256 of the universal time, the internal real time, and the machine name, taken when splice loads.
Every resume writes a `:boot` entry.
It carries the full boot id, the Lisp version, the machine name, and the core path.

### Values in Entries

Field values pass through the internal `sanitize-for-log` before printing.

- Numbers, keywords, symbols, and booleans are kept as they are.
- Strings keep their text, but newlines and carriage returns become spaces, so an entry never spans two lines.
- Lists are sanitized element by element.
- A condition becomes `(:condition "<type>" "<message>")`, with the message flattened to one line.
- Anything else (a structure, a function, a hash table) becomes `(:opaque "<16 hex characters>")`: the start of the SHA-256 of its printed form.

So a value that can't be read back never reaches the file.
An object's identity can still be compared across entries.

### Write Order

The internal `append-line` writes each entry in this order:

1. Write the line and its newline.
2. Flush the stream and `fsync` the log file.
3. Overwrite the checkpoint file `<log>.head` with the new seq and line hash, and `fsync` it.

The checkpoint holds one line: the seq as 20 zero-padded digits, a space, and the hash padded to 64 characters.
`fsync` is called through `sb-alien`, not through a contrib.
When a log is created, the directory holding it is also synced, so the new file survives a crash.
On one Mac this costs about 42 microseconds per entry.

Writes are serialized by a lock on the log.
If any step of a write signals, the condition is stored on the log, and the `audit` call that hit it signals too.
Every later `audit` call signals as well, naming the seq where the log stopped.

### Resume Decisions

`resume-audit-log` first verifies the chain and the checkpoint, then decides what to do with the file.

| Log State | What Resume Does |
| --- | --- |
| Intact and anchored | Continues `:seq` and `:prev-hash` from the last line |
| Last line complete, no newline | Appends the newline, then continues |
| Last line torn, checkpoint before it | Cuts the torn bytes and writes `:torn-tail` before `:boot` |
| Last line torn, checkpoint covering it | Refuses |
| Torn log with no checkpoint | Refuses |
| Non-empty log with no checkpoint | Refuses until `anchor-audit-log` |
| Log missing, checkpoint present | Refuses |
| Any other break | Refuses |
| No log and no checkpoint | Starts a new chain |

"Checkpoint before it" means the checkpoint is at or before the last whole entry.
When the checkpoint covers a torn line, that line was synced, so a line that no longer reads is damage, not a crash.
A missing log with its checkpoint present is the furthest possible truncation.

A torn line is a last line that doesn't read and has no newline, which is what a crash mid-write leaves.
The `:torn-tail` entry records `:after-seq`, the `:bytes` cut, and the `:sha256` of those bytes.

### Verify Reasons

`verify-audit-chain path` reads the log as a stream and returns `(values ok count break-seq reason)`.

| Reason | Meaning |
| --- | --- |
| `:intact` | Every `:prev-hash` matches and the checkpoint agrees |
| `:hash-mismatch` | An entry's `:prev-hash` is not the previous line's hash |
| `:unreadable` | A whole line doesn't read as an entry |
| `:torn-tail` | The last line doesn't read and has no newline |
| `:unanchored` | The chain holds, but a non-empty log has no checkpoint |
| `:truncated` | The checkpointed entry is gone or changed |
| `:unreadable-checkpoint` | The checkpoint file doesn't parse |

`count` is the number of entries verified before the break.
`break-seq` names the failing entry for the first three chain reasons, and is `nil` for the checkpoint reasons.

### Rebuilding Code State

`reconstruct-state path` folds the log into the code state the image should be running.
It refuses a log whose chain or checkpoint doesn't verify.
It returns a plist of three alists.

| Key | Entries |
| --- | --- |
| `:functions` | `(name . impl)`, impl one of `(:original set)`, `(:shimmed set)`, or `(:new set)` |
| `:classes` | `(name . shape)`, shape one of `(:original set)`, `(:union set)`, or `(:new set)` |
| `:sets` | `(name . state)`, the last logged state of each patch set |

Only the events that move code state count.
They are `:patch-registered`, a vetoing `:contract-result`, `:install`, `:canary-transition`, `:promotion`, `:rollback-complete`, and `:freeze`.
Method patches are not part of the reconstruction.

`verify-reconstruction path` compares that state with the live image and returns `(values ok mismatches state)`.
A function matches when its `fdefinition` is the very function object the impl names.
A class matches when its direct slot names equal the expected shape's.
A mismatch is a list such as `(name :fdefinition-mismatch impl)`, `(name :no-registry-object impl)`, or `(class :class-shape-mismatch shape :expected slots :live slots)`.
The comparison looks the patch sets up in the live registry, which is why it suits only the image that wrote the log.

### SHA-256

The hash is implemented in tree, in `src/sha256.lisp`, so the core `splice` system loads no SBCL contribs.
Three functions are exported.

| Function | Returns |
| --- | --- |
| `sha256-hex` | Hex digest of a string, encoded as UTF-8 |
| `sha256-octets-hex` | Hex digest of an `(unsigned-byte 8)` vector |
| `sha256-self-test` | `t` after checking three FIPS 180-4 test vectors |

`sha256-self-test` signals on a wrong digest.
