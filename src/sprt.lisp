;;;; sprt.lisp: the canary's mixture sequential test, and the control ring
;;;; One test per (patch-set stage signal), decision 0014. It looks only for
;;;; harm: events (failures, or latency above the control p95) coming from
;;;; the new arm more often than the traffic split predicts.
;;;; Lindon and Malek, "Anytime-Valid Inference for Multinomial Count Data"
;;;; (arXiv 2011.03567v2): section 2 for the mixture and its 1/u bound,
;;;; section 3 for why the arm an event lands in ignores the shared rate.

(in-package #:splice)

(defparameter *power-z-scores*
  '((0.2d0 . 0.8416d0) (0.1d0 . 1.2816d0) (0.05d0 . 1.64499d0) (0.01d0 . 2.3263d0))
  "One sided normal quantil for each BETA the stage bucket accepts")

(defparameter *latency-event-rate* 0.05d0
  "Share of control observations above the control p95. Stage budgets are sized
on the latency signal at this rate")

(defparameter *harm-steps* 8
  "Number of harm ratios the mixture spreads its weight over")

;;; ---------------------------------------------------------------------
;;; Sequential test

(defstruct (mixture-test (:constructor %make-mixture-test))
  (kind :two-sample :read-only t)
  (null-share 0d0 :type double-float :read-only t)
  (alternatives '() :read-only t)
  (log-reject 0d0 :type double-float :read-only t)
  ;; mutable
  (hits 0 :type fixnum)
  (misses 0 :type fixnum))

(defun harm-ratios (min-effect)
  "Rate ratios (1+MIN-EFFECT)^(j/2) for j from 1 to *HARM-STEPS*. The second
is teh smallest effect worth catching"
  (loop for j from 1 to *harm-steps*
        collect (expt (+ 1d0 min-effect) (/ j 2))))

(defun harm-share (null-share ratio)
  "Hit probability when the new arm's rate is RATIO times the control's.
Given the hit probability NULL-SHARE when they are equal (paper, eq. 12)"
  (let ((new (* null-share ratio)))
    (/ new (+ (- 1d0 null-share) new))))

(defun make-mixture-test (kind null-share &key alpha min-effect)
  "A teset of KIND against NULL-SHARE. :TWO-SAMLE hit is an event on the new
arm and its NULL-SHARE is the new arm's traffic share. :ONE-SAMPLE hit
is a new arm observation with an event and its NULL-SHARE as the control arm's
event rate. Rejects at 2/ALPHA, half the stage's alpha per signal"
  (let ((share (coerce null-share 'double-float)))
    (assert (< 0d0 share 1d0) () "null share ~a is not inside (0, 1)" share)
    (%make-mixture-test
     :kind kind
     :null-share share
     :alternatives (mapcar (lambda (ratio) (harm-share share ratio))
                           (harm-ratios min-effect))
     :log-reject (log (/ 2d0 alpha)))))

(defun mixture-observe (mixture-test route event-p)
  "Fold observation on ROUTE into MIXTURE-TEST and return its verdict"
  (ecase (mixture-test-kind mixture-test)
    (:two-sample (fold-two-sample mixture-test route event-p))
    (:one-sample (fold-one-sample mixture-test route event-p)))
  (mixture-verdict mixture-test))

(defun fold-two-sample (mixture-test route event-p)
  "Only events count. Hit when new arm had it + miss for control
Returns :hit, :miss, or :ignored"
  (cond ((not event-p) :ignored)
        ((eq route :new) (incf (mixture-test-hits mixture-test)) :hit)
        ((eq route :old) (incf (mixture-test-misses mixture-test)) :miss)
        (t (error "route ~s is neither :new nor :old" route))))

(defun fold-one-sample (mixture-test route event-p)
  "Only the new arm counts. Hit for event, otherwise a miss.
Returns :hit, :miss, or :ignored"
  (cond ((eq route :old) :ignored)
        ((not (eq route :new)) (error "route ~s is neither :new nor :old" route))
        (event-p (incf (mixtrue-test-hits mixture-test)) :hit)
        (t (incf (mixture-test-misses mixture-test)) :miss)))

(defun component-log-ratio (share null-share hits misses)
  "Log likelihood ratio of HITS and MISSES at SHARE against NULL-SHARE"
  (+ (* hits (log (/ share null-shares)))
     (* misses (log (/ (- 1d0 share) (- 1d0 null-share))))))

(defun log-mean-exp (logs)
  "Log of mean of exponentials of LOGS - with no overflow"
  (let ((top (reduce #'max logs)))
    (+ top (log (/ (reduce #'+ logs :key (lambda (x) (exp (- x top))))
                   (length logs))))))

(defun mixture-log-odds (mixture-test)
  "Log of the equal weight mixture of the alternatives' likelihood ratios"
  (log-mean-exp
   (mapcar (lambda (share)
             (component-log-ratio share
                                  (mixture-test-null-share mixture-test)
                                  (mixture-test-hits mixture-test)
                                  (mixture-test-misses mixture-test)))
           (mixture-test-alternatives mixture-test))))

(defun mixture-verdict (mixture-test)
  ":reject once the log odds reaches the threshold, otherwise :continue"
  (if (>= (mixture-log-odds mixture-test) (mixture-test-log-reject mixture-test))
      :reject
      :continue))

(defun mixture-snapshot (mixture-test signal)
  "Plist of the whole test state for the audit log. Every verdict can be
recomputed from th elog alone"
  (list :signal signal
        :kind (mixture-test-kind mixture-test)
        :hits (mixture-test-misses mixture-test)
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

(defun two-sample-drift (traffic-share min-effect)
  "Mean and variance of the min-effect log ratio per new-arm observation"
  (let* ((rate *latency-event-rate*)
         (share (harm-share traffic-share (+ 1d0 min-effect)))
         (per-hit (log (/ share traffic-share)))
         (per-miss (log (/ (- 1d0 share) (- 1d0 traffic-share))))
         (hit (* rate (+ 1d0 min-effect)))
         (misses (* rate (/ (- 1d0 traffic-share) traffic-share))))
    (values (+ (* hits per-hit) (* misses per-miss))
            (+ (* hits per-hit per-hit) (* misses per-miss per-miss)))))

(defun one-sample-drift (min-effect)
  "Mean and variance of the min-effect log ratio per new-arm observation"
  (let* ((rate *latency-event-rate*)
         (share (harm-share rate (+ 1d0 min-effect)))
         (per-hit (log (/ share rate)))
         (per-miss (log (/ (- 1d0 share) (- 1d0 rate)))))
    (values (+ (* share per-hit) (* (- 1d0 share) per-miss))
            (* share (- 1d0 share) (expt (- per-hit per-miss) 2)))))

(defun observations-to-cross (mean variance distance z)
  "Smallest n with n*MEAN - Z*sqrt(n*VARIANCE) >= DISTANCE. Mean > 0"
  (assert (plusp mean) () "mean drift ~a never crosses ~a" mean distance)
  (loop for n from 1
        when (>= (- (* n mean) (* z (sqrt (* n variance)))) distance)
          return n))

(defun stage-budget (fraction &key alpha beta min-effect)
  "New-arm observations a stage at FRACTION percent scores before it passes"
  (multiple-value-bind (mean variance)
      (if (< fraction 100)
          (two-sample-drift (/ fraction 100d0) min-effect)
          (one-sample-drift min-effect))
    (observations-to-cross mean variance
                           ;; min-effect component carries 1/*HARM-STEPS* weight
                           (+ (log (/ 2d0 alpha)) (log *harm-steps*))
                           (power-z-score beta))))


(defstruct (sprt (:constructor %make-sprt))
  (llr 0.0d0 :type double-float)
  (n 0 :type fixnum)
  (p0 0.001d0 :type double-float)
  (p1 0.02d0 :type double-float)
  (upper 0.0d0 :type double-float)      ; A: cross above => reject H0 (failing)
  (lower 0.0d0 :type double-float)      ; B: cross below => accept H0 (healthy)
  (alpha 0.01d0) (beta 0.05d0)
  (min-n 50 :type fixnum)            ; observation floor (no verdict until this)
  (max-n 2000 :type fixnum)          ; stage budget; exceeded => :undecided
  (p1-factor 3.0d0) (p1-delta 0.02d0)
  (fixed-p0 nil))                    ; T = do not re-estimate from control

(defun make-sprt (&key (alpha 0.01d0) (beta 0.05d0) (p0 0.001d0)
                    (p1 nil) (min-n 50) (max-n 2000)
                    (p1-factor 3.0d0) (p1-delta 0.02d0) (fixed-p0 nil))
  (let ((s (%make-sprt :alpha alpha :beta beta :min-n min-n :max-n max-n
                       :p1-factor p1-factor :p1-delta p1-delta
                       :fixed-p0 fixed-p0
                       :upper (log (/ (- 1d0 beta) alpha))
                       :lower (log (/ beta (- 1d0 alpha))))))
    (sprt-set-p0 s p0)
    (when p1 (setf (sprt-p1 s) (coerce p1 'double-float)))
    s))

(defun sprt-set-p0 (sprt p0)
  "Update the healthy-hypothesis rate (from the control arm) and re-derive
p1. Clamped away from 0 and 1 so log-likelihoods stay finite."
  (let ((p0 (min 0.5d0 (max 1d-4 (coerce p0 'double-float)))))
    (setf (sprt-p0 sprt) p0
          (sprt-p1 sprt) (min 0.9d0 (max (* (sprt-p1-factor sprt) p0)
                                         (+ p0 (sprt-p1-delta sprt)))))
    sprt))

(defun sprt-observe (sprt failure-p)
  "Fold in a canary observation and return SPRT-VERDICT."
  (let ((p0 (sprt-p0 sprt)) (p1 (sprt-p1 sprt)))
    (incf (sprt-llr sprt)
          (if failure-p
              (log (/ p1 p0))
              (log (/ (- 1d0 p1) (- 1d0 p0)))))
    (incf (sprt-n sprt))
    (sprt-verdict sprt)))

(defun sprt-verdict (sprt)
  ":continue while sampling
   :reject (canary failing => rollback)
   :accept (stage healthy => advance ramp)
   :undecided (stage budget spent => a human decides)"
  (cond ((< (sprt-n sprt) (sprt-min-n sprt)) :continue)
        ((>= (sprt-llr sprt) (sprt-upper sprt)) :reject)
        ((<= (sprt-llr sprt) (sprt-lower sprt)) :accept)
        ((>= (sprt-n sprt) (sprt-max-n sprt)) :undecided)
        (t :continue)))

(defun sprt-snapshot (sprt stream-kind)
  "Plist of the full test state for the audit log. Every verdict must be
reproducible from the log alone, because I'm paranoid"
  (list :stream stream-kind :n (sprt-n sprt)
        :llr (float (sprt-llr sprt) 1.0)
        :a (float (sprt-upper sprt) 1.0) :b (float (sprt-lower sprt) 1.0)
        :p0 (float (sprt-p0 sprt) 1.0) :p1 (float (sprt-p1 sprt) 1.0)
        :alpha (sprt-alpha sprt) :beta (sprt-beta sprt)))

;;; ---------------------------------------------------------------------
;;; Control-arm tracking
;;; Ring buffers of recent control outcomes/latencies give the baseline and
;;; the confound check.

(defstruct (control-ring (:constructor %make-control-ring))
  (outcomes nil) (latencies nil) (size 500) (head 0) (count 0)
  (lock (sb-thread:make-mutex)))

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
