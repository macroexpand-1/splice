;;;; check.lisp: every check, each in a fresh SBCL.
;;;;
;;;;   sbcl --non-interactive --load test/check.lisp
;;;;
;;;; CI and the pre-push hook (.githooks/pre-push) both run this file, so the
;;;; two run the same checks. It stops at the first failing check and exits 1;
;;;; it exits 0 when every check passes.
;;;;
;;;; Each check gets its own image because the demo patches the live image,
;;;; and a suite loaded beside it would see what it changed.
;;;;
;;;; The criteria are not a check. They measure detection rates over 100
;;;; sessions per fault class and the shim's cost in nanoseconds, so their
;;;; numbers move with chance and with the machine. CI runs them in a step of
;;;; their own and uploads the report without gating on it.
;;;;
;;;; Every check has a deadline of 10 minutes. A check still running at its
;;;; deadline is killed and reported as timed out, so a hang fails the run
;;;; instead of stalling it. The slowest suites take about a minute locally.

(require :asdf)

(defpackage #:splice-check
  (:use #:common-lisp))

(in-package #:splice-check)

(defstruct check
  (name nil :read-only t)
  (arguments nil :read-only t)
  (deadline-seconds nil :read-only t))

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*))
  "The repository root. Every check runs from here.")

;;; ---------------------------------------------------------------------
;;; Checks

(defun eval-arguments (forms)
  "SBCL arguments that evaluate each of FORMS, a list of strings, in order"
  (loop for form in forms
        append (list "--eval" form)))

(defun system-arguments (operation system-name)
  "SBCL arguments that load both system definitions and then call
OPERATION, a string such as \"asdf:test-system\", on SYSTEM-NAME"
  (eval-arguments
   (list "(require :asdf)"
         "(asdf:load-asd (truename \"splice.asd\"))"
         "(asdf:load-asd (truename \"examples/orders/splice-orders.asd\"))"
         (format nil "(~a ~s)" operation system-name))))

(defun test-check (system-name &key (deadline-seconds 600))
  (make-check :name (format nil "test ~a" system-name)
              :arguments (system-arguments "asdf:test-system" system-name)
              :deadline-seconds deadline-seconds))

(defun load-check (system-name)
  (make-check :name (format nil "load ~a" system-name)
              :arguments (system-arguments "asdf:load-system" system-name)
              :deadline-seconds 600))

(defun script-check (path)
  (make-check :name (format nil "script ~a" path)
              :arguments (list "--load" path)
              :deadline-seconds 600))

(defparameter *checks*
  (list (test-check "splice")
        (test-check "splice/cluster")
        ;; Checks that the transport compiles, and that the protocol loads
        ;; without the orders example. No test opens a socket yet.
        (load-check "splice/cluster-tcp")
        (test-check "splice/integration-tests")
        (test-check "splice-orders/tests")
        (test-check "splice-orders/demo-probe")
        (test-check "splice-orders/demo-tests")
        (script-check "examples/orders/scripts/demo.lisp"))
  "Every check, in the order they run, fast suites first.")

;;; ---------------------------------------------------------------------
;;; Running

(defun sbcl-command (check)
  "The command line for CHECK, run by the same SBCL that loaded this file"
  (list* (namestring sb-ext:*runtime-pathname*)
         "--non-interactive"
         (check-arguments check)))

(defun seconds-since (start)
  "Whole seconds since START, in internal real time"
  (floor (- (get-internal-real-time) start) internal-time-units-per-second))

(defun print-heartbeat (check elapsed)
  "A line saying CHECK is still running after ELAPSED seconds"
  (multiple-value-bind (minutes seconds) (floor elapsed 60)
    (format t "~%[~a: ~dm ~2,'0ds elapsed]~%" (check-name check) minutes seconds))
  (finish-output))

(defun wait-for-exit (process check)
  "Poll PROCESS, which runs CHECK, until it exits, with a heartbeat line every
minute. Returns :exited, or :timed-out once CHECK's deadline passes"
  (loop with start = (get-internal-real-time)
        for tick from 1
        for elapsed = (seconds-since start)
        unless (uiop:process-alive-p process)
          return :exited
        when (> elapsed (check-deadline-seconds check))
          return :timed-out
        when (zerop (mod tick 60))
          do (print-heartbeat check elapsed)
        do (sleep 1)))

(defun run-check (check)
  "Run CHECK in a fresh SBCL and kill it at its deadline. Returns :passed,
:failed or :timed-out"
  (format t "~&~%=== ~a ===~%" (check-name check))
  (finish-output)
  (let ((process (uiop:launch-program (sbcl-command check)
                                      :directory *root*
                                      :output :interactive
                                      :error-output :interactive)))
    (ecase (wait-for-exit process check)
      (:exited
       (if (zerop (uiop:wait-process process)) :passed :failed))
      (:timed-out
       (uiop:terminate-process process :urgent t)
       (uiop:wait-process process)
       :timed-out))))

(defun run-checks (checks)
  "Run CHECKS in order and stop at the first that does not pass. Returns
:passed, or :failed or :timed-out with that check as a second value."
  (dolist (check checks :passed)
    (let ((outcome (run-check check)))
      (unless (eq outcome :passed)
        (return (values outcome check))))))

(defun report-and-exit (outcome &optional check)
  (ecase outcome
    (:passed
     (format t "~&~%=== all ~d checks passed ===~%" (length *checks*))
     (uiop:quit 0))
    (:failed
     (format t "~&~%=== FAILED: ~a ===~%" (check-name check))
     (uiop:quit 1))
    (:timed-out
     (format t "~&~%=== TIMED OUT after ~ds: ~a ===~%"
             (check-deadline-seconds check) (check-name check))
     (uiop:quit 1))))

(multiple-value-call #'report-and-exit (run-checks *checks*))
