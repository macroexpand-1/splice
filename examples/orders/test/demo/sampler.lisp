;;;; sampler.lisp: the sampler's tests. Sessions here run with a sampler
;;;; polling every millisecond, a hundred times the stage rate.

(in-package #:splice-orders/demo-tests)

(def-suite demo-sampler :in demo)
(in-suite demo-sampler)

(defun collecting-sink ()
  "A sink that keeps every snapshot, and a function returning them oldest first."
  (let ((seen '())
        (lock (sb-thread:make-mutex :name "test-sink")))
    (values (lambda (snapshot) (sb-thread:with-mutex (lock) (push snapshot seen)))
            (lambda () (sb-thread:with-mutex (lock) (reverse seen))))))

(defun call-with-sampler (sinks fn)
  "Call FN while a sampler thread feeds SINKS every millisecond."
  (let* ((running (list t))
         (thread (sb-thread:make-thread
                  (lambda () (d:run-sampler sinks :period 0.001
                                                  :running (lambda () (car running))))
                  :name "test-sampler")))
    (unwind-protect (funcall fn)
      (setf (car running) nil)
      (sb-thread:join-thread thread :default :not-joined :timeout 5))))

(defmacro with-sampler ((sinks) &body body)
  "Run BODY inside CALL-WITH-SAMPLER, returning BODY's values."
  `(call-with-sampler ,sinks (lambda () ,@body)))

(defun forward-migrations (path)
  "How many forward migrations the log at PATH records."
  (let ((count 0))
    (splice::map-audit-entries
     path
     (lambda (entry)
       (when (and (eq (getf entry :event) :instance-migration)
                  (eq (getf entry :direction) :forward))
         (incf count)))
     :verify nil)
    count))

(defun untouched-session ()
  "A seed 1001 session whose tasks never touch a pre-existing order."
  (orders:run-canary-session :seed 1001 :quiet t
                        :touch-pre-existing-every most-positive-fixnum))

(defun all-pending-p (snapshot)
  (every (lambda (state) (eq state :pending)) (getf snapshot :orders)))

(defun touching-sink (snapshot)
  "A deliberately broken sink: it reads a slot of the first order."
  (declare (ignore snapshot))
  (let ((session orders:*live-session*))
    (when session
      (orders:order-id (first (orders:live-session-orders session))))))

(test sampling-touches-nothing
  "Nothing in the session touches a pre-existing order, so any migration
would be the sampler's."
  (with-demo-log (path)
    (multiple-value-bind (sink seen) (collecting-sink)
      (let ((result (with-sampler ((list sink)) (untouched-session))))
        (is (eq :promoted (orders:session-result-final-state result)))
        (is (= 0 (forward-migrations path)))
        (is (plusp (length (funcall seen))))
        (is (every #'all-pending-p (funcall seen)))))))

(test the-no-touch-test-is-live
  "The same check, with a sink that reads one slot, must fail."
  (with-demo-log (path)
    (multiple-value-bind (sink seen) (collecting-sink)
      (with-sampler ((list #'touching-sink sink)) (untouched-session))
      (is (= 1 (forward-migrations path)))
      (is (notevery #'all-pending-p (funcall seen))))))

(test nothing-prints-an-order
  "Probe claim 7: a full sampler run over a live session never prints an order."
  (let ((method (defmethod print-object :before ((o orders:order) stream)
                  (declare (ignore stream))
                  (error "printed an order"))))
    (unwind-protect
         (with-demo-log (path)
           (declare (ignore path))
           (multiple-value-bind (sink seen) (collecting-sink)
             (with-sampler ((list sink)) (untouched-session))
             (is (plusp (length (funcall seen))))
             (is (every (lambda (s) (null (getf s :faults))) (funcall seen)))))
      (remove-method #'print-object method))))

(test the-shipped-reader-is-the-probed-one
  "Probe claim 1, against LAYOUT-PENDING-P itself."
  (with-demo-log (path)
    (declare (ignore path))
    (orders:reset-workload)
    (unwind-protect
         (let ((orders (orders:make-pre-existing-orders (orders:make-rng 42) 40)))
           (splice:install (orders:register-currency-patch-set))
           (dotimes (i 1000) (mapc #'d::layout-pending-p orders))
           (is (= 0 (splice:migration-journal-count)))
           (is (every #'d::layout-pending-p orders)))
      (orders:reset-workload))))

(test sampling-leaves-the-outcome-alone
  (with-demo-log (path)
    (declare (ignore path))
    (let ((quiet (orders:run-canary-session :seed 1001 :quiet t))
          (sampled (with-sampler ('()) (orders:run-canary-session :seed 1001 :quiet t))))
      (is (eq :promoted (orders:session-result-final-state sampled)))
      (is (equal (mapcar #'car (orders:session-result-transitions quiet))
                 (mapcar #'car (orders:session-result-transitions sampled)))))))

(test an-unreadable-frame-is-skipped
  (let ((broken (orders::make-live-session
                 :patch-set nil :orders '() :started 1 :audit-start-seq 0
                 :pacer (orders::make-pacer)))
        (snapshot (d:empty-snapshot))
        (called nil))
    (multiple-value-bind (next faults)
        (d::sample-session snapshot '() broken
                           (list (lambda (s) (setf called s))))
      (is (eq snapshot next))
      (is (= 1 (length faults)))
      (is (null called)))))

(test between-sessions-calls-no-sink
  (let ((orders:*live-session* nil)
        (called nil))
    (multiple-value-bind (next faults)
        (d:sample-once :previous '(:old) (list (lambda (s) (setf called s))))
      (is (eq :previous next))
      (is (equal '(:old) faults))
      (is (null called)))))

(test a-failing-sink-stops-nothing
  (multiple-value-bind (sink seen) (collecting-sink)
    (let ((faults (d::call-sinks (list (lambda (s) (error "boom ~a" s)) sink)
                                 '(:seq 0))))
      (is (= 1 (length faults)))
      (is (equal '((:seq 0)) (funcall seen))))))

(test lanes-are-filtered
  (let* ((gate (sb-thread:make-semaphore))
         (threads (mapcar (lambda (name)
                            (sb-thread:make-thread (lambda () (sb-thread:wait-on-semaphore gate))
                                                   :name name))
                          '("CLOG event handler next:click" "orders-worker-9"))))
    (unwind-protect
         (let ((names (mapcar (lambda (lane) (getf lane :name)) (d::read-lanes))))
           (is (member "orders-worker-9" names :test #'string=))
           (is (not (member "CLOG event handler next:click" names :test #'string=))))
      (sb-thread:signal-semaphore gate 2)
      (mapc #'sb-thread:join-thread threads))))

(test the-tail-is-read-down-to-the-cursor
  (let ((lines '("(:seq 105)" "(:seq 104)" "(:seq 103)" "not lisp (")))
    (multiple-value-bind (entries status) (d::collect-newer lines 103)
      (is (equal '((:seq 104) (:seq 105)) entries))
      (is (eq :complete status))))
  (multiple-value-bind (entries status)
      (d::collect-newer '("(:seq 105)" "(:seq 104)") 50)
    (is (= 2 (length entries)))
    (is (eq :trimmed status))))

(test classify-order-states
  (is (eq :pending (d::classify-order t t)))
  (is (eq :pending (d::classify-order t nil)))
  (is (eq :migrated (d::classify-order nil t)))
  (is (eq :current (d::classify-order nil nil))))

(test one-sampler-at-a-time
  (unwind-protect
       (progn
         (is (typep (d:start-sampler '()) 'sb-thread:thread))
         (is (eq :already-running (d:start-sampler '())))
         (is (eq :stopped (d:stop-sampler)))
         (is (eq :not-running (d:stop-sampler))))
    (d:stop-sampler)))
