;;;; sprt.lisp: the canary's mixture sequential test, and the control ring
;;;; One test per (patch-set stage signal), decision 0014. It looks only for
;;;; harm: events (failures, or latency above the control p95) coming from
;;;; the new arm more often than the traffic split predicts.
;;;; Lindon and Malek, "Anytime-Valid Inference for Multinomial Count Data"
;;;; (arXiv 2011.03567v2): section 2 for the mixture and its 1/u bound,
;;;; section 3 for why the arm an event lands in ignores the shared rate.

(in-package #:splice)

(defparameter *power-z-scores*
  '((0.2d0 . 0.8416d0) (0.1d0 . 1.2816d0) (0.05d0 . 1.6449d0) (0.01d0 . 2.3263d0))
  "One-sided normal quantile for each BETA the stage budget accepts.")

(defparameter *latency-event-rate* 0.05d0
  "Share of control observations above the control p95, by construction.
Stage budgets are sized on the latency signal at this rate.")

(defparameter *harm-steps* 8
  "Number of harm ratios the mixture spreads its weight over.")

;;; ---------------------------------------------------------------------
;;; Sequential test

(defstruct (mixture-test (:constructor %make-mixture-test))
  (kind :two-sample :read-only t)             ; :two-sample or :one-sample
  (null-share 0d0 :type double-float :read-only t)
  (alternatives '() :read-only t)             ; one share per harm ratio
  (log-reject 0d0 :type double-float :read-only t)
  ;; mutable
  (hits 0 :type fixnum)
  (misses 0 :type fixnum))

(defun harm-ratios (min-effect)
  "Rate ratios (1+MIN-EFFECT)^(j/2) for j from 1 to *HARM-STEPS*. The second
is the smallest effect worth catching."
  (loop for j from 1 to *harm-steps*
        collect (expt (+ 1d0 min-effect) (/ j 2))))

(defun harm-share (null-share ratio)
  "The hit probability when the new arm's rate is RATIO times the control's,
given the hit probability NULL-SHARE when they are equal (paper, eq. 12)."
  (let ((new (* null-share ratio)))
    (/ new (+ (- 1d0 null-share) new))))

(defun make-mixture-test (kind null-share &key alpha min-effect)
  "A test of KIND against NULL-SHARE. A :TWO-SAMPLE hit is an event on the
new arm and its NULL-SHARE is the new arm's traffic share. A :ONE-SAMPLE hit
is a new-arm observation with an event and its NULL-SHARE is the control
arm's event rate. Rejects at 2/ALPHA, half the stage's alpha per signal."
  (let ((share (coerce null-share 'double-float)))
    (assert (< 0d0 share 1d0) () "null share ~a is not inside (0, 1)" share)
    (%make-mixture-test
     :kind kind
     :null-share share
     :alternatives (mapcar (lambda (ratio) (harm-share share ratio))
                           (harm-ratios min-effect))
     :log-reject (log (/ 2d0 alpha)))))

(defun mixture-observe (mixture-test route event-p)
  "Fold one observation on ROUTE into MIXTURE-TEST and return its verdict."
  (ecase (mixture-test-kind mixture-test)
    (:two-sample (fold-two-sample mixture-test route event-p))
    (:one-sample (fold-one-sample mixture-test route event-p)))
  (mixture-verdict mixture-test))

(defun fold-two-sample (mixture-test route event-p)
  "Only events count: a hit when the new arm had it, a miss for the control.
Returns :hit, :miss or :ignored."
  (cond ((not event-p) :ignored)
        ((eq route :new) (incf (mixture-test-hits mixture-test)) :hit)
        ((eq route :old) (incf (mixture-test-misses mixture-test)) :miss)
        (t (error "route ~s is neither :new nor :old" route))))

(defun fold-one-sample (mixture-test route event-p)
  "Only the new arm counts: a hit for an event, a miss otherwise.
Returns :hit, :miss or :ignored."
  (cond ((eq route :old) :ignored)
        ((not (eq route :new)) (error "route ~s is neither :new nor :old" route))
        (event-p (incf (mixture-test-hits mixture-test)) :hit)
        (t (incf (mixture-test-misses mixture-test)) :miss)))

(defun log-ratio-steps (share null-share)
  "Log likelihood ratio one hit adds, and one miss adds, at SHARE against
NULL-SHARE."
  (values (log (/ share null-share))
          (log (/ (- 1d0 share) (- 1d0 null-share)))))

(defun component-log-ratio (share null-share hits misses)
  "Log likelihood ratio of HITS and MISSES at SHARE against NULL-SHARE."
  (multiple-value-bind (hit-step miss-step) (log-ratio-steps share null-share)
    (+ (* hits hit-step) (* misses miss-step))))

(defun log-mean-exp (logs)
  "Log of the mean of the exponentials of LOGS, without overflow."
  (let ((top (reduce #'max logs)))
    (+ top (log (/ (reduce #'+ logs :key (lambda (x) (exp (- x top))))
                   (length logs))))))

(defun mixture-log-odds (mixture-test)
  "Log of the equal-weight mixture of the alternatives' likelihood ratios."
  (log-mean-exp
   (mapcar (lambda (share)
             (component-log-ratio share
                                  (mixture-test-null-share mixture-test)
                                  (mixture-test-hits mixture-test)
                                  (mixture-test-misses mixture-test)))
           (mixture-test-alternatives mixture-test))))

(defun mixture-verdict (mixture-test)
  ":reject once the log odds reach the threshold, otherwise :continue."
  (if (>= (mixture-log-odds mixture-test) (mixture-test-log-reject mixture-test))
      :reject
      :continue))

(defun mixture-snapshot (mixture-test signal)
  "Plist of the whole test state for the audit log, so every verdict can be
recomputed from the log alone."
  (list :signal signal
        :kind (mixture-test-kind mixture-test)
        :hits (mixture-test-hits mixture-test)
        :misses (mixture-test-misses mixture-test)
        :null-share (float (mixture-test-null-share mixture-test) 1.0)
        :log-odds (float (mixture-log-odds mixture-test) 1.0)
        :log-reject (float (mixture-test-log-reject mixture-test) 1.0)))

;;; ---------------------------------------------------------------------
;;; Stage budget
;;; New-arm observations a stage needs before passing: enough for the
;;; latency test to reach its threshold at 1+MIN-EFFECT with power 1-BETA.
;;; A normal approximation to the mixture's drift, not from the paper.

(defun power-z-score (beta)
  (let ((entry (assoc beta *power-z-scores* :test #'=)))
    (unless entry
      (error "beta ~a has no z-score; use one of ~{~a~^, ~}"
             beta (mapcar #'car *power-z-scores*)))
    (cdr entry)))

(defun drift-moments (share null-share hits misses)
  "Mean and second moment of the log ratio, from the HITS and MISSES expected
per observation."
  (multiple-value-bind (hit-step miss-step) (log-ratio-steps share null-share)
    (values (component-log-ratio share null-share hits misses)
            (+ (* hits hit-step hit-step) (* misses miss-step miss-step)))))

(defun two-sample-drift (traffic-share min-effect)
  "Mean and variance of the min-effect log ratio per new-arm observation.
Hits and misses are independent counts, so the variance is the second moment."
  (let ((rate *latency-event-rate*))
    (drift-moments (harm-share traffic-share (+ 1d0 min-effect))
                   traffic-share
                   (* rate (+ 1d0 min-effect))
                   (* rate (/ (- 1d0 traffic-share) traffic-share)))))

(defun one-sample-drift (min-effect)
  "Mean and variance of the min-effect log ratio per new-arm observation.
Each observation is exactly one hit or one miss, so the variance is the
second moment less the squared mean."
  (let* ((rate *latency-event-rate*)
         (share (harm-share rate (+ 1d0 min-effect))))
    (multiple-value-bind (mean second) (drift-moments share rate share (- 1d0 share))
      (values mean (- second (* mean mean))))))

(defun observations-to-cross (mean variance distance z)
  "Smallest n with n*MEAN - Z*sqrt(n*VARIANCE) >= DISTANCE.
MEAN must be positive, otherwise no n ever crosses."
  (assert (plusp mean) () "mean drift ~a never crosses ~a" mean distance)
  (loop for n from 1
        when (>= (- (* n mean) (* z (sqrt (* n variance)))) distance)
          return n))

(defun stage-budget (fraction &key alpha beta min-effect)
  "New-arm observations a stage at FRACTION percent scores before it passes."
  (multiple-value-bind (mean variance)
      (if (< fraction 100)
          (two-sample-drift (/ fraction 100d0) min-effect)
          (one-sample-drift min-effect))
    (observations-to-cross mean variance
                           ;; the min-effect component carries 1/*HARM-STEPS* weight
                           (+ (log (/ 2d0 alpha)) (log *harm-steps*))
                           (power-z-score beta))))

;;; ---------------------------------------------------------------------
;;; Control-arm tracking
;;; Ring buffers of recent control outcomes/latencies give the baseline and
;;; the confound check.

(defstruct (control-ring (:constructor %make-control-ring))
  (outcomes nil :read-only t)
  (latencies nil :read-only t)
  (size 500 :read-only t)
  (lock (sb-thread:make-mutex) :read-only t)
  ;; mutable
  (head 0)
  (count 0))

(defun make-control-ring (&key (size 500))
  (%make-control-ring :size size
                      :outcomes (make-array size :initial-element nil)
                      :latencies (make-array size :initial-element 0)))

(defun control-record (ring failure-p latency-ms)
  (sb-thread:with-mutex ((control-ring-lock ring))
    (setf (aref (control-ring-outcomes ring)  (control-ring-head ring)) failure-p
          (aref (control-ring-latencies ring) (control-ring-head ring)) latency-ms
          (control-ring-head ring) (mod (1+ (control-ring-head ring))
                                        (control-ring-size ring)))
    (setf (control-ring-count ring)
          (min (control-ring-size ring) (1+ (control-ring-count ring))))))

(defun control-failure-rate (ring &key (min-samples 30))
  "Failure rate over the ring or :TOO-FEW-SAMPLES"
  (sb-thread:with-mutex ((control-ring-lock ring))
    (let ((n (control-ring-count ring)))
      (if (>= n min-samples)
          (/ (loop for i from 0 below n
                   count (aref (control-ring-outcomes ring) i))
             (float n 1d0))
          :too-few-samples))))

(defun control-latency-quantile (ring q &key (min-samples 30))
  "Latency at quantile Q over the ring or :TOO-FEW-SAMPLES"
  (sb-thread:with-mutex ((control-ring-lock ring))
    (let ((n (control-ring-count ring)))
      (if (>= n min-samples)
          (let ((sorted (sort (subseq (control-ring-latencies ring) 0 n) #'<)))
            (aref sorted (min (1- n) (floor (* q n)))))
          :too-few-samples))))

(defun control-exceedance-rate (ring threshold-ms &key (min-samples 30))
  "Share of the ring's latencies above THRESHOLD-MS or :TOO-FEW-SAMPLES"
  (sb-thread:with-mutex ((control-ring-lock ring))
    (let ((n (control-ring-count ring)))
      (if (>= n min-samples)
          (/ (loop for i from 0 below n
                   count (> (aref (control-ring-latencies ring) i) threshold-ms))
             (float n 1d0))
          :too-few-samples))))
