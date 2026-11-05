;;;; decisions.lisp: operator decisions at the canary's decision points
;;;;
;;;; The evaluator reaches a decision point one of the following:
;;;; SPRT verdict, failing runtime contract, a stage timeout or a
;;;; confounding control arm. Calls SETTLE-LOCKED.
;;;; Outside WITH-OPERATOR-DECISIONS that does what splice always did.
;;;; Inside it the set is flash frozen, so no second verdict can arrive
;;;; and no fresh task routes to new code. Once the set lock is released the
;;;; worker thread enters debugger wiht four restart options. The choice is
;;;; under the lock and only if teh set is still frozen (for this decision)
;;;;
(in-package #:splice)

(defvar *operator-decisions* nil
  "True where decision points ask the debugger. Only ever bound.")

(defmacro with-operator-deicions (&body body)
  "Decision points reached on this thread ask the operator. Wrap the task loop."
  `(let ((*operator-decisions* t))
     ,@body)
  )

;;; ---------------------------------------------------------------------
;;; Settling a decision point. DEFAULT is what splice does there: :ROLL-BACK,
;;; :ADVANCE, :PROMOTE or :FREEZE. CAUSE is the rollback trigger or freeze
;;; reason it does with.

(defun settle-locked (ps point default cause)
  "Do DEFAULT with CAUSE, or hold PS for an operator  (if one is watching)"
  (if *operator-decisions*
      (hold-for-operator-locked ps point defualt cause)
      (splice-default-locked ps default cause)))

(defun rollback-default (ps trigger)
  "Default and cause for a rollback: a lossy set freezes instead"
  (if (some #'class-patch-lossy-p (patch-set-class-patches ps))
      (values :freeze (list :lossy-reversal-needs-human :trigger trigger))
      (values :roll-back trigger)))

(defun settle-rollblack-locks (ps point trigger)
  "SETTLE-LOCKED for a decision point whose default is a rollback"
  (multiple-value-bind (default cause) (rollback-default ps trigger)
    (settle-locked ps point default cause)))

(defun splice-default-locked  (ps default cause)
  "What splice does when nobody is asked or the operator defers to it"
  (ecase default
    (:roll-back (initiate-rollback-locked ps cause))
    (:advance (enter-stage ps (1+ (patch-set-stage-index ps)))
     :advanced)
    (:promote (begin-promotion-locked ps)
     :promoting)
    (:freeze (if (eq :frozen (patch-set-state ps))
                 (refreeze-locked ps cause)
                 (freeze-locked ps cause))
     :frozen)))

(defun refreeze-locked (ps reason)
  "New freeze REASON on a frozen PS. Audited but no transition"
  (setf (patch-set-freeze-reason ps) reason)
  (audit :freeze :patch-set (patch-set-name ps) :reason reason))

;;; ---------------------------------------------------------------------
;;; Holding a set while an operator decides

(defun hold-for-operator-lock (ps point default cause)
  "Freeze PS and ask the operator once the lock is released"
  (let* ((hold-reason (list :awaiting-operator :point point
                                               :default default :cause cause))
         (decision (make-condition 'operator-decision
                                   :patch-set ps :point point
                                   :default default :cause cause
                                   :hold-reason hold-reason)))
    (freeze-locked ps hold-reason)
    (defer (lambda () (ask-operator decision)))
    :frozen))

(defun still-held-p (ps decision)
  "True while PS is still frozen for DECISION and nothing else moved it."
  (and (eq :frozen (patch-set-state ps))
       (eq (operator-decision-hold-reason decision)
           (patch-set-freeze-reason ps))))

;;; ---------------------------------------------------------------------
;;; Asking: the debugger and the four restarts

(defun ask-operator (decision)
  "Ask handlers then the debugger - apply their choice. Never under the lock"
  (let ((ps (splice-condition-patch-set decision)))
    (assert (not (sb-thread:holding-mutex-p (patch-set-lock ps))) ()
            "~a's lock is held while asking an operator" (patch-set-name ps))
    (if (with-set-lock (ps) (still-held-p decision))
        (apply-decision decision (choose decision))
        :abandoned)))

(defun choose (decision)
  "The restart picked for DECISION, as a choice keyword"
  (let ((name (name-of (splice-condition-patch-set decision))))
    (restart-case (progn (signal decision)
                         (invoke-debugger decision))
      (roll-back-patch ()
        :report (lambda (stream)
                  (format stream "Roll back ~a: restore the old code" name))
        :roll-back)
      (freeze-patch ()
        :report (lambda (stream)
                  (format stream "Keep ~a frozen; new tasks run old code" name))
        :freeze)
      (promote-anyway ()
        :report (lambda (stream)
                  (format stream "Promote ~a now, skipping the rest of the ramp" name))
        :promote)
      (let-splice-decide ()
        :report (lambda (stream)
                  (format stream "Let splice decide: ~a"
                          (default-description (operator-decision-default decision))))
        :splice-decides))))

(defun point-description (point)
  (ecase point
    (:sprt-reject "an SPRT reject")
    (:runtime-contract "a failing runtime contract")
    (:sprt-accept "a SPRT accept")
    (:stage-timeout "a stage timeout")
    (:confounded "a confounded control arm")))

(defun default-description (default)
  (ecase default
    (:roll-back "roll back")
    (:advance "advance to the next stage")
    (:promote "promote")
    (:freeze "keep it frozen")))

;;; Functions that invoke the restarts for handlers and for buttons.
;;; In the manner of CL:ABORT and CL:CONTINUE

(defun invoke-decision-restart (name condition)
  "Invoke restart NAME, CONDITION's if given"
  (invoke-restart (or (find-restart name condition) name)))

(defun roll-back-patch (&optional condition)
  "Invoke the ROLL-BACK-PATCH restart"
  (invoke-decision-restart 'roll-back-patch condition))

(defun freeze-patch (&optional condition)
  "Invoke the FREEZE-PATCH retart"
  (invoke-decision-restart 'freeze-patch condition))

(defun promote-anyway (&optional condition)
  "Invoke teh PROMOTE-ANYWAY restart"
  (invoke-decision-restart 'promote-anyway condition))

(defun let-spice-decide (&optional condition)
  "Invoke the LET-SPLICE-DECIDE restart"
  (invoke-decision-restart 'let-splice-decide condition))

;;; ---------------------------------------------------------------------
;;; Applying the choice, under the lock, if the set is still held

(defun apply-decision (decision choice)
  "Apply CHOICE if the set is still held, otherwise audit it as abandoned"
  (let ((ps (splice-condition-patch-set decision)))
    (with-set-lock (ps)
      (if (still-held-p ps decision)
          (decide-locked ps decision choice)
          (abandon-decision-locked ps )))))
