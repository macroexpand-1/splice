;;;; record.lisp: tests for the demo's recorder, player and checker

(in-package #:splice-orders/demo-tests)

(def-suite demo-record :in demo :description "Recorder, loader, player and checker.")
(in-suite demo-record)

(defun frames (&rest elapsed)
  "A vector of minimal current-version snapshots at the given ELAPSED-MS values."
  (coerce (loop for ms in elapsed for seq from 0
                collect (list :version d:+snapshot-version+ :seq seq :elapsed-ms ms))
          'vector))

(defun test-header (&rest fields)
  "A current recording header, with FIELDS in front to override it."
  (append fields (list :recording 1 :snapshot-version d:+snapshot-version+
                       :splice-commit "0000000" :started "2026-11-03T00:00:00Z")))

(defun temp-recording-path ()
  (merge-pathnames (format nil "splice-recording-~a.sexp"
                           (random most-positive-fixnum (make-random-state t)))
                   (uiop:temporary-directory)))

(defun call-with-recording-file (forms fn)
  "Call FN with the path of a temporary file holding FORMS, one per line; delete it after."
  (let ((path (temp-recording-path)))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (dolist (form forms) (d:write-snapshot form out)))
    (unwind-protect (funcall fn path)
      (uiop:delete-file-if-exists path))))

(defun load-status (forms &rest args)
  "The status LOAD-RECORDING gives for a file holding FORMS."
  (call-with-recording-file forms (lambda (path) (values (apply #'d:load-recording path args)))))

(defun elapsed-ms (fn)
  "How many milliseconds calling FN takes."
  (let ((start (get-internal-real-time)))
    (funcall fn)
    (/ (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second)))

(defun with-one-llr-changed (snapshots)
  "A copy of SNAPSHOTS whose last frame with an errors walk has its newest LLR moved by 1."
  (let* ((copy (copy-seq snapshots))
         (index (position-if (lambda (s) (getf (getf s :sprt) :errors)) copy :from-end t))
         (frame (aref copy index))
         (sprt (getf frame :sprt))
         (errors (getf sprt :errors))
         (newest (first (last errors))))
    (setf (aref copy index)
          (list* :sprt (list* :errors (append (butlast errors)
                                              (list (cons (car newest) (+ 1 (cdr newest)))))
                              sprt)
                 frame))
    copy))

(test round-trip-renders-the-same
  (let ((fixtures (all-fixtures))
        (path (temp-recording-path)))
    (unwind-protect
         (progn
           (multiple-value-bind (sink close) (d:make-recorder path (test-header))
             (mapc sink fixtures)
             (funcall close))
           (multiple-value-bind (status header snapshots) (d:load-recording path :commit nil)
             (declare (ignore header))
             (is (eq :loaded status))
             (is (equal (mapcar (lambda (s) (d:render-frame nil s)) fixtures)
                        (map 'list (lambda (s) (d:render-frame nil s)) snapshots)))))
      (uiop:delete-file-if-exists path))))

(test refusals
  (let ((snapshot (load-fixture "act-1-promoted")))
    (is (eq :missing (d:load-recording (temp-recording-path) :commit nil)))
    (is (eq :wrong-recording-version (load-status '() :commit nil)))
    (is (eq :wrong-recording-version (load-status (list (test-header :recording 2) snapshot) :commit nil)))
    (is (eq :wrong-snapshot-version
            (load-status (list (test-header) (list :version (1+ d:+snapshot-version+))) :commit nil)))
    (is (eq :wrong-commit (load-status (list (test-header) snapshot) :commit "801108c")))
    (is (eq :loaded (load-status (list (test-header) snapshot) :commit nil)))
    (is (eq :empty (load-status (list (test-header)) :commit nil)))))

(test replay-in-order
  (let ((seen '()))
    (is (eq :finished (d:replay-recording
                       (frames 0 100 200) (lambda (snapshot index)
                                            (declare (ignore snapshot))
                                            (push index seen))
                       :speed 0)))
    (is (equal '(0 1 2) (reverse seen)))))

(test replay-keeps-the-recorded-pace
  (let ((ms (elapsed-ms (lambda ()
                          (d:replay-recording (frames 0 100 200)
                                              (lambda (snapshot index)
                                                (declare (ignore snapshot index)))
                                              :speed 1)))))
    (is (< (abs (- ms 200)) 50))))

(test jump-goes-first
  (let ((position (d::make-position)))
    (setf (d::play-position-index position) 2
          (d::play-position-jump position) 0)
    (is (equal '(:jump 0) (d::next-step position 3)))
    (is (equal '(:play 1) (d::next-step position 3)))))

(test a-jump-calls-on-jump-once
  (let ((position (d::make-position))
        (seen '())
        (jumps 0))
    (setf (d::play-position-index position) 2
          (d::play-position-jump position) 0)
    (d:replay-recording (frames 0 100 200)
                        (lambda (snapshot index)
                          (declare (ignore snapshot))
                          (push index seen))
                        :speed 0 :position position :on-jump (lambda () (incf jumps)))
    (is (= 1 jumps))
    (is (equal '(0 1 2) (reverse seen)))))

(test pause-shows-no-frame
  (let ((position (d::make-position)))
    (setf (d::play-position-paused position) t)
    (is (eq :paused (d::next-step position 3)))
    (is (= 0 (d::play-position-index position)))))

(test hold-at-end
  (let ((position (d::make-position :hold t)))
    (setf (d::play-position-index position) 3)
    (is (eq :paused (d::next-step position 3)))))

(test one-player-joined
  (let ((d::*player* nil)
        (sink (lambda (frame) (declare (ignore frame)))))
    (unwind-protect
         (progn
           (is (eq :started (d:start-player (test-header) (frames 0) sink :speed 0)))
           (is (eq :already-running (d:start-player (test-header) (frames 0) sink :speed 0)))
           (let ((thread (d::player-thread d::*player*)))
             (is (eq :stopped (d:stop-player)))
             (is (not (sb-thread:thread-alive-p thread))))
           (is (eq :not-running (d:stop-player))))
      (d:stop-player))))

(test replay-is-marked
  (let* ((plain (load-fixture "act-1-canary-25"))
         (marked (d::mark-replay plain (test-header) 0 1 '())))
    (is (search (d::set-hidden "replay" nil) (frame-text nil marked)))
    (is (search (d::set-hidden "replay" t) (frame-text marked plain)))))

(test a-failing-sink-is-a-fault-on-the-next-frame
  (let ((calls 0)
        (faults '()))
    (is (eq :finished
            (d::run-player (d::make-player :position (d::make-position))
                           (test-header) (frames 0 100 200)
                           (lambda (frame)
                             (when (= 1 (incf calls)) (error "boom"))
                             (push (getf frame :faults) faults))
                           (constantly :ignored) 0)))
    (destructuring-bind (after-failure after-success) (reverse faults)
      (is (= 1 (length after-failure)))
      (is (stringp (first after-failure)))
      (is (null after-success)))))

(test the-checker-matches-its-log
  "A seed 2002 session recorded through a sampler, checked against its own log."
  (with-demo-log (path)
    (let ((steps splice::*audit-sprt-steps*)
          (recording (temp-recording-path)))
      (setf splice::*audit-sprt-steps* t
            orders:*live-session* nil)
      (unwind-protect
           (progn
             (multiple-value-bind (sink close) (d:make-recorder recording (test-header))
               (with-sampler ((list sink))
                 (orders:run-canary-session :seed 2002 :fault :latent :quiet t))
               (funcall close))
             (let ((snapshots (nth-value 2 (d:load-recording recording :commit nil))))
               (is (eq :consistent (d:check-recording snapshots path)))
               (is (eq :inconsistent (d:check-recording (with-one-llr-changed snapshots) path)))
               (is (eq :broken-log (d:check-recording snapshots (d:tamper-copy path))))))
        (setf splice::*audit-sprt-steps* steps)
        (uiop:delete-file-if-exists recording)))))

(test an-abandoned-recording-still-loads
  (let ((path (temp-recording-path)))
    (multiple-value-bind (sink close) (d:make-recorder path (test-header))
      (unwind-protect
           (progn
             (funcall sink (load-fixture "act-1-paused-stage-0"))
             (funcall sink (load-fixture "act-1-canary-25"))
             (multiple-value-bind (status header snapshots) (d:load-recording path :commit nil)
               (declare (ignore header))
               (is (eq :loaded status))
               (is (= 2 (length snapshots)))))
        (funcall close)
        (uiop:delete-file-if-exists path)))))

(test recorded-points-are-the-walk
  (let ((points (d::recorded-sprt-points (vector (load-fixture "act-2-reject")))))
    (is (= 96 (length points)))
    (is (member '(:errors 50 . 38.830536) points :test #'equal))
    (is (member '(:slow 46 . -5.1163793) points :test #'equal))))
