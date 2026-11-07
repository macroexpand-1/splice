;;;; package.lisp: the orders example's test package, root suite and log helpers.
;;;;
;;;;   (asdf:test-system "splice-orders")

(defpackage #:splice-orders/tests
  (:use #:common-lisp #:fiveam)
  (:local-nicknames (#:orders #:splice-orders))
  (:export #:splice-orders-tests))
(in-package #:splice-orders/tests)

(def-suite splice-orders-tests :description "Tests for the orders example.")

(defun temp-log-path ()
  (merge-pathnames (format nil "splice-orders-~a.log" (random most-positive-fixnum
                                                              (make-random-state t)))
                   (uiop:temporary-directory)))

(defun log-entries (path)
  "Every entry of the log at PATH, oldest first, chain not checked."
  (let ((entries '()))
    (splice::map-audit-entries path (lambda (entry) (push entry entries))
                               :verify nil)
    (nreverse entries)))
