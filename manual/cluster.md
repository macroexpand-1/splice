# Cluster Rollouts

The cluster systems roll one patch set out across several SBCL images.
One conductor ships it, and each member image runs its own canary.
The conductor pools the members' error evidence.
It rolls every member back when one member rejects or the pooled test does.

The cluster is a prototype.
Its gaps are listed under [Known Gaps](#known-gaps) and in [Limitations](limitations.md).

## How a Rollout Runs

1. The conductor adds each member, then ships the patch set to all of them.
2. Each member checks the patch's hash, compiles its source, and registers it, or vetoes.
3. Once every member is prepared, the conductor tells them to commit.
   Each member installs the patch set, which runs its contracts.
4. Each member ramps through its stages on its own and reports its health while it runs.
5. When every member has finished, the conductor collects one final report per member and says goodbye.

A veto or a lost member during prepare or commit aborts the cluster.
Contracts run inside install, so a contract failure arrives during commit, not prepare.

The conductor rolls back every member on the first of three triggers:

- A member rolls back on its own.
- A member's set stays undecided for 2 minutes.
- The pooled error test rejects.

A member whose set has already left its canary stages keeps its state.

## Running the Demo

`examples/orders/scripts/demo-cluster.lisp` runs a conductor and two member images on one machine.

```sh
sbcl --non-interactive --load examples/orders/scripts/demo-cluster.lisp
```

It loads `splice-orders/cluster`, then starts two `sbcl` processes, so `sbcl` must be on `PATH`.
Each calls `splice-orders:run-orders-member`, one on port 7801 and one on port 7802 with the `:latent` fault.
The conductor ships `currency-patch-spec` to both.
Each member drives its own orders workload and sends health every 200 tasks.

The faulty member's canary rejects, so the conductor rolls back both.
The script prints each member's state, chain, and reconstruction results, and whether the conductor's log verifies.
It kills both member processes on the way out.

## Known Gaps

- There are no heartbeats, and the conductor has no timeouts of its own.
  A member that hangs with its connection open is never declared dead.
  Only a closed link counts as a lost member.
- Messages are not authenticated.
  Whichever local process connects to a member's port first can tell it to prepare or roll back.
- The conductor can order a rollback, but members promote without its approval.
  A healthy member can promote before a cluster rollback reaches it, and then keeps its state.
- A malformed message can kill a member.
  A line that doesn't read, or an unknown message kind, signals out of `run-member`'s serve loop with no handler.
- The pooled test sums each member's latest log odds.
  Those values go stale when a member stops reporting, and they reset at each of its stages.
  So the sum is not one valid sequential test, and it can reject a healthy cluster more often than alpha.
- The pooled threshold is `2/alpha` (log odds `log(2/alpha)`), while each member rejects at `2k/alpha` for a ramp of `k` stages.
  The pool takes a single stage's share and none of the per-stage split.
- The TCP transport is loopback only, so every image runs on one machine.

## Running Over TCP

Load `splice/cluster-tcp` for the TCP transport.

- `run-member` serves one conductor connection on a local port and returns when it ends.
- `run-conductor` connects to each member, runs the rollout, and returns one final report per member.
  It signals when a member vetoed.

A patch ships as source, in a plist of strings, keywords, and integers.
`examples/orders/src/cluster-spec.lisp` builds one in `currency-patch-spec`.
[Patch Specs](#patch-specs) lists the fields.

## Details

### Systems

| System | Files | Contents |
| --- | --- | --- |
| `splice/cluster` | `src/cluster-package.lisp`, `src/cluster-protocol.lisp` | The protocol as values; no sockets, no contribs |
| `splice/cluster-tcp` | `src/cluster-tcp.lisp` | A TCP transport over loopback |

The protocol system holds specs, the conductor, and the member.
The TCP system depends on `sb-bsd-sockets`.
Both export from the package `splice/cluster`.

### Protocol Messages

The rollout steps above map to these messages.

1. The conductor adds each member while the cluster is `:idle`.
2. `conductor-ship` sends `(:prepare :spec spec)` to every member.
3. Each member replies `:prepared`, or `:veto` with a reason.
4. Once every member is prepared, the conductor sends `(:commit)`.
5. Each member calls `splice:install` and replies `:committed`, or `:veto`.
6. Each member sends `:health` reports while it runs.
7. When every member is terminal, the conductor sends `(:report)`, collects one `:final` report per member, and sends `(:bye)`.

An abort during commit sends `(:rollback)` before `(:bye)`, since a member that already installed is canarying.
A transport reports a closed link to the conductor as the message `(:gone)`.

The conductor's phases are `:idle`, `:preparing`, `:committing`, `:running`, `:reporting`, `:done`, and `:aborted`.

### Patch Specs

| Field | Value |
| --- | --- |
| `:name` | Patch set name, interned in `:package` |
| `:package` | Name of a package that already exists on every member |
| `:description` | Free text |
| `:functions` | List of `(name source-text)`, each one lambda form |
| `:classes` | List of class plists (see below) |
| `:contracts` | List of `(name source-text)` |
| `:ramp` | Stage percentages, such as `(5 25 100)` |
| `:stage-limit` | Observations before an undecided stage times out |

Each class plist has `:name`, `:add-slots` (source text), `:drop-slots`, `:migrate-forward`, and `:migrate-backward`.

`conductor-ship` adds `:alpha-ppm` and `:beta-ppm` from the conductor's error rates, then puts `:hash` first.
Each member reads source with `*read-eval*` off.
Function, class, slot, and migration names must already exist in the member's package.
A missing one is an error, not a fresh symbol.
A spec carries no method patches, and no `:min-effect`, so the patch set's default applies.

| Function | Behavior |
| --- | --- |
| `spec-hash spec` | SHA-256 of the spec's canonical printed text, leaving out `:hash` |
| `spec-with-hash spec` | The spec with `:hash` set to its `spec-hash`, as the first field |
| `build-patch-set spec` | Checks the hash, compiles the source, and registers the set |

`build-patch-set` signals on a hash mismatch, a missing name, or a static veto.

### Health and Rollback

A member's `:health` message carries its state, its traffic fraction, and its observation count `:n`.
It also carries its error test's log odds in thousandths (`:llr-milli`).
The conductor keeps the latest report from each member and sums their log odds.
It broadcasts `(:rollback)` once, on the first of these triggers.

| Trigger | Cause |
| --- | --- |
| `:member-local-reject` | A member rolled back, or is rolling back, on its own |
| `:member-stalled` | A member's set stayed undecided for 2 minutes |
| `:pooled-sprt-reject` | The summed log odds reached the pooled threshold |

A member that receives `(:rollback)` rolls back if its set is still in a canary stage.
Otherwise it answers `:continue` and keeps its state.

After `:commit`, each member starts a watch thread.
It sends `:terminal` with the set's final state, or `:stalled` after 2 minutes without one.
After 10 more minutes it gives up and sends `:terminal` with the pseudo-state `:watch-expired`.
So the conductor always hears an end.

### Conductor Audit Log

The conductor writes its own audit log with these events:

- `:cluster-prepare`, `:cluster-commit`, `:cluster-rollback`, `:cluster-abort`, and `:cluster-final`.
- `:cluster-bad-message`, `:cluster-unknown-member`, and `:cluster-unknown-message`, for input it refuses.

### Protocol API

| Function | Behavior |
| --- | --- |
| `make-conductor &key adapter (alpha 0.01d0) (beta 0.05d0)` | A conductor with no members that sends through `adapter` |
| `conductor-add-member conductor member-id` | Adds a member while idle; returns `:idle` |
| `conductor-ship conductor patch-set-forms` | Hashes the spec and starts prepare; returns `:preparing` |
| `conductor-receive conductor member-id message` | Folds in one member message; returns the new phase |
| `conductor-phase conductor` | The current phase |
| `conductor-finals conductor` | One `(:member id :state state ...)` report per member, in the order added |
| `make-member &key adapter` | A member with no patch set yet |
| `member-receive cluster-member message` | Acts on one conductor message and returns its kind |
| `member-send-health cluster-member` | Sends the member's current `:health` report |

The conductor keeps the cluster as one immutable value and replaces it whole under a lock.
`conductor-receive` is safe to call from several threads.
`member-receive` expects one thread, in arrival order.
Its `:report` handling can block for up to 30 seconds.

### Transport Generics

A transport hands what arrives to `conductor-receive` or `member-receive`, and supplies an adapter object.

| Generic | Called With | Purpose |
| --- | --- | --- |
| `send-to-member` | `adapter member-id message` | The conductor's send |
| `send-to-conductor` | `adapter message` | A member's send |
| `member-committed` | `adapter cluster-member patch-set` | Called after install |
| `final-report-fields` | `adapter patch-set` | Extra plist fields for `:final` |

- `send-to-member` is called while the conductor holds its lock, so it must not call back into that conductor.
- `send-to-conductor` can be called from several threads at once.
- `member-committed` is where a host starts its workload; the default returns `:no-workload`.
- `final-report-fields` defaults to `()`.

Only `send-to-conductor` has no default method.

### The TCP Transport

`run-member &key (port 7801) log-path host` binds `127.0.0.1:port`, serves one conductor connection, and returns when it ends.
Its audit log defaults to `/tmp/splice-member-<port>.log`.
`host`, when given, receives `member-committed` and `final-report-fields`.

`run-conductor spec members-spec &key (alpha 0.01d0) (beta 0.05d0) log-path` connects to each `(host port)` in `members-spec`.
It runs the rollout and returns one final report per member, headed `:port`.
Its audit log defaults to `/tmp/splice-conductor.log`.
Each TCP member adds `:chain-ok`, `:entries`, and `:reconstruction-ok` from its own closed audit log.

The wire is one printed list per line, read with `*read-eval*` off.
Both sides delete any existing log at their path, then open a fresh one.
The conductor connects to `127.0.0.1` whatever host `members-spec` names.
