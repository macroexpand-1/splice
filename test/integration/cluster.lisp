;;;; cluster.lisp: one conductor and one member wired together in this
;;;; image over the test wire (unit/protocol.lisp). No socket, but the
;;;; member's set is live and tasks run against it.

(in-package #:splice-tests)

(def-suite live-cluster :in integration)
(in-suite live-cluster)

(defun drive-probe-task (cluster-member id)
  "Run one task over PROTOCOL-PROBE while CLUSTER-MEMBER's set canaries
sending its health every tenth task, otherwise wait a moment"
  (let ((ps (splice/cluster::member-patch-set cluster-member)))
    (if (and ps (splice::canary-stage-p (splice:patch-set-state ps)))
        (progn
          (splice:with-task (:id id :swallow-errors t)
            (funcall 'protocol-probe id))
          (when (zerop (mod id 10))
            (splice/cluster:member-send-health cluster-member)))
        (sleep 0.01))))

(test one-member-runs-in-process
  (let* ((wire (make-test-wire))
         (conductor (splice/cluster:make-conductor :adapter wire))
         (cluster-member (splice/cluster:make-member :adapter wire))
         (deadline (+ (get-internal-real-time)
                      (* 30 internal-time-units-per-second))))
    (unwind-protect
         (progn
           (splice/cluster:conductor-add-member conductor :m1)
           (splice/cluster:conductor-ship conductor (probe-spec))
           (loop for id from 1
                 until (or (member (splice/cluster:conductor-phase conductor)
                                   '(:done :aborted))
                           (> (get-internal-real-time) deadline))
                 do (let ((next (wire-take wire)))
                         (cond ((null next)
                                (drive-probe-task cluster-member id))
                               ((eq :member (car next))
                                (splice/cluster:member-receive cluster-member (cdr next)))
                               (t
                                (splice/cluster:conductor-receive conductor :m1 (cdr next))))))
           (is (eq :done (splice/cluster:conductor-phase conductor)))
           (is (equal '((:member :m1 :state :rolled-back :reversal nil))
                      (splice/cluster:conductor-finals conductor)))
           (is (every #'wire-value-p (test-wire-seen wire))
               "a message held something other than a wire value!"))
      (let ((ps (splice:find-patch-set 'protocol-probe-set)))
        (when ps (retire  ps))))))
