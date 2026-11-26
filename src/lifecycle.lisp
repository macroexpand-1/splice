;;;; lifecycle.lisp: patch-set state machine, canary evaluator, and
;;;; rollback/promotion. Those two complete in their own threads, since the
;;;; trigger arrives inside a pinned task that must drain first.

(in-package #:splice)

(defvar *drain-timeout-seconds* 10
  "How long rollback and promotion wait for pinned tasks to drain. Either one
freezes the set when the wait runs out.")

(defvar *audit-sprt-steps* nil
  "When true, audit every canary observations SPRT state as :SPRT-STEP
This is off by default, a long criteria would log every observation")

;;; ---------------------------------------------------------------------
;;; State transitions

(defun transition (ps to &rest fields)
  "Move PS to state TO, record history, and audit. Caller holds the lock."
  (let ((from (patch-set-state ps)))
    (setf (patch-set-state ps) to)
    (push (cons to (get-universal-time)) (patch-set-history ps))
    (apply #'audit :canary-transition
           :patch-set (patch-set-name ps) :from from :to to fields)))

(defun patch-set-lifecycle-history (ps)
  (reverse (patch-set-history ps)))

(defun baseline-failure-rate (ps)
  "The control arm's failure rate over the null ring, or a 0.001 prior until
the arm has enough samples"
  (let ((rate (control-failure-rate (patch-set-null-ring ps))))
    (if (eq rate :too-few-samples) 0.001d0 rate)))

;;; ---------------------------------------------------------------------
;;; Canary stage
;;; One stage's tests and counts, replaced whole on stage entry so a lucky
;;; 5% stage never subsidizes a bad 25% one.

(defstruct (canary-stage (:constructor %make-canary-stage)
                         (:predicate nil))  ; CANARY-STAGE-P is the state test in types.lisp
  (fraction 0 :read-only t)
  (budget 0 :read-only t)               ; scored :new observations to pass
  (error-test nil :read-only t)
  ;; mutable
  (latency-test :unscored)              ; :unscored, then a MIXTURE-TEST; :untested at 100%
  (latency-threshold :unset)            ; control p95 in ms, fixed once per stage
  (observations 0)                      ; every :new observation
  (scored 0))                           ; :new observations every test it runs scored

(defun test-kind (fraction)
  "A stage with a control arm compares the arms; at 100% there is none."
  (if (< fraction 100) :two-sample :one-sample))

(defun error-null-share (ps fraction)
  "The error test's hit probability when the new code is no worse."
  (ecase (test-kind fraction)
    (:two-sample (/ fraction 100d0))
    (:one-sample (max 1d-3 (baseline-failure-rate ps)))))

(defun fresh-stage (ps fraction)
  "A new CANARY-STAGE for PS at FRACTION percent."
  (%make-canary-stage
   :fraction fraction
   :budget (stage-budget fraction :alpha (patch-set-alpha ps)
                                  :stage-count (length (patch-set-ramp ps))
                                  :beta (patch-set-beta ps)
                                  :min-effect (patch-set-min-effect ps))
   :error-test (make-mixture-test (test-kind fraction) (error-null-share ps fraction)
                                  :alpha (patch-set-alpha ps)
                                  :stage-count (length (patch-set-ramp ps))
                                  :min-effect (patch-set-min-effect ps))
   :latency-test (initial-latency-test fraction)))

(defun initial-latency-test (fraction)
  "A stage with a control arm waits for its latency threshold. At 100% the
only null would come from an earlier period, and latency drifts between
periods by as much as the effect the test looks for, so that stage has no
latency test."
  (ecase (test-kind fraction)
    (:two-sample :unscored)
    (:one-sample :untested)))

(defun fix-latency-threshold (ps canary-stage)
  "Fix the stage's latency threshold at the control p95 and build its
two-sample test, once the null ring has enough samples. Returns :fixed or
:unscored."
  (let ((p95 (control-latency-quantile (patch-set-null-ring ps) 0.95)))
    (cond ((eq p95 :too-few-samples) :unscored)
          (t (setf (canary-stage-latency-threshold canary-stage) p95
                   (canary-stage-latency-test canary-stage)
                   (make-mixture-test :two-sample
                                      (/ (canary-stage-fraction canary-stage) 100d0)
                                      :alpha (patch-set-alpha ps)
                                      :stage-count (length (patch-set-ramp ps))
                                      :min-effect (patch-set-min-effect ps)))
             :fixed))))

(defun fold-stage-observation (ps route failure-p latency-ms)
  "Take one observation on ROUTE into PS's stage tests and counts. Caller
holds the lock. Returns :scored or :unscored."
  (let ((stage (patch-set-stage ps)))
    (when (eq (canary-stage-latency-test stage) :unscored)
      (fix-latency-threshold ps stage))
    (mixture-observe (canary-stage-error-test stage) route failure-p)
    (let ((latency (canary-stage-latency-test stage)))
      (when (mixture-test-p latency)
        (mixture-observe latency route
                         (> latency-ms (canary-stage-latency-threshold stage))))
      (when (eq route :new)
        (incf (canary-stage-observations stage))
        (unless (eq latency :unscored)
          (incf (canary-stage-scored stage))))
      (if (eq latency :unscored) :unscored :scored))))

;;; ---------------------------------------------------------------------
;;; Install
;;; Contracts gate -> shims (dormant) -> atomic flip to first stage

(defun install (name-or-ps)
  "Take a REGISTERED patch set through contracts into its first canary
stage. Signals PATCH-VETOED, installing nothing, if any contract fails. The
set moves to :INSTALLING under its lock before any work, so a second install,
or one on a set that isn't registered, is refused with ILLEGAL-TRANSITION."
  (let ((ps (resolve-patch-set name-or-ps)))
    (with-set-lock (ps)
      (if (eq (patch-set-state ps) :registered)
          (setf (patch-set-state ps) :installing)
          (refuse-locked ps :install)))
    ;; contracts run new code, which reads the added slots, so the union
    ;; shape comes first. Old code cannot see it, and a veto reverts it.
    (dolist (cp (patch-set-class-patches ps))
      (begin-class-canary ps cp))
    ;; no shim exists yet, so a veto means nothing live ever routed :new
    (handler-case (run-pre-flight-contracts ps)
      (patch-vetoed (e)
        (dolist (cp (patch-set-class-patches ps))
          (rollback-class-patch ps cp))
        (error e)))
    (setf (patch-set-control-ring ps) (make-control-ring)
          (patch-set-null-ring ps) (make-control-ring :size *null-ring-size*))
    ;; shims start dormant, routing :old until the stage flip
    (install-fn-shims ps)
    (install-method-shims ps)
    (with-set-lock (ps)
      (setf (patch-set-state ps) :staged)
      (push (cons :staged (get-universal-time)) (patch-set-history ps))
      (audit :install :patch-set (patch-set-name ps)
                      :shimmed-functions (mapcar #'fn-patch-name
                                                 (patch-set-fn-patches ps))
                      :shimmed-methods (mapcar #'method-patch-gf-name
                                               (patch-set-method-patches ps))
                      :union-classes (mapcar #'class-patch-class-name
                                             (patch-set-class-patches ps)))
      ;; one state flip makes the first stage live
      (enter-stage ps 0))
    ps))

(defun enter-stage (ps index)
  "Enter ramp stage INDEX. Caller holds the lock."
  (let ((fraction (nth index (patch-set-ramp ps))))
    (setf (patch-set-stage-index ps) index
          (patch-set-current-fraction ps) fraction

          (patch-set-stage ps) (fresh-stage ps fraction))
    (transition ps (stage-keyword fraction)
                :fraction fraction
                :budget (canary-stage-budget (patch-set-stage ps))
                :errors (mixture-snapshot (canary-stage-error-test (patch-set-stage ps))
                                          :errors))))

;;; ---------------------------------------------------------------------
;;; Evaluator
;;; Every task outcome flows through here (via WITH-TASK)

(defun report-outcome (ps route failure-p latency-ms)
  "Fold one task outcome into PS's evaluator. Control (:old) outcomes feed
the baseline; canary (:new) outcomes feed the SPRTs and may trigger a
transition. Returns the action taken: :continue when nothing changed, otherwise
:advanced, :promoting, :rolling-back or :frozen."
  (with-set-lock (ps)
    (report-outcome-locked ps route failure-p latency-ms)))

(defun report-outcome-locked (ps route failure-p latency-ms)
  "The locked stuff"
  (unless (canary-stage-p (patch-set-state ps))
    (when (and (patch-set-control-ring ps) (eq route :old))
      (record-control ps failure-p latency-ms))
    (return-from report-outcome-locked :continue))
  ;; hard triggers fire on any route: a migration failure can surface in
  ;; an old-routed task, and at 5% the next canary task may be far off
  (let ((trigger (take-hard-trigger ps)))
    (unless (eq trigger :unarmed)
      (return-from report-outcome-locked
        (initiate-rollback-locked ps (cons :hard-trigger trigger)))))
  (cond
    ((eq route :old)
     (record-control ps failure-p latency-ms)
     (fold-stage-observation ps :old failure-p latency-ms)
     (check-control-arm ps))
    (t                              ; :new, a canary observation
     (evaluate-canary-observation ps failure-p latency-ms))))

(defun record-control (ps failure-p latency-ms)
  "Record one control observation in both of PS's rings"
  (control-record (patch-set-control-ring ps) failure-p latency-ms)
  (control-record (patch-set-null-ring ps) failure-p latency-ms))

(defun check-control-arm (ps)
  "Freeze PS when the control arm is too degraded for any canary verdict to
mean something. Caller holds the lock. Returns :continue or :frozen."
  (let ((rate (control-failure-rate (patch-set-control-ring ps))))
    (if (and (realp rate) (> rate (patch-set-confound-threshold ps)))
        (settle-locked ps :confounded :freeze (list :confounded :control-rate rate))
        :continue)))

(defun evaluate-canary-observation (ps failure-p latency-ms)
  "Caller holds the lock; hard triggers were already checked upstream."
  (fold-stage-observation ps :new failure-p latency-ms)
  (audit-sprt-step ps)
  (if (runtime-contract-due-p ps)
      (check-runtime-contracts ps)
      (settle-stage ps (stage-verdict ps (patch-set-stage ps)))))

(defun runtime-contract-due-p (ps)
  "Contracts are sampled every interval of :new observations: structural
breakage is not a rate question."
  (let ((interval (patch-set-runtime-contract-interval ps)))
    (and (plusp interval)
         (zerop (mod (canary-stage-observations (patch-set-stage ps)) interval)))))

(defun check-runtime-contracts (ps)
  "Roll back on a failing runtime contract, otherwise settle the stage."
  (multiple-value-bind (verdict failing) (run-runtime-contracts ps)
    (if (eq verdict :fail)
        (settle-rollback-locked ps :runtime-contract (list :runtime-contract failing))
        (settle-stage ps (stage-verdict ps (patch-set-stage ps))))))

(defun latency-rejects-p (canary-stage)
  (let ((latency (canary-stage-latency-test canary-stage)))
    (and (mixture-test-p latency)
         (eq :reject (mixture-verdict latency)))))

(defun stage-verdict (ps canary-stage)
  "Where the stage stands: :reject-errors, :reject-latency, :pass, :timeout
or :continue. A reject wins over the budget, and the budget over the limit."
  (cond ((eq :reject (mixture-verdict (canary-stage-error-test canary-stage)))
         :reject-errors)
        ((latency-rejects-p canary-stage)
         :reject-latency)
        ((>= (canary-stage-scored canary-stage) (canary-stage-budget canary-stage))
         :pass)
        ((>= (canary-stage-observations canary-stage) (patch-set-stage-limit ps))
         :timeout)
        (t :continue)))

(defun settle-stage (ps verdict)
  "Act on VERDICT from STAGE-VERDICT. Caller holds the lock."
  (let ((stage (patch-set-stage ps)))
    (ecase verdict
      (:reject-errors (reject-stage ps :errors (canary-stage-error-test stage)))
      (:reject-latency (reject-stage ps :latency (canary-stage-latency-test stage)))
      (:pass (pass-stage ps stage))
      (:timeout (settle-locked ps :stage-timeout :freeze (stage-timeout-cause ps stage)))
      (:continue :continue))))

(defun reject-stage (ps signal mixture-test)
  "Roll back on SIGNAL's reject. The cause carries the stage's :new
observation count as :N, which detection-time readers use."
  (let ((n (canary-stage-observations (patch-set-stage ps)))
        (log-odds (mixture-log-odds mixture-test)))
    (defer (lambda () (signal 'canary-verdict :patch-set ps :stream-kind signal
                                              :direction :reject :n n :llr log-odds)))
    (settle-rollback-locked ps :sprt-reject
                            (list :sprt-reject
                                  (list* :n n (mixture-snapshot mixture-test signal))))))

(defun pass-stage (ps canary-stage)
  (let ((n (canary-stage-observations canary-stage))
        (log-odds (mixture-log-odds (canary-stage-error-test canary-stage))))
    (defer (lambda () (signal 'canary-verdict :patch-set ps :stream-kind :both
                                              :direction :pass :n n :llr log-odds))))
  (if (< (1+ (patch-set-stage-index ps)) (length (patch-set-ramp ps)))
      (settle-locked ps :budget-pass :advance nil)
      (settle-locked ps :budget-pass :promote nil)))

(defun latency-snapshot (canary-stage)
  (let ((latency (canary-stage-latency-test canary-stage)))
    (if (mixture-test-p latency)
        (mixture-snapshot latency :latency)
        latency)))

(defun stage-timeout-cause (ps canary-stage)
  (list :stage-timeout
        :observations (canary-stage-observations canary-stage)
        :limit (patch-set-stage-limit ps)
        :scored (canary-stage-scored canary-stage)
        :budget (canary-stage-budget canary-stage)
        :errors (mixture-snapshot (canary-stage-error-test canary-stage) :errors)
        :latency (latency-snapshot canary-stage)))

(defun stage-point (canary-stage mixture-test)
  "The test's position as (observations . log-odds); an unscored or untested
test is 0."
  (cons (canary-stage-observations canary-stage)
        (if (mixture-test-p mixture-test)
            (float (mixture-log-odds mixture-test) 1.0)
            0.0)))

(defun audit-sprt-step (ps)
  "Audit a canary observation's test positions when *AUDIT-SPRT-STEPS* is on"
  (when *audit-sprt-steps*
    (let ((stage (patch-set-stage ps)))
      (audit :sprt-step :patch-set (patch-set-name ps)
                        :stage (patch-set-stage-index ps)
                        :errors (stage-point stage (canary-stage-error-test stage))
                        :slow (stage-point stage (canary-stage-latency-test stage))))))

;;; ---------------------------------------------------------------------
;;; Rollback

(defun initiate-rollback-locked (ps trigger)
  "Caller holds the lock. Routes new tasks to :old at once and hands
completion to a drain thread. Returns :rolling-back, or :frozen when a lossy
class reversal needs an operator."
  ;; a lossy class reversal must not proceed automatically
  (when (and (some #'class-patch-lossy-p (patch-set-class-patches ps))
             (not (eq (car (if (consp trigger) trigger (list trigger)))
                      :operator)))
    (freeze-locked ps (list :lossy-reversal-needs-human :trigger trigger))
    (return-from initiate-rollback-locked :frozen))
  (setf (patch-set-current-fraction ps) 0)
  (transition ps :rolling-back :trigger trigger)
  (audit :rollback-decision :patch-set (patch-set-name ps) :trigger trigger
                            :pinned-new (patch-set-pinned-new ps)
                            :pinned-old (patch-set-pinned-old ps))
  (defer (lambda () (signal 'rollback-initiated :patch-set ps :trigger trigger)))
  (defer (lambda () (sb-thread:make-thread (lambda () (complete-rollback ps))
                                           :name (format nil "splice-rollback-~a"
                                                         (patch-set-name ps)))))
  :rolling-back)

(defun wait-for-drain (counter-fn timeout-seconds)
  (loop with deadline = (+ (get-internal-real-time)
                           (* timeout-seconds internal-time-units-per-second))
        while (plusp (funcall counter-fn))
        when (> (get-internal-real-time) deadline)
          do (return nil)
        do (sleep 0.005)
        finally (return t)))

(defun claim-transition (ps from to)
  "Move PS from FROM to TO, unless something else moved it first. Returns
:claimed or :abandoned."
  (with-set-lock (ps)
    (if (eq (patch-set-state ps) from)
        (progn (transition ps to) :claimed)
        (abandon-locked ps from to))))

(defun freeze-from (ps from reason)
  "Freeze PS if it is still in FROM. Returns :frozen or :abandoned."
  (with-set-lock (ps)
    (if (eq (patch-set-state ps) from)
        (progn (freeze-locked ps reason) :frozen)
        (abandon-locked ps from :frozen))))

(defun abandon-locked (ps expected wanted)
  "Audit a completion thread giving way to a state change it did not make."
  (audit :transition-abandoned :patch-set (patch-set-name ps)
                               :expected expected
                               :found (patch-set-state ps)
                               :wanted wanted)
  :abandoned)

(defun complete-rollback (ps)
  "Drain :new-pinned tasks, then claim the set and restore the old world. A
set that left :rolling-back during the drain (an operator freeze, say) is
left alone. Returns :rolled-back, :frozen or :abandoned."
  (cond ((not (wait-for-drain (lambda () (patch-set-pinned-new ps))
                              *drain-timeout-seconds*))
         (fail-rollback ps :rolling-back
                        (make-condition 'rollback-failure
                                        :patch-set ps
                                        :cause (format nil ":new-pinned tasks failed to drain in ~as"
                                                       *drain-timeout-seconds*))))
        ((eq :claimed (claim-transition ps :rolling-back :restoring))
         (restore-old-world ps))
        (t :abandoned)))

(defun fail-rollback (ps from failure)
  "The safety net itself failed: freeze PS for a human, unless it already
left FROM. Returns :frozen or :abandoned."
  (let ((outcome (freeze-from ps from
                              (list :rollback-failure (princ-to-string failure)))))
    (when (eq outcome :frozen)
      (audit :rollback-failed :patch-set (patch-set-name ps)
                              :cause (princ-to-string failure)))
    outcome))

(defun unrestored-parts (ps)
  "Every function, method and class of PS that the image doesn't hold in its
old form, read back from the image: function names, (gf-name specializers)
lists and class names. Empty when all of it is restored."
  (append (mapcar #'fn-patch-name
                  (remove-if #'old-function-restored-p (patch-set-fn-patches ps)))
          (mapcar (lambda (mp) (list (method-patch-gf-name mp)
                                     (method-patch-specializer-names mp)))
                  (remove-if #'old-method-restored-p (patch-set-method-patches ps)))
          (mapcar #'class-patch-class-name
                  (remove-if #'old-class-restored-p (patch-set-class-patches ps)))))

(defun old-function-restored-p (fp)
  (eq (fdefinition (fn-patch-name fp)) (fn-patch-old-fn fp)))

(defun old-method-restored-p (mp)
  "True when the generic function answers MP's specializers with the old method"
  (eq (find-old-method mp) (method-patch-old-method mp)))

(defun old-class-restored-p (cp)
  "True when the class's shape, read back now, is the one captured at registration"
  (equal (multiple-value-list (capture-class-shape (class-patch-class-name cp)))
         (list (class-patch-old-slot-specs cp) (class-patch-old-superclass-names cp))))

(defun restore-old-world (ps)
  "Swap the old functions and classes back in, reverse-migrate, verify. Runs
in :restoring, which an operator cannot move the set out of."
  (handler-case
      (progn
        (remove-fn-shims ps :world :old)
        (remove-method-shims ps :world :old)
        (let ((reversal-reports
                (mapcar (lambda (cp) (rollback-class-patch ps cp))
                        (patch-set-class-patches ps))))
          ;; verify restoration before declaring success
          (let ((unrestored (unrestored-parts ps)))
            (when unrestored
              (error 'rollback-failure :patch-set ps
                                       :cause (format nil "not restored: ~s" unrestored))))
          (setf (patch-set-last-reversal-report ps) reversal-reports)
          (with-set-lock (ps)
            (transition ps :rolled-back))
          (audit :rollback-complete :patch-set (patch-set-name ps)
                                    :restoration-verified t
                                    :reversal reversal-reports)
          :rolled-back))
    (rollback-failure (e)
      (fail-rollback ps :restoring e))))

;;; ---------------------------------------------------------------------
;;; Promotion

(defun begin-promotion-locked (ps)
  (transition ps :promoting)
  (defer (lambda () (sb-thread:make-thread (lambda () (complete-promotion ps))
                                           :name (format nil "splice-promote-~a"
                                                         (patch-set-name ps))))))

(defun complete-promotion (ps)
  "Drain :old-pinned tasks, then claim the set and swap in the new world. Drain that times
out freezes the set, so no :old task ever runs new code. Sets that leave :promoting
during the drain are left alone. Returns :promoted, :frozen, or :abandoned"
  (cond ((not (wait-for-drain (lambda () (patch-set-pinned-old ps))
                              *drain-timeout-seconds*))
         (freeze-from ps :promoting
                      (list :promotion-drain-timeout
                            :old-pinned (patch-set-pinned-old ps)
                            :timeout-seconds *drain-timeout-seconds*)))
        ((eq :claimed (claim-transition ps :promoting :swapping))
         (swap-in-new-world ps))
        (t :abandoned)))

(defun swap-in-new-world (ps)
  "The destructive install of the new world. Runs in :swapping, which an
operator cannot move the set out of."
  (remove-fn-shims ps :world :new)
  (remove-method-shims ps :world :new)
  (dolist (cp (patch-set-class-patches ps))
    (promote-class-patch ps cp))
  (with-set-lock (ps)
    (transition ps :promoted))
  (audit :promotion :patch-set (patch-set-name ps)
                    :functions (mapcar (lambda (fp)
                                         (list :name (fn-patch-name fp)
                                               :installed (fn-patch-new-source-hash fp)))
                                       (patch-set-fn-patches ps))
                    :journal-retained (migration-journal-count (patch-set-name ps)))
  :promoted)

;;; ---------------------------------------------------------------------
;;; Operator entry points and FROZEN handling

(defun freeze-locked (ps reason)
  (setf (patch-set-freeze-reason ps) reason
        (patch-set-current-fraction ps) 0)
  (transition ps :frozen :reason reason)
  (audit :freeze :patch-set (patch-set-name ps) :reason reason))

(defun refuse-locked (ps requested)
  "Signal ILLEGAL-TRANSITION once the lock is released, so its handlers run
outside it. Returns :refused, which the caller never sees."
  (let ((from (patch-set-state ps)))
    (defer (lambda ()
             (error 'illegal-transition :patch-set ps :from from
                                        :requested requested))))
  :refused)

(defun freeze (name reason &key (operator "unspecified"))
  "Stop a set where it is for an operator. Refused once a completion thread
has claimed the set (:restoring, :swapping) or the set has finished."
  (let ((ps (resolve-patch-set name)))
    (with-set-lock (ps)
      (freeze-operator-locked ps (list :operator operator :reason reason)))))

(defun freeze-operator-locked (ps reason)
  (let ((state (patch-set-state ps)))
    (cond ((eq state :frozen) :no-change)
          ((or (canary-stage-p state)
               (member state '(:staged :rolling-back :promoting)))
           (freeze-locked ps reason)
           :frozen)
          (t (refuse-locked ps :freeze)))))

(defun unfreeze (name decision &key (operator "unspecified"))
  "Resolve a FROZEN set: DECISION is :resume, :rollback, or :promote.
Every resolution is audited with the operator's identity. A set that isn't
frozen, or an unknown DECISION, is refused with ILLEGAL-TRANSITION before
anything is audited or cleared."
  (let ((ps (resolve-patch-set name)))
    (with-set-lock (ps)
      (if (and (eq (patch-set-state ps) :frozen)
               (member decision '(:resume :rollback :promote)))
          (unfreeze-locked ps decision operator)
          (refuse-locked ps :unfreeze)))))

(defun unfreeze-locked (ps decision operator)
  "Audit the unfreeze, clear the freeze reason and act on DECISION. Caller
holds the lock."
  (audit :unfreeze :patch-set (patch-set-name ps)
                   :operator operator :decision decision
                   :was-frozen-for (patch-set-freeze-reason ps))
  (setf (patch-set-freeze-reason ps) nil)
  (ecase decision
    (:resume (enter-stage ps (max 0 (patch-set-stage-index ps))))
    (:rollback (initiate-rollback-locked ps (list :operator operator)))
    (:promote (begin-promotion-locked ps))))

(defun roll-back (name &key (operator "unspecified"))
  "Operator-initiated rollback of a canarying, staged or frozen set. Quiet
when the set is already rolling back or rolled back; refused otherwise, and
always once sealed."
  (let ((ps (resolve-patch-set name)))
    (with-set-lock (ps)
      (roll-back-locked ps operator))))

(defun roll-back-locked (ps operator)
  (let ((state (patch-set-state ps)))
    (cond ((or (rolling-back-p state) (eq state :rolled-back)) :no-change)
          ((patch-set-sealed ps) (refuse-locked ps :roll-back))
          ((or (canary-stage-p state) (member state '(:staged :frozen)))
           (initiate-rollback-locked ps (list :operator operator)))
          (t (refuse-locked ps :roll-back)))))

(defun promote (name &key (operator "unspecified"))
  "Operator-forced promotion of a canarying or frozen set (bypasses remaining
ramp stages). Quiet when the set is already promoting or promoted; refused
otherwise."
  (let ((ps (resolve-patch-set name)))
    (with-set-lock (ps)
      (promote-locked ps operator))))

(defun promote-locked (ps operator)
  (let ((state (patch-set-state ps)))
    (cond ((or (promoting-p state) (eq state :promoted)) :no-change)
          ((or (canary-stage-p state) (eq state :frozen))
           (audit :force-promote :patch-set (patch-set-name ps) :operator operator)
           (begin-promotion-locked ps)
           :promoting)
          (t (refuse-locked ps :promote)))))

(defun seal-patch (name &key (operator "unspecified"))
  "Release a promoted set's migration journal; rollback of this set is no
longer offered."
  (let ((ps (resolve-patch-set name)))
    (with-set-lock (ps)
      (seal-locked ps operator))))

(defun seal-locked (ps operator)
  (cond ((patch-set-sealed ps) :no-change)
        ((eq :promoted (patch-set-state ps))
         (setf (patch-set-sealed ps) t)
         (audit :sealed :patch-set (patch-set-name ps) :operator operator)
         ;; outside the set lock, so the migration lock never nests in it
         (defer (lambda () (seal-class-journal ps)))
         :sealed)
        (t (refuse-locked ps :seal))))

(defun reverse-migration-report (name)
  "The reversal counts recorded by the last completed rollback of NAME or
:NOT-ROLLED-BACK"
  (patch-set-last-reversal-report (resolve-patch-set name)))

(defun unregister-patch-set (name)
  (remhash name *patch-sets*))

(defun wait-for-state (name-or-ps states &key (timeout 30))
  "Block until the set reaches one of STATES and return it or :TIMEOUT"
  (let ((ps (resolve-patch-set name-or-ps))
        (deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (let ((state (patch-set-state ps)))
        (when (member state states) (return state))
        (when (> (get-internal-real-time) deadline) (return :timeout))
        (sleep 0.01)))))

;;; ---------------------------------------------------------------------
;;; Audit-log reconstruction vs. the live image

;;; An impl or shape from RECONSTRUCT-STATE is (kind set-name). Every lookup
;;; below takes the whole impl or shape, so it searches only the set named.

(defun find-fn-patch (name impl)
  "The fn-patch for NAME in the set IMPL names or :UNPATCHED"
  (let ((ps (find-patch-set (second impl))))
    (or (and ps (find name (patch-set-fn-patches ps) :key #'fn-patch-name))
        :unpatched)))

(defun find-class-patch (class-name shape)
  "The class-patch for CLASS-NAME in the set SHAPE names or :UNPATCHED"
  (let ((ps (find-patch-set (second shape))))
    (or (and ps (find class-name (patch-set-class-patches ps)
                      :key #'class-patch-class-name))
        :unpatched)))

(defun impl-function (fp impl)
  "The function object IMPL's kind names for FP"
  (ecase (first impl)
    (:original (fn-patch-old-fn fp))
    (:shimmed (fn-patch-shim fp))
    (:new (fn-patch-new-fn fp))))

(defun shape-slot-names (cp shape)
  "Slot names CP's class has in SHAPE's kind"
  (mapcar (lambda (spec) (getf spec :name))
          (ecase (first shape)
            (:original (class-patch-old-slot-specs cp))
            (:union (class-patch-union-slots cp))
            (:new (class-patch-final-slots cp)))))

(defun live-slot-names (class-name)
  "Direct slot names of the live class CLASS-NAME or :NO-CLASS"
  (let ((class (find-class class-name nil)))
    (cond ((null class) :no-class)
          (t (sb-mop:finalize-inheritance class)
             (mapcar #'sb-mop:slot-definition-name
                     (sb-mop:class-direct-slots class))))))

(defun function-mismatch (name impl)
  "How the live function NAME differs from IMPL or :MATCH"
  (let ((fp (find-fn-patch name impl)))
    (cond ((eq fp :unpatched) (list name :no-registry-object impl))
          ((eq (fdefinition name) (impl-function fp impl)) :match)
          (t (list name :fdefinition-mismatch impl)))))

(defun class-mismatch (class-name shape)
  "How the live class CLASS-NAME differs from SHAPE or :MATCH"
  (let ((cp (find-class-patch class-name shape))
        (live (live-slot-names class-name)))
    (cond ((eq cp :unpatched) (list class-name :no-registry-object shape))
          ((and (listp live)
                (null (set-exclusive-or (shape-slot-names cp shape) live)))
           :match)
          (t (list class-name :class-shape-mismatch shape
                              :expected (shape-slot-names cp shape) :live live)))))

(defun verify-reconstruction (path)
  "Reconstruct expected image state from the audit log at PATH and compare
against the live image. Returns (values ok mismatches state)."
  (let* ((state (reconstruct-state path))
         (mismatches
           (remove :match
                   (append (loop for (name . impl) in (getf state :functions)
                                 collect (function-mismatch name impl))
                           (loop for (cname . shape) in (getf state :classes)
                                 collect (class-mismatch cname shape))))))
    (values (null mismatches) mismatches state)))
