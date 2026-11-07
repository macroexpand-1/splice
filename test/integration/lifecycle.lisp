;;;; lifecycle.lisp: operator handlers that re-enter the lifecycle from a
;;;; verdict or a rollback signal, and sealing, on live sets.

(in-package #:splice-tests)

(def-suite live-lifecycle :in integration)
(in-suite live-lifecycle)

(defun escaped-error (thunk)
  "The error THUNK lets escape, or :NONE when it returns."
  (handler-case (progn (funcall thunk) :none)
    (error (e) e)))

(defun freezing-handler (ps seen)
  "A handler that records its condition in the cons SEEN and freezes PS."
  (lambda (c)
    (push c (car seen))
    (splice:freeze ps "operator handler" :operator "unit-tests")))

;;; ---------------------------------------------------------------------
;;; Operator handlers re-entering the lifecycle

(test a-verdict-handler-can-freeze-after-an-accept
  (with-installed-set (ps (healthy-probe-set 'accept-then-freeze))
    (let* ((seen (list '()))
           (escaped (escaped-error
                     (lambda ()
                       (handler-bind ((splice:canary-verdict (freezing-handler ps seen)))
                         (drive-tasks (lambda () (car seen))))))))
      (is (eq :none escaped) "~a escaped the task" escaped)
      (is (= 1 (length (car seen))))
      (is (eq :accept (splice:canary-verdict-direction (first (car seen)))))
      (is (search '(:canary-50 :canary-100 :frozen) (state-trail ps))
          "trail was ~s" (state-trail ps))
      (is (eq :frozen (splice:patch-set-state ps)))
      (is (eq :operator (first (splice::patch-set-freeze-reason ps)))))))

(test a-verdict-handler-can-freeze-after-a-reject
  (with-installed-set (ps (failing-probe-set 'reject-then-freeze))
    (let* ((seen (list '()))
           (escaped (escaped-error
                     (lambda ()
                       (handler-bind ((splice:canary-verdict (freezing-handler ps seen)))
                         (drive-tasks (lambda () (car seen))))))))
      (is (eq :none escaped) "~a escaped the task" escaped)
      (is (= 1 (length (car seen))))
      (is (eq :reject (splice:canary-verdict-direction (first (car seen)))))
      ;; the rollback was decided before the handler ran, and its thread
      ;; gives way to the freeze once the drain ends
      (join-lifecycle-threads ps)
      (is (search '(:canary-100 :rolling-back :frozen) (state-trail ps))
          "trail was ~s" (state-trail ps))
      (is (eq :frozen (splice:patch-set-state ps))))))

(test a-rollback-handler-can-freeze-an-operator-rollback
  (with-installed-set (ps (healthy-probe-set 'operator-rollback-then-freeze))
    (let* ((seen (list '()))
           (escaped (escaped-error
                     (lambda ()
                       (handler-bind ((splice:rollback-initiated (freezing-handler ps seen)))
                         (splice:roll-back ps :operator "unit-tests"))))))
      (is (eq :none escaped) "~a escaped roll-back" escaped)
      (is (= 1 (length (car seen))))
      (is (eq :operator (first (splice:rollback-initiated-trigger (first (car seen))))))
      (join-lifecycle-threads ps)
      (is (search '(:canary-50 :rolling-back :frozen) (state-trail ps))
          "trail was ~s" (state-trail ps))
      (is (eq :frozen (splice:patch-set-state ps))))))

(test a-verdict-handler-that-rolls-back-starts-one-rollback
  (with-installed-set (ps (failing-probe-set 'reject-then-roll-back))
    (let* ((returned (list '()))
           (escaped (escaped-error
                     (lambda ()
                       (handler-bind ((splice:canary-verdict
                                        (lambda (c)
                                          (declare (ignore c))
                                          (push (splice:roll-back ps :operator "unit-tests")
                                                (car returned)))))
                         (drive-tasks (lambda () (car returned))))))))
      (is (eq :none escaped) "~a escaped the task" escaped)
      (is (equal '(:no-change) (car returned)))
      (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15)))
      (join-lifecycle-threads ps)
      (is (= 1 (count :rolling-back (state-trail ps)))
          "trail was ~s" (state-trail ps))
      (is (= 1 (count :restoring (state-trail ps)))
          "trail was ~s" (state-trail ps)))))

;;; ---------------------------------------------------------------------
;;; Sealing

(test a-sealed-set-cannot-be-rolled-back
  (let ((original (fdefinition 'lifecycle-probe)))
    (unwind-protect
         (with-installed-set (ps (healthy-probe-set 'promote-then-seal))
           (is (eq :promoting (splice:promote ps :operator "unit-tests")))
           (is (eq :promoted (splice:wait-for-state ps '(:promoted) :timeout 15)))
           (join-lifecycle-threads ps)
           (is (equal '(:canary-50 :promoting :swapping :promoted)
                      (last (state-trail ps) 4))
               "trail was ~s" (state-trail ps))
           (is (eq :sealed (splice:seal-patch ps :operator "unit-tests")))
           (signals splice:illegal-transition (splice:roll-back ps :operator "unit-tests"))
           (is (eq :promoted (splice:patch-set-state ps))))
      (setf (fdefinition 'lifecycle-probe) original))))

(test sealing-a-canarying-set-is-refused
  (with-installed-set (ps (healthy-probe-set 'seal-mid-canary))
    (signals splice:illegal-transition (splice:seal-patch ps :operator "unit-tests"))
    (is-false (splice::patch-set-sealed ps))
    (is (eq :canary-50 (splice:patch-set-state ps)))))
