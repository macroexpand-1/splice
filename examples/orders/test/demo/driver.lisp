;;;; driver.lisp: tests for the demo's act driver

(in-package #:splice-orders/demo-tests)

(def-suite demo-driver :in demo :description "Act settings, refusal over a live act, recordings, the late gate.")
(in-suite demo-driver)

(test act-settings-passed
  (is (= 200 (getf (d::act-settings 1) :pre-existing)))
  (is (= 200 (getf (d::act-settings 2) :pre-existing)))
  (is (= 120 (getf (d::act-settings 1) :drain))))

(test refuse-over-live-session
  (let* ((gate d:*gate*)
         (recorder d::*recorder*)
         (act d:*current-act*)
         (old d::*session-thread*)
         (hold (sb-thread:make-semaphore))
         (thread (sb-thread:make-thread (lambda () (sb-thread:wait-on-semaphore hold)))))
    (setf d::*session-thread* thread)
    (unwind-protect
         (progn
           (is (eq :session-running (d:start-act 1 '())))
           (is (eq recorder d::*recorder*))
           (is (eq act d:*current-act*))
           (is (eq :session-running (d:reset-between-acts)))
           (is (eq gate d:*gate*)))
      (sb-thread:signal-semaphore hold)
      (sb-thread:join-thread thread)
      (setf d::*session-thread* old))))

(test a-stranded-held-task-blocks-the-reset
  (let ((gate d:*gate*)
        (old d::*session-thread*)
        (drain splice::*drain-timeout-seconds*))
    (setf d:*gate* (d:make-gate)
          d::*session-thread* nil)
    (unwind-protect
         (let ((straggler (sb-thread:make-thread #'d::await-release :name "orders-straggler")))
           (is (eq :session-running (d:reset-between-acts)))
           (d:open-gate d:*gate* :release-held)
           (sb-thread:join-thread straggler)
           (is (eq :reset (d:reset-between-acts))))
      (setf d:*gate* gate
            d::*session-thread* old
            splice::*drain-timeout-seconds* drain))))

(test one-recording-per-act
  (let ((old d::*recorder*)
        (path nil))
    (setf d::*recorder* nil)
    (unwind-protect
         (progn
           (setf path (d:start-recording 2))
           (is (equal path (d:stop-recording)))
           (is (eq :none (d:stop-recording)))
           (let ((header (with-open-file (in path) (d:read-snapshot in))))
             (is (eql 2 (getf header :act)))
             (is (eql 2002 (getf header :seed)))
             (is (eql 3 (getf header :threads)))))
      (d::close-recording)
      (when path (uiop:delete-file-if-exists path))
      (setf d::*recorder* old))))

(test gate-read-late
  (let ((old d:*gate*))
    (unwind-protect
         (progn
           (setf d:*gate* (d:make-gate))
           (let ((waiter (sb-thread:make-thread (lambda () (d::stage-pace 0)))))
             (d:open-gate d:*gate* :next-stage)
             (is (eq :next-stage (sb-thread:join-thread waiter :timeout 2 :default :timed-out)))))
      (setf d:*gate* old))))

(test act-1-unattended
  (with-demo-log (path)
    (declare (ignore path))
    (d:reset-between-acts)
    (dotimes (i 3) (d:open-gate d:*gate* :next-stage))
    (d:open-gate d:*gate* :release-held)
    (is (eq :promoted (orders:session-result-final-state (d:run-act 1))))
    (is (= 120 splice::*drain-timeout-seconds*))
    (d:reset-between-acts)))
