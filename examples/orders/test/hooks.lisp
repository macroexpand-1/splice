;;;; hooks.lisp: the observer hooks in the session driver and the :SPRT-STEP event.
;;;; Sessions here start worker and completion threads, which cannot see a
;;;; LET binding of *AUDIT-LOG*, so they use a global log instead.

(in-package #:splice-orders/tests)

(def-suite hooks :in splice-orders-tests)
(in-suite hooks)

(defun call-with-shared-log (fn)
  "Call FN with the path of a fresh audit log opened as the global
*AUDIT-LOG*; put the previous global log back after."
  (let ((previous splice:*audit-log*)
        (path (temp-log-path)))
    (splice:open-audit-log path)
    (unwind-protect (funcall fn path)
      (splice:close-audit-log)
      (setf splice:*audit-log* previous)
      (splice:delete-audit-log path))))

(defmacro with-shared-log ((path) &body body)
  "Run BODY with PATH bound to the log CALL-WITH-SHARED-LOG opens."
  `(call-with-shared-log (lambda (,path) ,@body)))

(defun call-with-global (symbol value fn)
  "Call FN with SYMBOL's global value set to VALUE, for threads to see; restore it after."
  (let ((old (symbol-value symbol)))
    (setf (symbol-value symbol) value)
    (unwind-protect (funcall fn)
      (setf (symbol-value symbol) old))))

(defmacro with-global ((symbol value) &body body)
  "Run BODY with SYMBOL's global value set to VALUE, like a LET that threads see.
SYMBOL is not evaluated."
  `(call-with-global ',symbol ,value (lambda () ,@body)))

(defun entries-of (path event)
  (remove-if-not (lambda (entry) (eq (getf entry :event) event))
                 (log-entries path)))

;;; A healthy session passes its 5% and 25% stages only most of the time:
;;; their latency tests compare wall-clock task times. Tests here whose claim
;;; needs a stage to pass report outcomes themselves, at one fixed latency,
;;; and tests whose claim needs a promotion have the operator promote.

(defun report-healthy-outcomes (ps pacer first-id)
  "Pace through PACER and report a healthy 1 ms outcome to PS for each id
from FIRST-ID until PS leaves its canary stages. Returns :left-canary, or
:cap-reached after a million ids"
  (loop for id from first-id below (+ first-id 1000000)
        unless (splice::canary-stage-p (splice:patch-set-state ps))
          return :left-canary
        do (orders::await-pace pacer ps)
           (splice:report-outcome ps (splice::pin-route ps id) nil 1d0)
        finally (return :cap-reached)))

(defun call-with-currency-set (fn)
  "Install a fresh currency set with a 3x smallest effect, so its budgets
are small, and call FN on it. Restores the pristine workload after"
  (orders:reset-workload)
  (unwind-protect
       (let ((ps (orders:register-currency-patch-set :min-effect 3d0)))
         (splice:install ps)
         (funcall fn ps))
    (orders:reset-workload)))

(test one-pace-per-stage
  "Three workers pace each stage once between them."
  (with-shared-log (path)
    (declare (ignore path))
    (call-with-currency-set
     (lambda (ps)
       (let* ((paced '())
              (pacer (orders::make-pacer :pace (lambda (stage) (push stage paced))))
              (workers (loop for w from 0 below 3
                             collect (let ((first-id (* 1000000 (1+ w))))
                                       (sb-thread:make-thread
                                        (lambda () (report-healthy-outcomes ps pacer first-id))
                                        :name "pace-worker")))))
         (is (every (lambda (outcome) (eq :left-canary outcome))
                    (mapcar #'sb-thread:join-thread workers)))
         (is (eq :promoted (splice:wait-for-state ps '(:promoted) :timeout 30)))
         (is (equal '(0 1 2) (reverse paced))))))))

(test the-session-stays-published-after-it-ends
  (with-shared-log (path)
    (declare (ignore path))
    (let ((seen '()))
      (orders:run-canary-session
       :seed 2002 :fault :latent :quiet t
       :pace (lambda (stage)
               (push (list stage
                           (orders:live-session-paused-at
                            orders:*live-session*))
                     seen)))
      (is (equal '((0 0)) seen))
      (is (eq :rolled-back
              (splice:patch-set-state (orders:live-session-patch-set
                                       orders:*live-session*)))))))

(defun await-old-pin (ps seconds)
  "Poll until PS counts an :old pin. Returns :pinned, or :never-pinned once
SECONDS pass"
  (loop with deadline = (+ (get-internal-real-time)
                           (* seconds internal-time-units-per-second))
        when (plusp (splice::patch-set-pinned-old ps))
          return :pinned
        when (> (get-internal-real-time) deadline)
          return :never-pinned
        do (sleep 0.01)))

(defun held-task-pace (gate)
  "A pace that, before the first stage runs a task, starts the held task,
waits for its :old pin and promotes. The promotion then waits on the held
task, whatever the stage tests would have said."
  (lambda (stage)
    (when (= stage 0)
      (let ((ps (orders:live-session-patch-set orders:*live-session*)))
        (orders:start-held-task ps (lambda () (sb-thread:wait-on-semaphore gate)))
        (when (eq :pinned (await-old-pin ps 10))
          (splice:promote ps :operator "hooks-tests"))))))

(defun await-live-session (timeout)
  "The published live session, waiting up to TIMEOUT seconds, or :NONE."
  (loop repeat (* 100 timeout)
        when orders:*live-session* return it
        do (sleep 0.01)
        finally (return :none)))

(defun session-thread (&rest args)
  (sb-thread:make-thread (lambda () (apply #'orders:run-canary-session args))
                         :name "test-session"))

(test the-held-task-delays-promotion
  (with-shared-log (path)
    (declare (ignore path))
    (with-global (splice::*drain-timeout-seconds* 60)
      (setf orders:*live-session* nil)
      (let* ((gate (sb-thread:make-semaphore))
             (thread (session-thread :seed 1001 :threads 3 :quiet t :settle-timeout 90
                                     :pace (held-task-pace gate)))
             (ps (orders:live-session-patch-set (await-live-session 10))))
        (is (eq :promoting (splice:wait-for-state ps '(:promoting) :timeout 60)))
        (sleep 1)
        (is (eq :promoting (splice:patch-set-state ps)))
        (is (= 1 (splice::patch-set-pinned-old ps)))
        (is (not (null orders:*live-session*)))
        (sb-thread:signal-semaphore gate)
        (is (eq :promoted (orders:session-result-final-state
                           (sb-thread:join-thread thread))))))))

(test steps-match-the-verdict
  (with-shared-log (path)
    (with-global (splice::*audit-sprt-steps* t)
      (orders:run-canary-session :seed 2002 :fault :latent :quiet t)
      (let* ((decision (first (entries-of path :rollback-decision)))
             (verdict (second (getf decision :trigger)))
             (step (first (last (remove-if-not
                                 (lambda (e) (< (getf e :seq) (getf decision :seq)))
                                 (entries-of path :sprt-step)))))
             ;; the step names the latency signal :slow
             (point (getf step (ecase (getf verdict :signal)
                                 (:errors :errors)
                                 (:latency :slow)))))
        (is (eql (getf verdict :n) (car point)))
        (is (< (abs (- (getf verdict :log-odds) (cdr point))) 1e-3))))))

(test a-drain-timeout-freezes-promotion
  (with-shared-log (path)
    (declare (ignore path))
    (with-global (splice::*drain-timeout-seconds* 1)
      (let ((gate (sb-thread:make-semaphore)))
        (unwind-protect
             (progn
               (is (eq :frozen (orders:session-result-final-state
                                (orders:run-canary-session
                                 :seed 1001 :threads 3 :quiet t
                                 :pace (held-task-pace gate)))))
               ;; frozen instead of swapping: every name still points at its shim
               (is (every-shim-installed-p
                    (orders:live-session-patch-set orders:*live-session*))))
          (sb-thread:signal-semaphore gate))))))

(defun every-shim-installed-p (ps)
  (every (lambda (fn-patch)
           (eq (fdefinition (splice::fn-patch-name fn-patch))
               (splice::fn-patch-shim fn-patch)))
         (splice::patch-set-fn-patches ps)))
