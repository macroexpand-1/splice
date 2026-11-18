;;;; check.lisp: every check, each in a fresh SBCL.
;;;;
;;;;   sbcl --non-interactive --load test/check.lisp
;;;;
;;;; CI and the pre-push hook (.githooks/pre-push) both run this file, so the
;;;; two run the same checks. It stops at the first failing check and exits 1;
;;;; it exits 0 when every check passes.
;;;;
;;;; Each check gets its own image because the demo and the criteria patch the
;;;; live image, and a suite loaded beside them would see what they changed.
;;;;
;;;; The criteria run 100 times per fault class, about 2 to 4 minutes. C7 is
;;;; a timing check (the canary shim must cost under 2x a plain call, 1.37x
;;;; locally), so it is the likeliest to flake on a noisy machine (T106).

(require :asdf)

(defpackage #:splice-check
  (:use #:common-lisp))

(in-package #:splice-check)

(defstruct check
  (name nil :read-only t)
  (arguments nil :read-only t))

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

(defun test-check (system-name)
  (make-check :name (format nil "test ~a" system-name)
              :arguments (system-arguments "asdf:test-system" system-name)))

(defun load-check (system-name)
  (make-check :name (format nil "load ~a" system-name)
              :arguments (system-arguments "asdf:load-system" system-name)))

(defun script-check (path)
  (make-check :name (format nil "script ~a" path)
              :arguments (list "--load" path)))

(defparameter *checks*
  (list (test-check "splice")
        (test-check "splice/cluster")
        ;; Checks that the transport compiles, and that the protocol loads
        ;; without the orders example. No test opens a socket (T104).
        (load-check "splice/cluster-tcp")
        (test-check "splice/integration-tests")
        (test-check "splice-orders/tests")
        (test-check "splice-orders/demo-probe")
        (test-check "splice-orders/demo-tests")
        (script-check "examples/orders/scripts/demo.lisp")
        ;; Writes examples/orders/artifacts/criteria-report.md, which CI uploads.
        (test-check "splice-orders/criteria"))
  "Every check, in the order they run: fast suites first, the criteria last.")

;;; ---------------------------------------------------------------------
;;; Running

(defun sbcl-command (check)
  "The command line for CHECK, run by the same SBCL that loaded this file"
  (list* (namestring sb-ext:*runtime-pathname*)
         "--non-interactive"
         (check-arguments check)))

(defun check-passes-p (check)
  (format t "~&~%=== ~a ===~%" (check-name check))
  (finish-output)
  (zerop (nth-value 2 (uiop:run-program (sbcl-command check)
                                        :directory *root*
                                        :output :interactive
                                        :error-output :interactive
                                        :ignore-error-status t))))

(defun run-checks (checks)
  "Run CHECKS in order and stop at the first failure. Returns :passed, or
:failed with the failing check as a second value."
  (dolist (check checks :passed)
    (unless (check-passes-p check)
      (return (values :failed check)))))

(defun report-and-exit (outcome &optional check)
  (ecase outcome
    (:passed
     (format t "~&~%=== all ~d checks passed ===~%" (length *checks*))
     (uiop:quit 0))
    (:failed
     (format t "~&~%=== FAILED: ~a ===~%" (check-name check))
     (uiop:quit 1))))

(multiple-value-call #'report-and-exit (run-checks *checks*))
