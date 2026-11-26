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

(test a-verdict-handler-can-freeze-after-a-pass
  (with-installed-set (ps (healthy-probe-set 'pass-then-freeze))
    (let* ((seen (list '()))
           (escaped (escaped-error
                     (lambda ()
                       (handler-bind ((splice:canary-verdict (freezing-handler ps seen)))
                         (drive-tasks (lambda () (car seen))))))))
      (is (eq :none escaped) "~a escaped the task" escaped)
      (is (= 1 (length (car seen))))
      (is (eq :pass (splice:canary-verdict-direction (first (car seen)))))
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
;;; A declared set, end to end
;;; DEFPATCH-SET as a user writes it: declare, install, run tasks, promote.

(defun shipping-cost (weight-kg)
  (* 4 weight-kg))

(defun declare-flat-rate-shipping ()
  "Declare and register FLAT-RATE-SHIPPING, and return the set."
  (splice:defpatch-set flat-rate-shipping
      (:description "Flat rate for parcels under 2 kg"
       :ramp '(50 100)
       :min-effect 3d0)
    (:function shipping-cost
     (lambda (weight-kg)
       (if (< weight-kg 2) 5 (* 4 weight-kg))))
    (:contract never-negative
     :check (lambda () (<= 0 (funcall (splice:new 'shipping-cost) 1)))))
  (splice:find-patch-set 'flat-rate-shipping))

(defun run-shipping-tasks (limit)
  (loop for id from 1 to limit
        do (splice:with-task (:id id)
             (shipping-cost (mod id 5)))))

(test a-declared-set-ramps-and-promotes
  (let ((ps (declare-flat-rate-shipping)))
    (unwind-protect
         (progn
           (splice:install 'flat-rate-shipping)
           (run-shipping-tasks 2000)
           (is (eq :promoted (splice:wait-for-state ps '(:promoted))))
           (is (search '(:canary-50 :canary-100 :promoting :swapping :promoted)
                       (state-trail ps))
               "trail was ~s" (state-trail ps))
           (is (= 5 (shipping-cost 1))))
      (retire ps))))

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

(test unfreezing-a-set-that-is-not-frozen-is-refused
  (with-installed-set (ps (healthy-probe-set 'unfreeze-unfrozen))
    (signals splice:illegal-transition (splice:unfreeze ps :resume :operator "unit-tests"))
    (is (eq :canary-50 (splice:patch-set-state ps)))))

(test an-unknown-unfreeze-decision-leaves-the-set-frozen
  (with-installed-set (ps (healthy-probe-set 'unfreeze-bad-decision))
    (splice:freeze ps "operator hold" :operator "unit-tests")
    (signals splice:illegal-transition (splice:unfreeze ps :sideways :operator "unit-tests"))
    (is (eq :frozen (splice:patch-set-state ps)))
    (is-true (splice::patch-set-freeze-reason ps))))

;;; ---------------------------------------------------------------------
;;; A task that fails before its body runs

(defun run-sampled-task ()
  "Run one probe task whose id is sampled, so it writes a :task-sample entry"
  (splice:with-task (:id splice::*task-sample-every*)
    (funcall 'lifecycle-probe 1)))

(test a-refused-sample-audit-releases-its-pins
  "A sampled task whose audit write is refused leaves no pin counted and
reports no observation"
  (with-temp-log-path (path)
    (let ((log (splice:open-audit-log path)))
      (with-installed-set (ps (healthy-probe-set 'refused-sample))
        ;; a closed checkpoint fails the next write and latches the log
        (close (splice::audit-log-checkpoint log))
        (is (typep (escaped-error #'run-sampled-task) 'error))
        (is (= 0 (splice::patch-set-pinned-new ps)))
        (is (= 0 (splice::patch-set-pinned-old ps)))
        (is (= 0 (splice::canary-stage-observations (splice::patch-set-stage ps))))
        (is (= 0 (splice::control-ring-count (splice::patch-set-control-ring ps))))
        ;; retiring audits; with the latched log closed, those entries go unlogged
        (splice:close-audit-log)))))

;;; ---------------------------------------------------------------------
;;; What a task's latency counts

(defun old-routed-task-id (ps)
  "First task id that draws :old on PS at every stage below 100"
  (loop for id from 1
        when (= 99 (splice::routing-draw id (splice:patch-set-name ps)))
          return id))

(defun last-control-latency (ps)
  "The latency of PS's most recent control observation"
  (let ((ring (splice::patch-set-control-ring ps)))
    (aref (splice::control-ring-latencies ring)
          (mod (1- (splice::control-ring-head ring))
               (splice::control-ring-size ring)))))

(defun hold-set-lock-after (ps signal held seconds)
  "Start a thread that waits on SIGNAL, takes PS's lock, signals HELD and
keeps the lock for SECONDS. Returns the thread"
  (sb-thread:make-thread
   (lambda ()
     (sb-thread:wait-on-semaphore signal)
     (splice::with-set-lock (ps)
       (sb-thread:signal-semaphore held)
       (sleep seconds)))))

(test a-task-latency-leaves-out-the-wait-to-release
  "A task whose pins wait on the set lock reports only its body's time"
  (with-installed-set (ps (healthy-probe-set 'lock-wait))
    (let* ((body-done (sb-thread:make-semaphore))
           (lock-held (sb-thread:make-semaphore))
           (holder (hold-set-lock-after ps body-done lock-held 0.2)))
      (splice:with-task (:id (old-routed-task-id ps))
        (sb-thread:signal-semaphore body-done)
        (sb-thread:wait-on-semaphore lock-held))
      (sb-thread:join-thread holder)
      (is (< (last-control-latency ps) 100)))))
