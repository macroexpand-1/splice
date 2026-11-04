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
      (uiop:delete-file-if-exists path))))

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

(defun transition-states (result)
  (mapcar #'car (orders:session-result-transitions result)))

(defun entries-of (path event)
  (remove-if-not (lambda (entry) (eq (getf entry :event) event))
                 (log-entries path)))

(test hooks-change-no-outcome
  "A pace that never waits and :SPRT-STEP events leave the lifecycle alone."
  (with-shared-log (path)
    (declare (ignore path))
    (let ((plain (orders:run-canary-session :seed 1001 :quiet t))
          (hooked (with-global (splice::*audit-sprt-steps* t)
                    (orders:run-canary-session
                     :seed 1001 :quiet t
                     :pace (lambda (stage) (declare (ignore stage)))))))
      (is (eq :promoted (orders:session-result-final-state plain)))
      (is (equal (transition-states plain) (transition-states hooked))))))

(test one-pace-per-stage
  (with-shared-log (path)
    (declare (ignore path))
    (let ((paced '()))
      (orders:run-canary-session
       :seed 1001 :threads 3 :quiet t
       :pace (lambda (stage) (push stage paced)))
      (is (equal '(0 1 2) (reverse paced))))))

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

(defun held-task-pace (gate)
  "A pace that starts the held task at stage 1 and never waits itself."
  (lambda (stage)
    (when (= stage 1)
      (orders:start-held-task
       (orders:live-session-patch-set orders:*live-session*)
       (lambda () (sb-thread:wait-on-semaphore gate))))))

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
                                 (entries-of path :sprt-step))))))
        (is (eql (getf verdict :n) (car (getf step :errors))))
        (is (< (abs (- (getf verdict :llr) (cdr (getf step :errors)))) 1e-3))))))

(test a-drain-timeout-freezes-promotion
  (with-shared-log (path)
    (declare (ignore path))
    (with-global (splice::*drain-timeout-seconds* 1)
      (let ((gate (sb-thread:make-semaphore)))
        (unwind-protect
             (is (eq :frozen (orders:session-result-final-state
                              (orders:run-canary-session
                               :seed 1001 :threads 3 :quiet t
                               :pace (held-task-pace gate)))))
          (sb-thread:signal-semaphore gate))))))
