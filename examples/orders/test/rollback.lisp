;;;; rollback.lisp: what a rollback restores, what the log reconstructs, and
;;;; how a lossy set and its runtime contracts behave, on the currency set.
;;;; No verdict here comes from wall-clock latency: rollbacks are the
;;;; operator's, and a set that must keep canarying either runs at 100%,
;;;; where no latency test runs, or stops before its latency test scores.

(in-package #:splice-orders/tests)

(def-suite rollback :in splice-orders-tests)
(in-suite rollback)

;;; ---------------------------------------------------------------------
;;; A set rolled back by the operator

(defun install-currency-set-at-100 ()
  "Install a fresh currency set with one 100% stage. Every task routes :new,
and the stage has no latency test, so healthy tasks cannot end it early."
  (let ((ps (orders:register-currency-patch-set :ramp '(100))))
    (splice:install ps)
    ps))

(defun migrate-orders-forward (orders)
  "Process each of ORDERS in a task on the new route, migrating it forward"
  (loop for order in orders
        for id from 1
        do (splice:with-task (:id id)
             (orders:process-order order))))

(defun roll-back-and-wait (ps)
  "Roll PS back as the operator and wait for it. Returns its final state"
  (splice:roll-back ps :operator "rollback-tests")
  (prog1 (splice:wait-for-state ps '(:rolled-back :frozen) :timeout 30)
    (join-completion-threads ps)))

(defun join-completion-threads (ps)
  "Wait for PS's rollback and promotion threads, if any are running"
  (let ((names (list (format nil "splice-rollback-~a" (splice:patch-set-name ps))
                     (format nil "splice-promote-~a" (splice:patch-set-name ps)))))
    (dolist (thread (sb-thread:list-all-threads))
      (when (member (sb-thread:thread-name thread) names :test #'equal)
        (sb-thread:join-thread thread :default nil)))))

(defun call-with-clean-workload (fn)
  "Call FN with a fresh global log's path and the pristine workload, and
restore the pristine workload after"
  (with-shared-log (path)
    (orders:reset-workload)
    (unwind-protect (funcall fn path)
      (orders:reset-workload))))

(defmacro with-clean-workload ((path) &body body)
  `(call-with-clean-workload (lambda (,path) ,@body)))

(test a-rollback-restores-functions-class-and-orders
  (with-clean-workload (path)
    (declare (ignore path))
    (let* ((orders (orders:make-pre-existing-orders (orders:make-rng 42) 40))
           (ps (install-currency-set-at-100)))
      (migrate-orders-forward orders)
      (is (eq :canary-100 (splice:patch-set-state ps)))
      (is (eq :rolled-back (roll-back-and-wait ps)))
      (let ((comparison (orders::compare-rollback-exactness ps))
            (reversal (first (splice:reverse-migration-report 'orders::currency-migration))))
        (is (getf comparison :fdefinitions-eq) "~s" comparison)
        (is (getf comparison :class-shape-original) "~s" comparison)
        (is (consp reversal) "~s" reversal)
        (is (= 40 (getf reversal :journal-exact)) "~s" reversal)
        ;; the canary's own writes survive rollback
        (is (= 0 (getf reversal :slots-undone)) "~s" reversal)))))

(defun workload-signature (seed count)
  "Totals from COUNT seeded orders run against whatever code and class shape
are live now"
  (let ((rng (orders:make-rng seed)))
    (loop for id from 1 to count
          collect (splice:with-task (:id id)
                    (orders:process-order (orders::random-order rng id))))))

(test the-workload-after-a-rollback-matches-a-never-patched-one
  (with-clean-workload (path)
    (declare (ignore path))
    (let ((never-patched (workload-signature 777 300))
          (ps (install-currency-set-at-100)))
      (migrate-orders-forward (orders:make-pre-existing-orders (orders:make-rng 42) 40))
      (is (eq :rolled-back (roll-back-and-wait ps)))
      (is (equal never-patched (workload-signature 777 300))))))

(test the-log-reconstructs-the-image-before-during-and-after
  (with-clean-workload (path)
    (let ((ps (orders:register-currency-patch-set :ramp '(100)))
          (orders (orders:make-pre-existing-orders (orders:make-rng 42) 40)))
      (is-true (splice:verify-reconstruction path) "before install")
      (splice:install ps)
      (migrate-orders-forward orders)
      (multiple-value-bind (ok mismatches state) (splice:verify-reconstruction path)
        (is-true ok "mid-canary: ~s" mismatches)
        (is (eq :canary-100 (cdr (assoc (splice:patch-set-name ps) (getf state :sets))))))
      (is (eq :rolled-back (roll-back-and-wait ps)))
      (is-true (splice:verify-reconstruction path) "after rollback"))))

;;; ---------------------------------------------------------------------
;;; A lossy set's hard trigger

(test a-hard-trigger-freezes-a-lossy-set-and-resume-continues-it
  (with-clean-workload (path)
    (declare (ignore path))
    (let ((corrupted (first (orders:make-pre-existing-orders (orders:make-rng 41) 1
                                                             :corrupted 1)))
          (ps (orders:register-currency-patch-set :lossy t)))
      (splice:install ps)
      ;; the corrupted order fails forward migration and arms the hard
      ;; trigger, which fires on any route
      (let ((orders:*fault* (orders:make-fault :kind :migration)))
        (splice:with-task (:id 1 :swallow-errors t)
          (orders:process-order corrupted)))
      (is (eq :frozen (splice:patch-set-state ps)))
      (is (eq :lossy-reversal-needs-human (first (splice::patch-set-freeze-reason ps))))
      (splice:unfreeze ps :resume :operator "rollback-tests")
      (splice:with-task (:id 2 :swallow-errors t)
        (orders:process-order (orders:make-test-order)))
      (is (splice::canary-stage-p (splice:patch-set-state ps))
          "state was ~s" (splice:patch-set-state ps))
      (is (eq :rolled-back (roll-back-and-wait ps))))))

;;; ---------------------------------------------------------------------
;;; Runtime contracts see old code

(defun route-probe (x)
  "Old side of the probe patch: names the code that ran. Call it through its
symbol: SBCL derives :OLD as the return type of a same-file DEFUN and would
type-check the shim's :NEW into an error."
  (declare (ignore x))
  :old)

(defun route-probe-set (seen)
  "A 50% set over ROUTE-PROBE whose contract pushes what a plain call to
ROUTE-PROBE ran onto (car SEEN), every tenth canary observation"
  (splice::make-patch-set
   :name 'route-probe-patch
   :ramp '(50)
   :runtime-contract-interval 10
   :fn-patches
   (list (splice::make-fn-patch
          :name 'route-probe
          :new-fn (lambda (x) (declare (ignore x)) :new)
          :new-source '(route-probe-new)
          :new-source-hash (splice:sha256-hex "route-probe-new")))
   :contracts
   (list (splice::make-contract
          :name 'old-call-reaches-old-code
          :check-fn (lambda ()
                      (let ((ran (funcall 'route-probe 1)))
                        (push ran (car seen))
                        (eq ran :old)))
          :source '(old-call-reaches-old-code)))))

(defun run-until-new-observations (ps count)
  "Run ROUTE-PROBE tasks until PS has COUNT canary observations in its stage.
Returns :reached, or :cap-reached after ten thousand tasks"
  (loop for id from 1 to 10000
        when (>= (splice::canary-stage-observations (splice::patch-set-stage ps)) count)
          return :reached
        do (splice:with-task (:id id) (funcall 'route-probe id))
        finally (return :cap-reached)))

(test a-runtime-contract-inside-a-canary-task-reaches-old-code
  ;; ten canary observations come long before the control arm has the 30
  ;; samples the latency test needs, so the stage can only be canarying
  (with-shared-log (path)
    (declare (ignore path))
    (let* ((seen (list '()))
           (ps (route-probe-set seen)))
      (splice:unregister-patch-set 'route-probe-patch)
      (splice:register-patch-set ps)
      (unwind-protect
           (progn
             (splice:install ps)
             (is (eq :reached (run-until-new-observations ps 10)))
             (is (eq :canary-50 (splice:patch-set-state ps)))
             ;; pre-flight once, then once at the tenth canary observation
             (is (equal '(:old :old) (car seen)) "seen ~s" (car seen)))
        (when (splice::canary-stage-p (splice:patch-set-state ps))
          (roll-back-and-wait ps))
        (splice:unregister-patch-set 'route-probe-patch)))))
