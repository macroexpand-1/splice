;;;; router.lisp: per-task epoch pinning
;;;; A task pins :old or :new per active patch set at entry and keeps it, so
;;;; it never sees a mixture of old and new from one set.

(in-package #:splice)

(defvar *task-id* nil "Identity of the current task or NIL.")
(defvar *task-epochs* nil
  "List of (patch-set route) pins made at task entry.")
(defvar *task-anomaly-noted* nil
  "Alist (patch-set . :noted or :fell-back) of sets whose anomaly this task
already recorded, so an error unwinding through nested shims counts once.
:FELL-BACK means the set's new code failed and old code answered instead.")
(defvar *task-counter-cell* (list 0)
  "Task ids handed out so far. A cons for ATOMIC-INCF.")
(defvar *task-sample-every* 50
  "Log every Nth task's pinned routes to the audit log.")
(defconstant +clock-monotonic-raw+ 4
  "CLOCK_MONOTONIC_RAW's id on Darwin and Linux alike. SB-UNIX names only
CLOCK_MONOTONIC, which ticks in whole microseconds on Darwin")

(defun next-task-id ()
  (1+ (sb-ext:atomic-incf (car *task-counter-cell*))))

(defun routing-draw (task-id set-name)
  "Deterministic draw in [0,100) per (task, set). SHA-256 rather than SXHASH
so it reproduces across images and from the audit log."
  (mod (parse-integer
        (subseq (sha256-hex (format nil "~a|~a" task-id set-name)) 0 8)
        :radix 16)
       100))

(defun draw-route (task-id set-name fraction)
  "Route a canary stage at FRACTION gives TASK-ID: :new when its draw falls
under FRACTION, :old otherwise. Pure, so the audit log can be checked
against it offline."
  (if (< (routing-draw task-id set-name) fraction)
      :new
      :old))

(defun pin-route (ps task-id)
  "Route for a fresh task. Canarying sets draw against the ramp fraction,
a promoting set pins :new, and anything else pins :old."
  (case (patch-set-state ps)
    ((:promoting :swapping) :new)
    (t (if (canary-stage-p (patch-set-state ps))
           (draw-route task-id (patch-set-name ps) (patch-set-current-fraction ps))
           :old))))

(defun pin-and-count (ps task-id)
  "Pin PS for a fresh task and count it in flight, all as one step."
  (with-set-lock (ps)
    (let ((route (pin-route ps task-id)))
      (if (eq route :new)
          (incf (patch-set-pinned-new ps))
          (incf (patch-set-pinned-old ps)))
      (list ps route))))

(declaim (inline task-route-for))
(defun task-route-for (ps)
  "The current task's pinned route for PS, or :old outside a task.
Asked for Inline since every shim call asks it"
  (let ((pin (assoc ps *task-epochs* :test #'eq)))
    (if pin (cadr pin) :old)))

(defun current-route (set-name)
  (task-route-for (resolve-patch-set set-name)))

(defun note-anomaly (ps condition)
  "Record an error from :new-routed code, once per task per set. Storage
conditions and migration failures arm the hard trigger. It audits and arms
before it signals CANARY-ANOMALY, so a handler that unwinds loses neither."
  (let ((first-time (not (assoc ps *task-anomaly-noted* :test #'eq))))
    (when first-time
      (push (cons ps :noted) *task-anomaly-noted*)
      (audit-anomaly ps condition))
    (arm-for-condition ps condition)
    (when first-time
      (signal 'canary-anomaly :patch-set ps :task *task-id* :cause condition))))

(defun audit-anomaly (ps condition)
  (audit :canary-anomaly
         :patch-set (patch-set-name ps) :task *task-id*
         :cause (princ-to-string condition)
         :cause-type (string (type-of condition))))

(defun arm-for-condition (ps condition)
  "Arm PS's hard trigger when CONDITION is a storage condition or a migration
failure; leave it alone otherwise"
  (when (or (typep condition 'storage-condition)
            (typep condition 'migration-failure))
    (arm-hard-trigger ps (list (if (typep condition 'storage-condition)
                                   :storage-condition
                                   :migration-failure)
                               (princ-to-string condition)))))

(defun note-fallback (ps)
  "Mark PS as fallen back for the task. NOTE-ANOMALY has already recorded the error
so the entry exists"
  (setf (cdr (assoc ps *task-anomaly-noted* :test #'eq)) :fell-back))

(defun fell-back-p (ps)
  "True when this task's new code for PS failed and old code answered"
  (eq :fell-back (cdr (assoc ps *task-anomaly-noted* :test #'eq))))

(defun pin-failed-p (pin outcome)
  "True when the task failed on PIN's route: it raise or its new code fell back
Fallback counts against :NEW only"
  (destructuring-bind (ps route) pin
    (or (eq outcome :failure)
        (and (eq route :new) (fell-back-p ps)))))

(defun monotonic-ns ()
  "Nanoseconds on the raw monotonic clock. GET-INTERNAL-REAL-TIME ticks in
microseconds, coarser than a fast task"
  (multiple-value-bind (seconds nanoseconds)
      (sb-unix:clock-gettime +clock-monotonic-raw+)
    (+ (* seconds 1000000000) nanoseconds)))

(defun elapsed-ms (start-ns)
  "Milliseconds since START-NS on the monotonic clock"
  (/ (- (monotonic-ns) start-ns) 1d6))

(defun audit-task-sample (task-id task-epochs)
  "Log TASK-ID's pins when it is a sampled task, enough to re-derive routing
offline. Returns :sampled or :skipped"
  (cond ((and task-epochs (integerp task-id)
              (zerop (mod task-id *task-sample-every*)))
         (audit :task-sample :task task-id
                             :pins (mapcar #'pin-sample task-epochs))
         :sampled)
        (t :skipped)))

(defun pin-sample (pin)
  "Plist describing PIN for a :task-sample entry"
  (destructuring-bind (ps route) pin
    (list :patch-set (patch-set-name ps)
          :route route
          :fraction (patch-set-current-fraction ps)
          :state (patch-set-state ps))))

(defun pin-active-sets (task-id)
  "Pin TASK-ID on every active canary set, adding each pin to *TASK-EPOCHS*
as it is taken, so a failure partway leaves only taken pins to release"
  (dolist (ps (active-canary-sets))
    (setf *task-epochs* (append *task-epochs* (list (pin-and-count ps task-id))))))

(defun call-with-task (id thunk &key (swallow-errors nil))
  "Run THUNK as one task: pin routes, count in-flight tasks, and report the
outcome to each pinned set. The FALLBACK-TO-OLD restart retries the whole task
on old code. A failure before THUNK runs releases the pins taken and reports
nothing."
  (let ((*task-id* (or id (next-task-id)))
        (*task-epochs* '())
        (*task-anomaly-noted* '())
        (outcome :not-run)
        (start 0))
    ;; open before pinning, so a failure while pinning or sampling releases
    ;; every pin taken so far
    (unwind-protect
         (progn
           (pin-active-sets *task-id*)
           ;; before the clock starts: the sample's log write is not the task's latency
           (audit-task-sample *task-id* *task-epochs*)
           (setf start (monotonic-ns)
                 outcome :success)
           (restart-case
               ;; record in whichever handler receives the error: a HANDLER-CASE
               ;; would unwind before an outer HANDLER-BIND could record it
               (if swallow-errors
                   (handler-case (funcall thunk)
                     (error () (setf outcome :failure) nil))
                   (handler-bind ((error (lambda (e)
                                           (declare (ignore e))
                                           (setf outcome :failure))))
                     (funcall thunk)))
             (fallback-to-old ()
               :report "Retry this task with every patch set routed to old code."
               (let ((*task-epochs* (mapcar (lambda (pin) (list (car pin) :old))
                                            *task-epochs*)))
                 (funcall thunk)))))
      ;; time the body alone: RELEASE-PINS waits on the set lock, which other
      ;; threads hold while they score their own tasks
      (let ((latency-ms (elapsed-ms start)))
        ;; release pins before reporting: a rollback would wait on these counts
        (release-pins *task-epochs*)
        (unless (eq outcome :not-run)
          (report-task-outcome *task-epochs* outcome latency-ms))))))

(defun release-pins (task-epochs)
  "Uncount each of TASK-EPOCHS' pins from its set's in-flight tasks"
  (dolist (pin task-epochs)
    (destructuring-bind (ps route) pin
      (with-set-lock (ps)
        (if (eq route :new)
            (decf (patch-set-pinned-new ps))
            (decf (patch-set-pinned-old ps)))))))

(defun report-task-outcome (task-epochs outcome latency-ms)
  "Report OUTCOME and LATENCY-MS to the set of each of TASK-EPOCHS' pins"
  (dolist (pin task-epochs)
    (report-outcome (car pin) (cadr pin) (pin-failed-p pin outcome) latency-ms)))

(defmacro with-task ((&key id (swallow-errors nil)) &body body)
  `(call-with-task ,id (lambda () ,@body) :swallow-errors ,swallow-errors))
