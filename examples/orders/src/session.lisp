;;;; session.lisp: the session driver. Runs the flagship patch set through
;;;; one canary lifecycle under synthetic load and collects the evidence:
;;;; detection, and rollback exactness.

(in-package #:splice-orders)

;;; ---------------------------------------------------------------------
;;; Globals and the structs they hold

(defparameter *worker-prefix* "orders-worker-"
  "Name prefix of RUN-CANARY-SESSION's worker threads.")

(defparameter *thread-prefixes* (list *worker-prefix* "orders-straggler")
  "Every thread-name prefix the example uses, so a viewer can tell its
threads from the rest. orders-straggler is reserved for a held :old task.")

(defstruct pacer
  (pace nil :read-only t)
  (lock (sb-thread:make-mutex :name "orders-pace") :read-only t)
  ;; mutable
  (last-paced nil)
  (paused-at :none))

(defstruct live-session
  (patch-set nil :read-only t)
  (orders nil :read-only t)
  (seed nil :read-only t)
  (fault nil :read-only t)
  (threads nil :read-only t)
  (started nil :read-only t)
  (audit-start-seq nil :read-only t)
  (pacer nil :read-only t)
  (max-tasks nil :read-only t)       ; the cap on tasks the session runs
  (touch-every nil :read-only t))    ; every this many tasks touches a pre-existing order

(defvar *live-session* nil
  "The session RUN-CANARY-SESSION is running or last ran (for other threasd)
NIL from the start of a session until its install succeeds")

(defstruct session-result
  (final-state nil :read-only t)
  (transitions nil :read-only t)
  (tasks-run nil :read-only t)
  (veto-p nil :read-only t)
  (detection-observations nil :read-only t)
  (reversal-report nil :read-only t)
  (pre-existing-snapshot nil :read-only t)
  (post-rollback-comparison nil :read-only t)
  (wallclock-ms nil :read-only t))

;;; ---------------------------------------------------------------------
;;; Hooks for observers
;;; Live session, pacing, held :old task.

(defun publish-session (&rest initargs)
  "Make a LIVE-SESSION from INITARGS and publish it to every thread"
  (setf *live-session* (apply #'make-live-session initargs)))

(defun await-pace (pacer ps)
  "Hold this worker while the presenter holds a new stage.
Returns :passed or :paced"
  (cond ((null (pacer-pace pacer)) :passed)
        ((eql (splice::patch-set-stage-index ps) (pacer-last-paced pacer)) :passed)
        (t (sb-thread:with-mutex ((pacer-lock pacer))
             (pace-stage pacer (splice::patch-set-stage-index ps))))))

(defun pace-stage (pacer stage)
  "Pace STAGE unless another work already did this while this one waited"
  (if (eql stage (pacer-last-paced pacer))
      :passed
      (progn (setf (pacer-paused-at pacer) stage)
             (unwind-protect (funcall (pacer-pace pacer) stage)
               (setf (pacer-paused-at pacer) :none))
             (setf (pacer-last-paced pacer) stage)
             :paced)))

(defun live-session-paused-at (session)
  "Stage index SESSION's presenter is holding or :NONE"
  (pacer-paused-at (live-session-pacer session)))

(defun old-pinned-task-id (set-name &key (from 1000000))
  "First task id from FROM whose routing draws pins :old at every stage below 100"
  (loop for id from from
        when (= 99 (splice::routing-draw id set-name))
          return id))

(defun start-held-task (ps hold)
  "Start a task pinned :old on PS that calls HOLD. It blocks before it does
its work. PS must be in the canary stage below 100. Returns the thread"
  (let ((id (old-pinned-task-id (splice:patch-set-name ps))))
    (sb-thread:make-thread
     (lambda ()
       (splice:with-task (:id id :swallow-errors t)
         (funcall hold)
         (process-order (make-test-order))))
     :name "orders-straggler")))

;;; ---------------------------------------------------------------------
;;; Session driver

(defun reset-workload ()
  "Restore the pristine pre-patch world so every session starts identical."
  (loop for (name fn) on *pristine-fns* by #'cddr
        do (setf (fdefinition name) fn))
  ;; restore the original class shape captured at load time
  (destructuring-bind (slots supers) *pristine-order-shape*
    (splice::apply-class-shape 'order slots supers))
  ;; restore the original print-total method if a promoted shim replaced it
  (splice::eval-method-redefinition
   '(defmethod print-total ((order order) (stream stream))
     (format stream "$~,2f" (order-float-total order))))
  (splice:unregister-patch-set 'currency-migration)
  (clrhash splice::*migration-registry*)
  (clrhash splice::*tracked-classes*)
  (sb-thread:with-mutex (splice::*migration-lock*)
    (clrhash splice::*migration-journal*)
    (clrhash splice::*canary-population*))
  (values))

(defun snapshot-order (order)
  (list :id (order-id order)
        :float-total (order-float-total order)
        :status (order-status order)
        :discount-code (order-discount-code order)))

(defun random-discount-code (rng)
  "\"TEN\", \"VIP\" or NIL, drawn from RNG"
  (case (mod (rng-next rng) 5)
    (0 "TEN")
    (1 "VIP")
    (t nil)))

(defun random-order (rng id)
  "A fresh order with ID, its count, price and discount code drawn from RNG"
  (make-instance 'order
                 :id id
                 :item-count (rng-range rng 1 9)
                 :unit-price (/ (rng-range rng 100 9999) 100.0)
                 :discount-code (random-discount-code rng)))

(defun priced-order (rng id)
  "A random order with ID, priced the pre-patch way"
  (let ((order (random-order rng id)))
    (price-order order)
    order))

(defun corrupt-order (order)
  "Mark ORDER corrupted, so forward migration fails on it under :migration"
  (setf (order-float-total order) -5.0
        (order-status order) :corrupted))

(defun make-pre-existing-orders (rng count &key corrupted)
  "Orders that predate the patch, for migration to move and rollback to
restore. CORRUPTED orders fail forward migration under :migration."
  (let ((orders (loop for i from 1 to count
                      collect (priced-order rng i))))
    (dotimes (i (or corrupted 0))
      (corrupt-order (nth (* 3 i) orders)))
    orders))

(defun budgeted-task-cap (ramp &key alpha beta min-effect)
  "Tasks a healthy session needs to pass every stage of RAMP, with half
again for slack."
  (ceiling (* 3/2 (reduce #'+ ramp
                          :key (lambda (fraction)
                                 (/ (splice:stage-budget fraction :alpha alpha :beta beta
                                                                  :min-effect min-effect)
                                    (/ fraction 100)))))))

(defun run-canary-session (&key (fault nil) (seed 42) (max-tasks :budgeted)
                             (ramp '(5 25 100)) (alpha 0.01d0) (beta 0.05d0)
                             (min-effect 0.3d0) (stage-limit 40000)
                             (pre-existing 40) (threads 1)
                             (touch-pre-existing-every 11)
                             paired-fallback quiet
                             pace (settle-timeout 30))
  "Run one patch lifecycle under synthetic load; return a SESSION-RESULT.
Expects an open audit log. PACE, when given, is called with each stage index
and blocks until that stage may run. SETTLE-TIMEOUT is how long to wait for a
terminal state once the workers stop. MAX-TASKS :BUDGETED sizes the cap
from the stage budgets with BUDGETED-TASK-CAP."
  ;; withdraw the last session before the workload it describes is reset
  (setf *live-session* nil)
  (reset-workload)
  (let* ((rng (make-rng seed))
         (*fault-rng* (make-rng (+ seed 7)))
         (*fault* (when fault (make-fault :kind fault)))
         (orders (make-pre-existing-orders
                  rng pre-existing
                  :corrupted (when (eq fault :migration) 3)))
         (pre-snapshot (mapcar #'snapshot-order orders))
         (start (get-internal-real-time))
         (audit-start-seq (current-audit-seq))
         (ps (register-currency-patch-set
              :ramp ramp :alpha alpha :beta beta
              :min-effect min-effect :stage-limit stage-limit
              :paired-fallback paired-fallback)))
    (handler-case (splice:install ps)
      (splice:patch-vetoed (e)
        (return-from run-canary-session (vetoed-result e))))
    (let* ((session (publish-session
                     :patch-set ps :orders orders :seed seed :fault fault
                     :threads threads :started (get-internal-real-time)
                     :audit-start-seq audit-start-seq :pacer (make-pacer :pace pace)
                     :max-tasks (session-task-cap max-tasks ramp alpha beta min-effect)
                     :touch-every touch-pre-existing-every))
           (tasks-run (run-session-load session rng)))
      (splice:wait-for-state ps '(:promoted :rolled-back :frozen) :timeout settle-timeout)
      (let ((result (collect-session-result session tasks-run pre-snapshot start)))
        (unless quiet
          (print-session-line fault seed result))
        result))))

(defun current-audit-seq ()
  "The open audit log's sequence number, or 0 with no log open"
  (if splice:*audit-log*
      (splice::audit-log-seq splice:*audit-log*)
      0))

(defun session-task-cap (max-tasks ramp alpha beta min-effect)
  "MAX-TASKS, or the cap BUDGETED-TASK-CAP gives RAMP when it is :BUDGETED"
  (if (eq max-tasks :budgeted)
      (budgeted-task-cap ramp :alpha alpha :beta beta :min-effect min-effect)
      max-tasks))

(defun vetoed-result (patch-vetoed)
  "The SESSION-RESULT for a session whose install was vetoed"
  (make-session-result :final-state :vetoed :veto-p t
                       :transitions (princ-to-string patch-vetoed)))

;;; ---------------------------------------------------------------------
;;; Session load
;;; The tasks a session runs, on this thread or on worker threads.

(defun session-decided-p (session)
  "True once SESSION's patch set has a verdict, so load can stop and
completion isn't mutex-starved"
  (member (splice:patch-set-state (live-session-patch-set session))
          '(:promoted :rolled-back :frozen :vetoed
            :promoting :swapping :rolling-back :restoring)))

(defun session-order (session i rng)
  "The order task I of SESSION processes: a pre-existing one every
touch-every tasks, to drive forward migration, otherwise a fresh one"
  (let ((orders (live-session-orders session)))
    (if (zerop (mod i (live-session-touch-every session)))
        (nth (mod (rng-next rng) (length orders)) orders)
        (random-order rng (+ 1000 i)))))

(defun run-session-task (session i rng)
  "Run task I of SESSION once the presenter lets its stage run"
  (await-pace (live-session-pacer session) (live-session-patch-set session))
  ;; think time keeps load tracking the ramp when canary is slow
  (when (> (live-session-threads session) 1)
    (sleep 0.0002))
  (when (fault-active-p :load-correlated)
    (fault-window-note *fault* :total))
  (splice:with-task (:id i :swallow-errors t)
    (process-order (session-order session i rng))))

(defun run-session-load (session rng)
  "Run SESSION's tasks until its patch set has a verdict or the task cap is
reached. Returns the number of tasks run"
  (let ((tasks-run (list 0)))
    (if (> (live-session-threads session) 1)
        (run-threaded-load session tasks-run)
        (run-serial-load session rng tasks-run))
    (car tasks-run)))

(defun run-serial-load (session rng tasks-run)
  "Run SESSION's tasks on this thread, counting them in TASKS-RUN"
  (loop for i from 1 to (live-session-max-tasks session)
        until (session-decided-p session)
        do (run-session-task session i rng)
           (setf (car tasks-run) i)))

(defun run-threaded-load (session tasks-run)
  "Run SESSION's tasks on its worker threads and wait for them all"
  (let ((stop (list nil)))
    (mapc #'sb-thread:join-thread
          (loop for w from 0 below (live-session-threads session)
                collect (start-session-worker session w tasks-run stop)))))

(defun start-session-worker (session w tasks-run stop)
  "Start worker W of SESSION. Returns the thread"
  ;; threads don't inherit dynamic bindings: rebind the shared
  ;; fault and give each worker its own PRNG
  (let ((fault *fault*)
        (rng (make-rng (+ (live-session-seed session) 100 w))))
    (sb-thread:make-thread
     (lambda ()
       (let ((*fault* fault)
             (*fault-rng* rng))
         (work-session-tasks session rng tasks-run stop)))
     :name (format nil "~a~a" *worker-prefix* w))))

(defun work-session-tasks (session rng tasks-run stop)
  "Take task numbers from TASKS-RUN and run them until STOP is set or the
cap is passed. The worker that sees a verdict sets STOP"
  (loop for i = (sb-ext:atomic-incf (car tasks-run))
        until (or (car stop) (> i (live-session-max-tasks session)))
        do (run-session-task session i rng)
           (when (session-decided-p session)
             (setf (car stop) t))))

;;; ---------------------------------------------------------------------
;;; Session result

(defun collect-session-result (session tasks-run pre-snapshot start)
  "The SESSION-RESULT for SESSION once its patch set has settled. START is
when the session began, in internal real time"
  (let ((ps (live-session-patch-set session)))
    (make-session-result
     :final-state (splice:patch-set-state ps)
     :transitions (splice:patch-set-lifecycle-history ps)
     :tasks-run tasks-run
     :detection-observations (detection-observations-from-audit
                              (live-session-audit-start-seq session))
     :reversal-report (splice:reverse-migration-report 'currency-migration)
     :pre-existing-snapshot pre-snapshot
     :post-rollback-comparison (rollback-comparison session pre-snapshot)
     :wallclock-ms (elapsed-ms start))))

(defun rollback-comparison (session pre-snapshot)
  "How SESSION's orders compare with PRE-SNAPSHOT after a rollback, or NIL"
  (let ((ps (live-session-patch-set session)))
    (when (eq (splice:patch-set-state ps) :rolled-back)
      (compare-rollback-exactness (live-session-orders session) pre-snapshot ps))))

(defun elapsed-ms (start)
  "Milliseconds since START, in internal real time"
  (round (* 1000 (- (get-internal-real-time) start))
         internal-time-units-per-second))

(defun print-session-line (fault seed result)
  "Print RESULT's one-line summary for a session with FAULT and SEED"
  (format t "~&  [~a seed=~a] ~a after ~a tasks (~ams)~a~%"
          (or fault :clean) seed (session-result-final-state result)
          (session-result-tasks-run result)
          (session-result-wallclock-ms result)
          (detection-note result)))

(defun detection-note (result)
  "\" detection-n=N\" when RESULT has a detection count, otherwise \"\""
  (let ((n (session-result-detection-observations result)))
    (if (integerp n)
        (format nil " detection-n=~a" n)
        "")))

;;; ---------------------------------------------------------------------
;;; Evidence

(defun detection-observations-from-audit (&optional (after-seq 0))
  "SPRT sample count at the rollback decision, read from audit log entries
after AFTER-SEQ. Returns the count, :NO-LOG or :NO-SPRT-REJECT"
  (if splice:*audit-log*
      (let ((*package* (find-package :splice)))
        (loop for line in (copy-audit-lines splice:*audit-log*)
              for entry = (ignore-errors (read-from-string line))
              when (and entry (<= (getf entry :seq 0) after-seq))
                do (return :no-sprt-reject) ; lines are newest-first; past the session
              when (and entry (eq (getf entry :event) :rollback-decision))
                do (let ((trigger (getf entry :trigger)))
                     (when (and (consp trigger) (eq (first trigger) :sprt-reject))
                       (return (getf (second trigger) :n))))
              finally (return :no-sprt-reject)))
      :no-log))

(defun copy-audit-lines (log)
  "LOG's in-memory lines, newest first, copied under its lock because AUDIT trims them in place"
  (sb-thread:with-mutex ((splice::audit-log-lock log))
    (copy-list (splice::audit-log-lines log))))

(defun compare-rollback-exactness (orders pre-snapshot ps)
  "Check rollback exactness: fdefinitions EQ the originals, the class shape
is original, and pre-existing orders match their pre-patch snapshot."
  (let ((fn-ok (every (lambda (fp)
                        (eq (fdefinition (splice::fn-patch-name fp))
                            (splice::fn-patch-old-fn fp)))
                      (splice::patch-set-fn-patches ps)))
        (shape-ok (null (set-exclusive-or
                         '(id item-count unit-price discount-code
                           float-total status)
                         (mapcar #'sb-mop:slot-definition-name
                                 (sb-mop:class-direct-slots
                                  (find-class 'order))))))
        (restored (loop for o in orders
                        for snap in pre-snapshot
                        count (and (equal (order-float-total o)
                                          (getf snap :float-total))
                                   (equal (order-status o)
                                          (getf snap :status))))))
    (list :fdefinitions-eq fn-ok
          :class-shape-original shape-ok
          :snapshot-restored restored
          :snapshot-total (length orders))))

;;; ---------------------------------------------------------------------
;;; Baseline workload

(defun run-workload (&key (tasks 500) (seed 1))
  "Plain workload with no patch in flight (baseline / overhead measurement)."
  (let ((rng (make-rng seed)))
    (loop for i from 1 to tasks
          do (splice:with-task (:id i :swallow-errors t)
               (process-order (make-instance 'order
                                             :id i :item-count (rng-range rng 1 9)
                                             :unit-price (/ (rng-range rng 100 9999) 100.0)
                                             :discount-code (case (mod (rng-next rng) 5)
                                                              (0 "TEN") (1 "VIP") (t nil))))))))
