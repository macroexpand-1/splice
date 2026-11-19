;;;; sprt.lisp: the mixture test, the stage budget, and the control ring.

(in-package #:splice-tests)

(def-suite sprt :in splice-tests)
(in-suite sprt)

(defun close-to (a b &optional (tolerance 1d-9))
  (< (abs (- a b)) tolerance))

(defun observe-until-decided (mixture-test route event-p limit)
  "Feed MIXTURE-TEST the same observation until it rejects or LIMIT
observations go by. Returns the verdict."
  (loop repeat limit
        for verdict = (splice:mixture-observe mixture-test route event-p)
        when (eq verdict :reject)
          return verdict
        finally (return :continue)))

;;; ---------------------------------------------------------------------
;;; The mixture

(test harm-share-follows-the-rate-ratio
  ;; paper, eq. 12: a 2x rate on a half share takes two thirds of the events
  (is (close-to (/ 2d0 3) (splice::harm-share 0.5d0 2d0)))
  (is (close-to 0.05d0 (splice::harm-share 0.05d0 1d0))))

(test one-alternative-is-the-plain-likelihood-ratio
  (let* ((splice::*harm-steps* 1)
         (test (splice:make-mixture-test :two-sample 0.5d0 :alpha 0.01d0 :min-effect 3d0)))
    (splice:mixture-observe test :new t)
    (is (close-to (log (/ 4d0 3)) (splice:mixture-log-odds test)))
    (splice:mixture-observe test :old t)
    (is (close-to (log (/ 8d0 9)) (splice:mixture-log-odds test)))))

(test the-mixture-averages-the-alternatives
  ;; ratios 2 and 4 on a half share give shares 2/3 and 4/5
  (let* ((splice::*harm-steps* 2)
         (test (splice:make-mixture-test :two-sample 0.5d0 :alpha 0.01d0 :min-effect 3d0)))
    (splice:mixture-observe test :new t)
    (is (close-to (log (/ (+ (/ 4d0 3) (/ 8d0 5)) 2)) (splice:mixture-log-odds test)))))

(test two-sample-counts-only-events
  (let ((test (splice:make-mixture-test :two-sample 0.05d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (splice:mixture-observe test :new nil)
    (splice:mixture-observe test :old nil)
    (is (= 0 (splice::mixture-test-hits test) (splice::mixture-test-misses test)))
    (is (close-to 0d0 (splice:mixture-log-odds test)))))

(test one-sample-ignores-the-control-arm
  (let ((test (splice:make-mixture-test :one-sample 0.01d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (splice:mixture-observe test :old t)
    (is (= 0 (splice::mixture-test-hits test) (splice::mixture-test-misses test)))
    (splice:mixture-observe test :new nil)
    (is (= 1 (splice::mixture-test-misses test)))))

(test rejects-at-two-over-alpha
  (let ((test (splice:make-mixture-test :two-sample 0.05d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (is (close-to (log 200d0) (splice::mixture-test-log-reject test)))
    (is (eq :reject (observe-until-decided test :new t 100)))
    (is (>= (splice:mixture-log-odds test) (log 200d0)))))

(test a-better-new-arm-never-rejects
  ;; events on a 5% arm, but the new arm has a fortieth of them, half its share
  (let ((test (splice:make-mixture-test :two-sample 0.05d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (is (eq :continue (loop for i from 1 to 2000
                            for route = (if (zerop (mod i 40)) :new :old)
                            for verdict = (splice:mixture-observe test route t)
                            when (eq verdict :reject) return :reject
                            finally (return :continue))))
    (is (< (splice:mixture-log-odds test) 0d0))))

(test a-null-share-outside-the-unit-interval-is-refused
  (signals error (splice:make-mixture-test :one-sample 0d0 :alpha 0.01d0 :min-effect 0.3d0))
  (signals error (splice:make-mixture-test :two-sample 1d0 :alpha 0.01d0 :min-effect 0.3d0)))

(test an-unknown-route-is-refused
  (let ((test (splice:make-mixture-test :two-sample 0.5d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (signals error (splice:mixture-observe test :sideways t))))

(test snapshot-carries-the-whole-test-state
  (let ((test (splice:make-mixture-test :two-sample 0.25d0 :alpha 0.01d0 :min-effect 0.3d0)))
    (splice:mixture-observe test :new t)
    (let ((snapshot (splice::mixture-snapshot test :errors)))
      (is (eq :errors (getf snapshot :signal)))
      (is (eq :two-sample (getf snapshot :kind)))
      (is (= 1 (getf snapshot :hits)))
      (is (= 0 (getf snapshot :misses)))
      (is (close-to 0.25d0 (getf snapshot :null-share) 1d-6))
      (is (close-to (log 200d0) (getf snapshot :log-reject) 1d-5)))))

;;; ---------------------------------------------------------------------
;;; Stage budget

(test budgets-for-the-default-options
  (flet ((budget (fraction)
           (splice:stage-budget fraction :alpha 0.01d0 :beta 0.05d0 :min-effect 0.3d0)))
    (is (= 9004 (budget 5)))
    (is (= 11450 (budget 25)))
    (is (= 17256 (budget 50)))
    (is (= 9136 (budget 100)))))

(test a-larger-effect-needs-a-smaller-budget
  (is (< (splice:stage-budget 50 :alpha 0.01d0 :beta 0.05d0 :min-effect 3d0)
         (splice:stage-budget 50 :alpha 0.01d0 :beta 0.05d0 :min-effect 0.3d0))))

(test an-unlisted-beta-is-refused
  (signals error (splice:stage-budget 5 :alpha 0.01d0 :beta 0.07d0 :min-effect 0.3d0)))

;;; ---------------------------------------------------------------------
;;; Control ring

(defun ring-with (outcomes &key (size 500) (latency 1))
  (let ((ring (splice::make-control-ring :size size)))
    (dolist (failure-p outcomes ring)
      (splice::control-record ring failure-p latency))))

(test failure-rate-needs-enough-samples
  (is (eq :too-few-samples (splice::control-failure-rate (ring-with (make-list 29)))))
  (is (= 0 (splice::control-failure-rate (ring-with (make-list 30))))))

(test failure-rate-counts-failures
  (let ((ring (ring-with (append (make-list 30 :initial-element t)
                                 (make-list 90)))))
    (is (close-to 0.25d0 (splice::control-failure-rate ring)))))

(test the-ring-forgets-its-oldest-outcomes
  (let ((ring (ring-with (append (make-list 40 :initial-element t)
                                 (make-list 40))
                         :size 40)))
    (is (= 40 (splice::control-ring-count ring)))
    (is (= 0 (splice::control-failure-rate ring)))))

(test latency-quantile
  (let ((ring (splice::make-control-ring :size 100)))
    ;; record 100 down to 1 so the ring has to sort them
    (loop for ms from 100 downto 1
          do (splice::control-record ring nil ms))
    (is (= 51 (splice::control-latency-quantile ring 0.5)))
    (is (= 100 (splice::control-latency-quantile ring 0.99)))
    (is (= 100 (splice::control-latency-quantile ring 1.0)))
    (is (= 1 (splice::control-latency-quantile ring 0.0)))))

(test latency-quantile-needs-enough-samples
  (is (eq :too-few-samples
          (splice::control-latency-quantile (ring-with (make-list 29)) 0.5))))

(test exceedance-rate-counts-latencies-above-the-threshold
  (let ((ring (splice::make-control-ring :size 100)))
    (loop for ms from 1 to 100
          do (splice::control-record ring nil ms))
    (is (close-to 0.05d0 (splice::control-exceedance-rate ring 95)))
    (is (close-to 0d0 (splice::control-exceedance-rate ring 100)))))
