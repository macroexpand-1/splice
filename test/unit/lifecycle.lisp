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
;;; Stage limit
;;; A stage with no control traffic can never score latency, so only the
;;; limit ends it.

(defun starved-stage-set (limit)
  "A :CANARY-100 set with an empty control ring and stage limit LIMIT."
  (let ((ps (bare-set :canary-100 :ramp '(100) :current-fraction 100 :stage-index 0
                      :stage-limit limit :runtime-contract-interval 0
                      :control-ring (splice::make-control-ring)
                      :null-ring (splice::make-control-ring))))
    (setf (splice::patch-set-stage ps) (splice::fresh-stage ps 100))
    ps))

(test a-starved-stage-freezes-at-its-limit
  (let ((ps (starved-stage-set 3)))
    (is (eq :continue (splice::report-outcome ps :new nil 1.0)))
    (is (eq :continue (splice::report-outcome ps :new nil 1.0)))
    (splice::report-outcome ps :new nil 1.0)
    (is (eq :frozen (splice:patch-set-state ps)))
    (is (eq :stage-timeout (first (splice::patch-set-freeze-reason ps))))
    (is (= 3 (getf (rest (splice::patch-set-freeze-reason ps)) :observations)))))

(test entering-a-stage-resets-its-count
  (let ((ps (starved-stage-set 10)))
    (splice::report-outcome ps :new nil 1.0)
    (splice::with-set-lock (ps) (splice::enter-stage ps 0))
    (is (= 0 (splice::canary-stage-observations (splice::patch-set-stage ps))))))

(test only-a-stage-with-a-control-arm-tests-latency
  (let ((ps (starved-stage-set 10)))
    (is (eq :unscored (splice::canary-stage-latency-test (splice::fresh-stage ps 25))))
    (is (eq :untested (splice::canary-stage-latency-test (splice::fresh-stage ps 100))))))

(test a-full-stage-scores-slow-canaries-without-rejecting
  "At 100% nothing compares latency, so slow canaries count toward the budget"
  (let ((ps (starved-stage-set 1000)))
    (dotimes (i 200)
      (splice::control-record (splice::patch-set-null-ring ps) nil 1.0))
    (dotimes (i 200)
      (splice::report-outcome ps :new nil 1000.0))
    (is (eq :canary-100 (splice:patch-set-state ps)))
    (is (= 200 (splice::canary-stage-scored (splice::patch-set-stage ps))))
    (is (eq :untested (splice::canary-stage-latency-test (splice::patch-set-stage ps))))))

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

;;; ---------------------------------------------------------------------
;;; Hard triggers and waiting

(test installing-a-set-that-is-not-registered-is-refused
  (dolist (state '(:installing :staged :canary-5 :vetoed))
    (let ((ps (bare-set state)))
      (signals splice:illegal-transition (splice:install ps))
      (is (eq state (splice:patch-set-state ps))))))

(test taking-a-hard-trigger-leaves-it-unarmed
  (let ((ps (bare-set :canary-5)))
    (is (eq :unarmed (splice::take-hard-trigger ps)))
    (splice::arm-hard-trigger ps '(:storage-condition "probe"))
    (splice::arm-hard-trigger ps '(:migration-failure "second"))
    (is (equal '(:storage-condition "probe") (splice::take-hard-trigger ps)))
    (is (eq :unarmed (splice::take-hard-trigger ps)))))

(test waiting-past-the-deadline-is-a-timeout
  (is (eq :timeout (splice:wait-for-state (bare-set :staged) '(:promoted) :timeout 0))))

;;; ---------------------------------------------------------------------
;;; Naming a set

(test an-unknown-set-name-is-an-error
  (signals splice:unknown-patch-set (splice:freeze 'no-such-set "probe"))
  (signals splice:unknown-patch-set (splice:roll-back 'no-such-set))
  (signals splice:unknown-patch-set (splice:current-route 'no-such-set))
  (signals splice:unknown-patch-set (splice:reverse-migration-report 'no-such-set)))

(test a-set-never-rolled-back-has-no-reversal-report
  (with-patch-set-names (report-probe)
    (setf (gethash 'report-probe splice::*patch-sets*)
          (splice::make-patch-set :name 'report-probe))
    (is (eq :not-rolled-back (splice:reverse-migration-report 'report-probe)))))

;;; ---------------------------------------------------------------------
;;; Reconstruction against the live image

(test an-unknown-function-impl-is-an-error
  (signals error (splice::impl-function (splice::make-fn-patch) '(:bogus s))))

(test an-unpatched-name-has-no-registry-object
  (is (equal '(no-such-fn :no-registry-object (:original no-such-set))
             (splice::function-mismatch 'no-such-fn '(:original no-such-set))))
  (is (equal '(no-such-class :no-registry-object (:union no-such-set))
             (splice::class-mismatch 'no-such-class '(:union no-such-set)))))

(test lookups-search-only-the-set-the-impl-names
  (with-patch-set-names (owner-a owner-b)
    (flet ((register (set-name)
             (let ((ps (splice::make-patch-set
                        :name set-name
                        :fn-patches (list (splice::make-fn-patch :name 'shared-fn))
                        :class-patches (list (splice::make-class-patch
                                              :class-name 'shared-class)))))
               (setf (gethash set-name splice::*patch-sets*) ps))))
      (let ((a (register 'owner-a))
            (b (register 'owner-b)))
        (is (eq (first (splice::patch-set-fn-patches b))
                (splice::find-fn-patch 'shared-fn '(:new owner-b))))
        (is (eq (first (splice::patch-set-fn-patches a))
                (splice::find-fn-patch 'shared-fn '(:original owner-a))))
        (is (eq (first (splice::patch-set-class-patches b))
                (splice::find-class-patch 'shared-class '(:new owner-b))))
        (is (eq :unpatched (splice::find-fn-patch 'shared-fn '(:new owner-c))))))))
