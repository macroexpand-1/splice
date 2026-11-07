;;;; lifecycle.lisp: the per-set lock's deferred effects (types.lisp),
;;;; which operator requests each state allows, and the completion threads'
;;;; checks, all on bare sets. The live-set tests are in
;;;; integration/lifecycle.lisp.

(in-package #:splice-tests)

(def-suite lifecycle :in splice-tests)
(in-suite lifecycle)

;;; ---------------------------------------------------------------------
;;; WITH-SET-LOCK

(test deferred-effects-run-after-release-in-order
  (let* ((ps (splice::make-patch-set :name 'lock-probe))
         (lock (splice::patch-set-lock ps))
         (seen '()))
    (is (eq :body (splice::with-set-lock (ps)
                    (splice::defer (lambda () (push (list :first (sb-thread:mutex-owner lock))
                                                    seen)))
                    (splice::defer (lambda () (push (list :second (sb-thread:mutex-owner lock))
                                                    seen)))
                    (is (null seen))
                    :body)))
    (is (equal '((:first nil) (:second nil)) (reverse seen)))))

(test defer-outside-the-lock-is-an-error
  (signals unbound-variable (splice::defer (lambda () nil))))

(test a-deferred-effect-can-take-the-lock-again
  (let ((ps (splice::make-patch-set :name 'lock-probe))
        (relocked nil))
    (splice::with-set-lock (ps)
      (splice::defer (lambda ()
                       (splice::with-set-lock (ps) (setf relocked t)))))
    (is-true relocked)))

;;; ---------------------------------------------------------------------
;;; Operator requests by state
;;; Which operator requests each state allows, on bare sets: none of these
;;; reach a transition, so nothing needs installing

(defun bare-set (state &rest initargs)
  (apply #'splice::make-patch-set :name 'bare :state state initargs))

(defun outcome-of (thunk)
  "THUNK's value, or :REFUSED when it signals ILLEGAL-TRANSITION."
  (handler-case (funcall thunk)
    (splice:illegal-transition () :refused)))

(defun state-trail (ps)
  (mapcar #'car (splice:patch-set-lifecycle-history ps)))

(test operator-requests-on-each-state
  (flet ((check (request states expected)
           (dolist (state states)
             (let ((ps (bare-set state)))
               (is (eq expected (outcome-of (lambda () (funcall request ps))))
                   "~a from ~a" request state)
               (is (eq state (splice:patch-set-state ps)))))))
    (let ((freeze-it (lambda (ps) (splice:freeze ps "probe" :operator "unit-tests")))
          (roll-it-back (lambda (ps) (splice:roll-back ps :operator "unit-tests")))
          (promote-it (lambda (ps) (splice:promote ps :operator "unit-tests")))
          (seal-it (lambda (ps) (splice:seal-patch ps :operator "unit-tests"))))
      (check freeze-it '(:frozen) :no-change)
      (check freeze-it '(:registered :restoring :swapping :rolled-back :promoted :vetoed)
             :refused)
      (check roll-it-back '(:rolling-back :restoring :rolled-back) :no-change)
      (check roll-it-back '(:registered :promoting :swapping :promoted :vetoed) :refused)
      (check promote-it '(:promoting :swapping :promoted) :no-change)
      (check promote-it '(:registered :staged :rolling-back :restoring :rolled-back :vetoed)
             :refused)
      (check seal-it '(:registered :canary-5 :frozen :rolling-back :rolled-back) :refused))))

;;; ---------------------------------------------------------------------
;;; Completion threads
;;; Completion threads give way to a freeze that lands during the drain.
;;; Nothing is pinned, so the drain ends at once.

(test a-rollback-thread-leaves-a-frozen-set-alone
  (let ((ps (bare-set :frozen)))
    (is (eq :abandoned (splice::complete-rollback ps)))
    (is (eq :frozen (splice:patch-set-state ps)))))

(test a-promotion-thread-leaves-a-frozen-set-alone
  (let ((ps (bare-set :frozen)))
    (is (eq :abandoned (splice::complete-promotion ps)))
    (is (eq :frozen (splice:patch-set-state ps)))))

;;; Promotion swaps only after the :old pins drain (decision 0008). A bare
;;; set has no shims, so these exercise the drain and the claim alone.

(test a-drain-timeout-freezes-instead-of-swapping
  (let ((ps (bare-set :promoting :pinned-old 1))
        (splice::*drain-timeout-seconds* 0.05))
    (is (eq :frozen (splice::complete-promotion ps)))
    (is (eq :frozen (splice:patch-set-state ps)))
    (is (eq :promotion-drain-timeout (first (splice::patch-set-freeze-reason ps))))
    (is (equal '(:frozen) (state-trail ps)) "trail was ~s" (state-trail ps))))

(test a-drain-that-completes-swaps
  (let ((ps (bare-set :promoting)))
    (is (eq :promoted (splice::complete-promotion ps)))
    (is (equal '(:swapping :promoted) (state-trail ps)) "trail was ~s" (state-trail ps))))
