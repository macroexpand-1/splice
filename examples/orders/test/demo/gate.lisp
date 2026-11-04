;;;; gate.lisp: tests for the demo's presenter gate

(in-package #:splice-orders/demo-tests)

(def-suite demo-gate :in demo :description "One click, one release.")
(in-suite demo-gate)

(test gate-one-click-one-release
  (let* ((gate (d:make-gate))
         (passed (list 0))
         (waiters (loop repeat 2
                        collect (sb-thread:make-thread
                                 (lambda ()
                                   (d:await-gate gate :next-stage)
                                   (sb-ext:atomic-incf (car passed)))))))
    (d:open-gate gate :next-stage)
    (sleep 0.2)
    (is (= 1 (car passed)))
    (d:open-gate gate :next-stage)
    (mapc #'sb-thread:join-thread waiters)
    (is (= 2 (car passed)))))
