;;;; decisions.lisp: the operator restarts at canary decision points, on
;;;; live sets. The test thread is the worker that gets asked, and a
;;;; HANDLER-BIND around DRIVE-TASKS plays the operator.

(in-package #:splice-tests)

(def-suite live-decisions :in integration)
(in-suite live-decisions)

(defun choosing (restart seen)
  "Handler that pushes the decision onto (car SEEN) and invokes RESTART."
  (lambda (c)
    (push c (car seen))
    (funcall restart c)))

(defun canary-ended-p (ps)
  (lambda () (not (splice::canary-stage-p (splice:patch-set-state ps)))))

(defun timeout-probe-set (name)
  "Healthy set whose first outcome times the stage out."
  (let ((ps (healthy-probe-set name)))
    (setf (splice::patch-set-sprt-min-n ps) 1
          (splice::patch-set-sprt-max-n ps) 1)
    ps))

(test outside-the-macro-a-reject-is-settled-by-splice
  (with-installed-set (ps (failing-probe-set 'unasked-reject))
    (let ((asked (list '())))
      (handler-bind ((splice:operator-decision (lambda (c) (push c (car asked)))))
        (drive-tasks (canary-ended-p ps)))
      (is (null (car asked)))
      (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15)))
      (join-lifecycle-threads ps)
      (is (not (member :frozen (state-trail ps))) "trail was ~s" (state-trail ps)))))

(test a-held-reject-rolls-back-on-the-operator-s-word
  (with-audit-log (path)
    (with-installed-set (ps (failing-probe-set 'held-reject))
      (let ((seen (list '()))
            (while-asked nil))
        (splice:with-operator-decisions
          (handler-bind ((splice:operator-decision
                           (lambda (c)
                             (push c (car seen))
                             (setf while-asked
                                   (list (splice:patch-set-state ps)
                                         (first (splice::patch-set-freeze-reason ps))))
                             (splice:roll-back-patch c))))
            (drive-tasks (lambda () (car seen)))))
        (let ((decision (first (car seen))))
          (is (= 1 (length (car seen))))
          (is (eq :sprt-reject (splice:operator-decision-point decision)))
          (is (eq :roll-back (splice:operator-decision-default decision)))
          (is (search "is held at an SPRT reject; splice would roll back"
                      (princ-to-string decision))))
        (is (equal '(:frozen :awaiting-operator) while-asked))
        (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15)))
        (join-lifecycle-threads ps)
        (is (search '(:canary-100 :frozen :rolling-back) (state-trail ps))
            "trail was ~s" (state-trail ps))
        (let ((decided (find :rollback-decision (log-entries path)
                             :key (lambda (entry) (getf entry :event)))))
          (is (equal '(:operator "debugger" :point :sprt-reject)
                     (getf decided :trigger))))))))

(test promote-anyway-overrules-a-reject
  (let ((original (fdefinition 'lifecycle-probe)))
    (unwind-protect
         (with-installed-set (ps (failing-probe-set 'promote-over-reject))
           (splice:with-operator-decisions
             (handler-bind ((splice:operator-decision #'splice:promote-anyway))
               (drive-tasks (canary-ended-p ps))))
           (is (eq :promoted (splice:wait-for-state ps '(:promoted) :timeout 15)))
           (join-lifecycle-threads ps)
           (is (search '(:canary-100 :frozen :promoting :swapping :promoted)
                       (state-trail ps))
               "trail was ~s" (state-trail ps)))
      (setf (fdefinition 'lifecycle-probe) original))))

(test let-splice-decide-advances-a-held-accept
  (with-installed-set (ps (healthy-probe-set 'held-accept))
    (let ((seen (list '())))
      (splice:with-operator-decisions
        (handler-bind ((splice:operator-decision (choosing #'splice:let-splice-decide seen)))
          (drive-tasks (lambda () (car seen)))))
      (is (eq :sprt-accept (splice:operator-decision-point (first (car seen)))))
      (is (eq :advance (splice:operator-decision-default (first (car seen)))))
      (is (eq :canary-100 (splice:patch-set-state ps)))
      (is (search '(:canary-50 :frozen :canary-100) (state-trail ps))
          "trail was ~s" (state-trail ps)))))

(test freeze-patch-keeps-a-timed-out-stage-frozen
  (with-installed-set (ps (timeout-probe-set 'held-timeout))
    (let ((seen (list '())))
      (splice:with-operator-decisions
        (handler-bind ((splice:operator-decision (choosing #'splice:freeze-patch seen)))
          (drive-tasks (lambda () (car seen)))))
      (let ((reason (splice::patch-set-freeze-reason ps)))
        (is (eq :stage-timeout (splice:operator-decision-point (first (car seen)))))
        (is (eq :frozen (splice:patch-set-state ps)))
        (is (eq :operator (first reason)))
        (is (eq :stage-timeout (first (getf reason :reason)))))
      (is (= 1 (count :frozen (state-trail ps))) "trail was ~s" (state-trail ps)))))

(test two-workers-at-one-verdict-make-one-decision
  (with-installed-set (ps (failing-probe-set 'two-workers))
    (let* ((lock (sb-thread:make-mutex :name "decision count"))
           (seen '())
           (workers
             (loop for w below 2
                   collect (let ((first-id (* 100000 (1+ w))))
                             (sb-thread:make-thread
                              (lambda ()
                                (splice:with-operator-decisions
                                  (handler-bind ((splice:operator-decision
                                                   (lambda (c)
                                                     (sb-thread:with-mutex (lock)
                                                       (push c seen))
                                                     (sleep 0.2)
                                                     (splice:roll-back-patch c))))
                                    (loop for id from first-id below (+ first-id 500)
                                          while (splice::canary-stage-p (splice:patch-set-state ps))
                                          do (splice:with-task (:id id :swallow-errors t)
                                               (funcall 'lifecycle-probe id))))))
                              :name (format nil "decision-worker-~d" w))))))
      (mapc #'sb-thread:join-thread workers)
      (is (= 1 (length seen)))
      (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15)))
      (join-lifecycle-threads ps)
      (is (= 1 (count :rolling-back (state-trail ps))) "trail was ~s" (state-trail ps)))))

(test the-set-lock-is-free-while-the-operator-thinks
  (with-installed-set (ps (failing-probe-set 'lock-free-ask))
    (let ((checks '()))
      (splice:with-operator-decisions
        (handler-bind ((splice:operator-decision
                         (lambda (c)
                           (push (sb-thread:holding-mutex-p (splice::patch-set-lock ps))
                                 checks)
                           (let ((other (sb-thread:make-thread
                                         (lambda ()
                                           (splice::with-set-lock (ps) :took-it)))))
                             (push (sb-thread:join-thread other :default :timed-out
                                                                :timeout 5)
                                   checks))
                           (splice:roll-back-patch c))))
          (drive-tasks (canary-ended-p ps))))
      (is (equal '(:took-it nil) checks)))))

(test a-choice-after-someone-else-moved-the-set-is-abandoned
  (with-audit-log (path)
    (with-installed-set (ps (failing-probe-set 'abandoned-choice))
      (splice:with-operator-decisions
        (handler-bind ((splice:operator-decision
                         (lambda (c)
                           (splice:unfreeze ps :rollback :operator "unit-tests")
                           (splice:promote-anyway c))))
          (drive-tasks (canary-ended-p ps))))
      (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15)))
      (join-lifecycle-threads ps)
      (is (not (member :promoting (state-trail ps))) "trail was ~s" (state-trail ps))
      (is (find :decision-abandoned (log-entries path)
                :key (lambda (entry) (getf entry :event)))))))

(test with-no-handler-the-debugger-is-entered
  (with-installed-set (ps (failing-probe-set 'debugger-entered))
    (let* ((entered '())
           (hook (lambda (c hook)
                   (declare (ignore hook))
                   (push c entered)
                   (splice:let-splice-decide c))))
      (let ((sb-ext:*invoke-debugger-hook* hook)
            (*debugger-hook* hook))
        (splice:with-operator-decisions
          (drive-tasks (canary-ended-p ps))))
      (is (= 1 (length entered)))
      (is (typep (first entered) 'splice:operator-decision))
      (is (eq :rolled-back (splice:wait-for-state ps '(:rolled-back) :timeout 15))))))
