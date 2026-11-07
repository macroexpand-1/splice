;;;; fixtures.lisp: the integration suite's root suite and live-set fixtures.
;;;;
;;;;   sbcl --non-interactive --eval '(require :asdf)' \
;;;;        --eval '(asdf:load-asd (truename "splice.asd"))' \
;;;;        --eval '(asdf:test-system "splice/integration-tests")'
;;;;
;;;; These tests install real patch sets and drive tasks through them, so
;;;; rollback and promotion threads run and some tests wait on them. They
;;;; share the unit suite's package and fixtures but not its root suite, so
;;;; (asdf:test-system "splice") stays unit only. From a REPL,
;;;; (fiveam:run! 'splice-tests::integration) runs everything here.

(in-package #:splice-tests)

(def-suite integration :description "Integration tests for splice: live sets.")

;;; ---------------------------------------------------------------------
;;; Live sets
;;; Each test installs a set over LIFECYCLE-PROBE and retires it
;;; afterwards, which puts the original function back.

(defun lifecycle-probe (x) x)

(defun failing-probe-set (name)
  "Every task canaries and every canary fails, so the error SPRT rejects at
its observation floor."
  (let ((ps (fn-patch-set name 'lifecycle-probe
                          (lambda (x) (error "canary broke on ~a" x)))))
    (setf (splice::patch-set-ramp ps) '(100)
          (splice::patch-set-sprt-min-n ps) 5
          (splice::patch-set-runtime-contract-interval ps) 0)
    ps))

(defun healthy-probe-set (name)
  "Two stages, so accepting the first enters the second rather than
starting a promotion thread."
  (let ((ps (fn-patch-set name 'lifecycle-probe (lambda (x) x))))
    (setf (splice::patch-set-ramp ps) '(50 100)
          (splice::patch-set-runtime-contract-interval ps) 0)
    ps))

(defun join-lifecycle-threads (ps)
  "Wait for PS's rollback and promotion threads, if any are running."
  (let ((names (list (format nil "splice-rollback-~a" (splice:patch-set-name ps))
                     (format nil "splice-promote-~a" (splice:patch-set-name ps)))))
    (dolist (thread (sb-thread:list-all-threads))
      (when (member (sb-thread:thread-name thread) names :test #'equal)
        (sb-thread:join-thread thread :default nil)))))

(defun roll-back-for-cleanup (ps)
  (if (eq :frozen (splice:patch-set-state ps))
      (splice:unfreeze ps :rollback :operator "unit-tests")
      (splice:roll-back ps :operator "unit-tests"))
  (splice:wait-for-state ps '(:rolled-back) :timeout 15)
  (join-lifecycle-threads ps))

(defun retire (ps)
  "Restore whatever PS replaced and drop it from the registry."
  (join-lifecycle-threads ps)
  (unless (or (splice::finished-p ps)
              (eq :registered (splice:patch-set-state ps)))
    (roll-back-for-cleanup ps))
  (splice:unregister-patch-set (splice:patch-set-name ps)))

(defmacro with-installed-set ((var form) &body body)
  "Register and install the set FORM makes, bind it to VAR for BODY, and
retire it whatever happened."
  `(let ((,var ,form))
     (unwind-protect (progn (splice:register-patch-set ,var)
                            (splice:install ,var)
                            ,@body)
       (retire ,var))))

(defun drive-tasks (done-p &key (limit 2000))
  "Run probe tasks until DONE-P returns true or LIMIT tasks have run."
  (loop for id from 1 to limit
        until (funcall done-p)
        do (splice:with-task (:id id :swallow-errors t)
             (funcall 'lifecycle-probe id))))
