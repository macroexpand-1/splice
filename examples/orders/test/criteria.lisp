;;;; criteria.lisp: measures the success criteria that move with chance or
;;;; with the machine (detection rates, false rejects, operating
;;;; characteristics, shim overhead) and writes artifacts/criteria-report.md
;;;; (under examples/orders/) with the numbers. CI uploads the report and
;;;; doesn't gate on it. From the repository root:
;;;;
;;;;   sbcl --non-interactive --eval '(require :asdf)' \
;;;;        --eval '(asdf:load-asd (truename "splice.asd"))' \
;;;;        --eval '(asdf:load-asd (truename "examples/orders/splice-orders.asd"))' \
;;;;        --eval '(asdf:test-system "splice-orders/criteria")'     ; full (~15 min)
;;;;
;;;; SPLICE_RUNS=20 in the environment gives a quicker run. TEST-OP signals
;;;; an error when any criterion fails, so a non-interactive run exits
;;;; nonzero. From a REPL, (splice-orders/criteria:run-criteria :runs 20)
;;;; returns T when every criterion passes.

(defpackage :splice-orders/criteria
  (:use :cl)
  (:local-nicknames (#:orders #:splice-orders))
  (:export #:run-criteria))
(in-package :splice-orders/criteria)

(defstruct batch kind runs (caught 0) final-states stages detect-ns detect-tasks)

(defvar *runs* 100 "Sessions per fault class; bound by RUN-CRITERIA.")
(defvar *failures* '())
(defvar *report* '())
(defvar *batches* '())
(defvar *big-log* nil "The log the session batches and the overhead run share.")
(defvar *oc-rows* '() "One row per traffic shape the C8 run measured, newest first")
(defparameter *oc-fraction* 25 "The stage every C8 run canaries at")

;;; ---------------------------------------------------------------------
;;; Helpers

(defun root () (asdf:system-source-directory "splice-orders"))
(defun scratch-file (name) (merge-pathnames name (uiop:temporary-directory)))

(defun fresh-scratch-log (name)
  "SCRATCH-FILE NAME with any log a previous run left deleted"
  (let ((path (scratch-file name)))
    (splice:delete-audit-log path)
    path))

(defun default-runs ()
  (let ((v (sb-ext:posix-getenv "SPLICE_RUNS")))
    (if v (parse-integer v) 100)))

(defun check (name ok detail)
  (format t "~:[FAIL~;ok  ~] ~a~@[: ~a~]~%" ok name detail)
  (unless ok (push (list name detail) *failures*))
  (push (list name ok detail) *report*)
  ok)

(defun median (numbers)
  (let ((s (sort (remove-if-not #'integerp numbers) #'<)))
    (when s (nth (floor (length s) 2) s))))

(defun wilson-ci (k n &optional (z 1.96))
  "95% Wilson score interval for a binomial proportion."
  (let* ((p (/ k (float n)))
         (z2n (/ (* z z) n))
         (center (/ (+ p (/ z2n 2)) (1+ z2n)))
         (half (/ (* z (sqrt (+ (/ (* p (- 1 p)) n) (/ z2n n 4)))) (1+ z2n))))
    (list (max 0.0 (- center half)) (min 1.0 (+ center half)))))

;;; ---------------------------------------------------------------------
;;; C2/C6: fault matrix and statistical honesty
;;; Over *RUNS* sessions per fault class.

(defun batch-count (state b)
  (count state (batch-final-states b)))

(defun highest-canary-stage (r)
  (loop with best = 0
        for (state . nil) in (orders:session-result-transitions r)
        when (splice::canary-stage-p state)
          do (setf best (max best (parse-integer (subseq (symbol-name state) 7))))
        finally (return best)))

(defun print-session-dot ()
  "One dot as each session starts, so a long batch shows it is moving"
  (write-char #\.)
  (finish-output))

(defun run-batch (kind &key threads)
  "Run *RUNS* sessions with fault KIND, a dot printed per session"
  (let ((b (make-batch :kind kind :runs *runs*)))
    (dotimes (i *runs*)
      (print-session-dot)
      (let* ((r (orders:run-canary-session :fault kind
                                           :seed (+ 10000 (* 131 i)
                                                    (if kind (sxhash kind) 0))
                                           :threads (or threads 1) :quiet t))
             (state (orders:session-result-final-state r)))
        (push state (batch-final-states b))
        (when (eq state :rolled-back)
          (incf (batch-caught b))
          (push (orders:session-result-detection-observations r) (batch-detect-ns b))
          (push (orders:session-result-tasks-run r) (batch-detect-tasks b))
          (push (highest-canary-stage r) (batch-stages b)))))
    (terpri)
    b))

(defun check-clean-batch ()
  "Spurious rollbacks of a clean patch measure the realized false-positive rate."
  (format t "clean batch ")
  (let ((b (run-batch nil)))
    (push (cons :clean b) *batches*)
    (let* ((k (batch-caught b))        ; every rollback of a clean patch is spurious
           (ci (wilson-ci k *runs*))
           (promoted (batch-count :promoted b)))
      ;; alpha bounds a session's whole chance of a spurious rollback, so the
      ;; realized rate only has to be no worse: the CI must reach down to alpha
      (check (format nil "C6: clean-patch spurious rollbacks ~a/~a, 95% CI [~,4f, ~,4f] reaches alpha=0.01 or below"
                     k *runs* (first ci) (second ci))
             (and (<= (first ci) 0.01)
                  ;; and never via a nonsense route: a clean patch must mostly
                  ;; promote, and a frozen, vetoed or undecided session is not
                  ;; a promotion
                  (>= promoted (* 0.9 *runs*)))
             (format nil "promoted ~a, rolled back ~a, frozen ~a, vetoed ~a, other ~a"
                     promoted k (batch-count :frozen b) (batch-count :vetoed b)
                     (- *runs* promoted k (batch-count :frozen b)
                        (batch-count :vetoed b)))))))

(defun check-fault-batches ()
  (dolist (kind (orders:all-fault-kinds))
    (format t "~a batch " kind)
    (let ((b (run-batch kind :threads (when (eq kind :load-correlated) 8))))
      (push (cons kind b) *batches*)
      (check (format nil "C2/C6: ~a detection rate ~a/~a >= 0.95 (1-beta)"
                     kind (batch-caught b) *runs*)
             (>= (batch-caught b) (* 0.95 *runs*)) nil)
      (when (eq kind :load-correlated)
        (let ((at-5 (count 5 (batch-stages b)))
              (at-25+ (count-if (lambda (s) (>= s 25)) (batch-stages b))))
          (check (format nil "C2b: load-correlated slips past 5% (caught at 5%: ~a, at 25%+: ~a)"
                         at-5 at-25+)
                 (and (>= at-25+ (* 0.9 (batch-caught b))) (< at-5 (* 0.1 *runs*)))
                 nil))))))

;;; ---------------------------------------------------------------------
;;; C7: overhead

(defun ns-per-call (fn-form &key (iterations 500000))
  (let ((f (compile nil fn-form)))
    (sb-ext:gc :full t)
    (let ((start (get-internal-real-time)))
      (funcall f iterations)
      (/ (* (- (get-internal-real-time) start) 1.0e9)
         internal-time-units-per-second iterations))))

(defun check-overhead ()
  (format t "~%--- C7: shim overhead~%")
  (orders:reset-workload)
  (let* ((bench-order (make-instance 'orders:order :id 1 :item-count 3 :unit-price 19.99))
         (plain (ns-per-call `(lambda (n)
                                (let ((o ,bench-order))
                                  (dotimes (i n) (orders:price-order o)))))))
    (let ((ps (orders:register-currency-patch-set)))
      (splice:install ps)
      ;; canary in flight: measure the shim on both routes, inside task scope
      (let* ((shim-old (let ((splice::*task-epochs* (list (list ps :old))))
                         (ns-per-call `(lambda (n)
                                         (let ((o ,bench-order))
                                           (dotimes (i n) (orders:price-order o)))))))
             (shim-new (let ((splice::*task-epochs* (list (list ps :new))))
                         (ns-per-call `(lambda (n)
                                         (let ((o ,(make-instance 'orders:order :id 2
                                                                                :item-count 3 :unit-price 19.99)))
                                           (dotimes (i n) (orders:price-order o))))))))
        (splice:promote ps :operator "criteria")
        (splice:wait-for-state ps '(:promoted) :timeout 30)
        (let ((promoted (ns-per-call `(lambda (n)
                                        (let ((o ,(make-instance 'orders:order :id 3
                                                                               :item-count 3 :unit-price 19.99)))
                                          (dotimes (i n) (orders:price-order o)))))))
          (push (list :plain plain :shim-old shim-old :shim-new shim-new
                      :promoted promoted)
                *report*)
          (format t "plain old: ~,1fns  shim(:old): ~,1fns (~,2fx)  shim(:new): ~,1fns  promoted new: ~,1fns~%"
                  plain shim-old (/ shim-old plain) shim-new promoted)
          (check (format nil "C7: canary shim overhead ~,2fx < 2x plain call"
                         (/ shim-old plain))
                 (< (/ shim-old plain) 2.0) nil))))))

;;; ---------------------------------------------------------------------
;;; C8: operating characteristics
;;; The live evaluator fed synthetic outcome streams through REPORT-OUTCOME,
;;; routed by the production draw. One stage per run, since the budget is a
;;; per-stage promise; a one-stage ramp gives that stage the whole alpha.

(defstruct (traffic (:copier nil))
  (label "" :read-only t)
  (error-rate 0.01d0 :read-only t)
  (error-ratio 1d0 :read-only t)
  (latency-factor 1d0 :read-only t)
  (burst-period 0 :read-only t)
  (burst-length 0 :read-only t)
  (burst-rate 0d0 :read-only t)
  (burst-arms :both :read-only t)
  (harmful nil :read-only t))

(defun oc-traffic-shapes ()
  (list (make-traffic :label "Healthy")
        (make-traffic :label "Healthy, shared bursts"
                      :burst-period 1000 :burst-length 100 :burst-rate 0.1d0)
        (make-traffic :label "Latency 1.1x" :latency-factor 1.1d0 :harmful t)
        (make-traffic :label "Latency 1.2x" :latency-factor 1.2d0 :harmful t)
        (make-traffic :label "Latency 1.3x" :latency-factor 1.3d0 :harmful t)
        (make-traffic :label "Latency 1.5x" :latency-factor 1.5d0 :harmful t)
        (make-traffic :label "Latency 2x" :latency-factor 2d0 :harmful t)
        (make-traffic :label "Errors 1.3x" :error-ratio 1.3d0 :harmful t)
        (make-traffic :label "Errors 2x" :error-ratio 2d0 :harmful t)
        (make-traffic :label "Bursty fault, new arm only"
                      :burst-period 1000 :burst-length 100 :burst-rate 0.1d0
                      :burst-arms :new :harmful t)))

(defun in-burst-p (traffic route task-id)
  (and (plusp (traffic-burst-period traffic))
       (< (mod task-id (traffic-burst-period traffic)) (traffic-burst-length traffic))
       (or (eq (traffic-burst-arms traffic) :both) (eq route :new))))

(defun failure-probability (traffic route task-id)
  (let ((base (if (in-burst-p traffic route task-id)
                  (traffic-burst-rate traffic)
                  (traffic-error-rate traffic))))
    (if (eq route :new)
        (min 1d0 (* base (traffic-error-ratio traffic)))
        base)))

(defun draw-latency-ms (traffic route rng)
  "1ms plus an exponential with mean 1ms, scale on the new arm"
  (let ((base (+ 1d0 (- (log (- 1d0 (orders::rng-uniform rng)))))))
    (if (eq route :new) (* base (traffic-latency-factor traffic)) base)))

(defun oc-probe-set (min-effect)
  "A bar set canarying at *OC-FRACTION*. No shims, so no task runs code"
  (let ((ps (splice::make-patch-set :name 'oc-probe :ramp (list *oc-fraction*)
                                    :min-effect min-effect
                                    :runtime-contract-interval 0
                                    :control-ring (splice::make-control-ring)
                                    :null-ring (splice::make-control-ring
                                                :size splice::*null-ring-size*))))
    (splice::with-set-lock (ps) (splice::enter-stage ps 0))
    ps))

(defun feed-task (ps traffic task-id rng)
  "Route TASK-ID by the production draw and report one synthetic outcome"
  (let ((route (if (< (splice::routing-draw task-id 'oc-probe) *oc-fraction*) :new :old)))
    (splice::report-outcome ps route
                            (< (orders::rng-uniform rng)
                               (failure-probability traffic route task-id))
                            (draw-latency-ms traffic route rng))))

(defun run-oc-stage (traffic seed &key (min-effect 0.3d0))
  "Feed one stage until it reaches a decision point. Returns the point and
the stage's :new observations at it."
  (let ((ps (oc-probe-set min-effect))
        (rng (orders:make-rng seed))
        (point (list :none)))
    (splice:with-operator-decisions
      (handler-bind ((splice:operator-decision
                       (lambda (c)
                         (setf (car point) (splice:operator-decision-point c))
                         (splice:freeze-patch c))))
        (loop for task-id from 1
              until (not (eq (car point) :none))
              do (feed-task ps traffic task-id rng))))
    (values (car point)
            (splice::canary-stage-observations (splice::patch-set-stage ps)))))

(defun measure-traffic (traffic)
  "Run *RUNS* stages of TRAFFIC; returns a row plist."
  (let ((points '()) (detect-ns '()))
    (dotimes (i *runs*)
      (multiple-value-bind (point n) (run-oc-stage traffic (+ 5000 (* 131 i)))
        (push point points)
        (when (eq point :sprt-reject) (push n detect-ns))))
    (list :traffic traffic
          :rejects (count :sprt-reject points)
          :passes (count :budget-pass points)
          :timeouts (count :stage-timeout points)
          :confounded (count :confounded points)
          :median-n (median detect-ns))))

(defun check-operating-characteristics ()
  (format t "~%--- C8: operating characteristics at ~a%, ~a runs per shape~%"
          *oc-fraction* *runs*)
  (setf *oc-rows* '())
  (dolist (traffic (oc-traffic-shapes))
    (push (measure-traffic traffic) *oc-rows*))
  (dolist (row (reverse *oc-rows*))
    (let* ((traffic (getf row :traffic))
           (k (getf row :rejects))
           (ci (wilson-ci k *runs*)))
      (cond ((not (traffic-harmful traffic))
             (check (format nil "C8: ~a false rejects ~a/~a, 95% CI [~,4f, ~,4f] not above alpha"
                            (traffic-label traffic) k *runs* (first ci) (second ci))
                    (<= (first ci) 0.01) nil))
            ((string= "Latency 1.3x" (traffic-label traffic))
             (check (format nil "C8: latency 1.3x rejected ~a/~a, 95% CI [~,4f, ~,4f] reaches 0.95"
                            k *runs* (first ci) (second ci))
                    (>= (second ci) 0.95) nil))))))

(defun write-oc-table (out)
  (format out "~%## Operating Characteristics (C8, One Stage at ~a%, n=~a Runs Each)~%~%"
          *oc-fraction* *runs*)
  (format out "| Traffic | Rejected | Passed | Timed Out | Confounded | Median New-Arm n to Reject |~%|---|---|---|---|---|---|~%")
  (dolist (row (reverse *oc-rows*))
    (format out "| ~a | ~a | ~a | ~a | ~a | ~a |~%"
            (traffic-label (getf row :traffic))
            (getf row :rejects) (getf row :passes) (getf row :timeouts)
            (getf row :confounded)
            (or (getf row :median-n) "N/A"))))

;;; ---------------------------------------------------------------------
;;; Report

(defun report-commit ()
  "Short commit of splice's checkout, with -dirty when it has changes, or \"unknown\""
  (handler-case
      (string-trim '(#\Newline #\Space)
                   (uiop:run-program (list "git" "-C" (namestring (root))
                                           "describe" "--always" "--dirty" "--abbrev=7")
                                     :output :string))
    (error () "unknown")))

(defun write-report ()
  (with-open-file (out (ensure-directories-exist
                        (merge-pathnames "artifacts/criteria-report.md" (root)))
                       :direction :output :if-exists :supersede)
    (format out "# Criteria Report~%~%")
    (format out "Generated by `test/criteria.lisp` (~a runs per class) on ~a, ~a.~%~%"
            *runs* (lisp-implementation-type) (lisp-implementation-version))
    (format out "Commit ~a, written ~a.~%~%" (report-commit) (splice::timestamp-string))
    (format out "## Verdicts~%~%")
    (format out "| Criterion | Result |~%|---|---|~%")
    (dolist (entry (reverse *report*))
      (when (and (listp entry) (= 3 (length entry)) (stringp (first entry)))
        (format out "| ~a | ~:[**FAIL**~;Pass~] |~%"
                (substitute #\space #\newline (first entry)) (second entry))))
    (format out "~%## Fault-Class Detection (n=~a Runs Each)~%~%" *runs*)
    (format out "| Fault | Caught | Median SPRT n | Median Tasks to Decision | Stages Caught At |~%|---|---|---|---|---|~%")
    (dolist (kb (reverse *batches*))
      (destructuring-bind (kind . b) kb
        (format out "| ~a | ~a/~a | ~a | ~a | ~a |~%"
                (or kind :clean) (batch-caught b) (batch-runs b)
                (or (median (batch-detect-ns b)) "N/A")
                (or (median (batch-detect-tasks b)) "N/A")
                (let ((s (remove-duplicates (batch-stages b))))
                  (if s (format nil "~{~a%~^, ~}" (sort s #'<)) "N/A")))))
    (write-oc-table out)
    (let ((oh (find-if (lambda (e) (and (listp e) (eq (first e) :plain))) *report*)))
      (when oh
        (format out "~%## Overhead (C7)~%~%")
        (format out "| Path | ns/call |~%|---|---|~%")
        (format out "| Plain (pre-patch) | ~,1f |~%| Shim, :old route | ~,1f (~,2fx) |~%| Shim, :new route | ~,1f |~%| Promoted (shim gone) | ~,1f |~%"
                (getf oh :plain) (getf oh :shim-old)
                (/ (getf oh :shim-old) (getf oh :plain))
                (getf oh :shim-new) (getf oh :promoted))))
    (format out "~%## Outcome~%~%~:[**~a criteria FAILED**~;All criteria passed.~]~%"
            (null *failures*) (length *failures*))))

;;; ---------------------------------------------------------------------
;;; Entry point

(defun run-criteria (&key (runs (default-runs)))
  "Run every criterion in order, write artifacts/criteria-report.md, and
return T when all pass. Each criterion is a measurement that moves with chance
or with the machine; the claims that don't are tests in splice-orders/tests
and splice/integration-tests."
  (let ((*runs* runs)
        (*failures* '())
        (*report* '())
        (*batches* '())
        (*big-log* (fresh-scratch-log "splice-criteria.log")))
    (format t "~%=== splice criteria runner (~a runs per class) ===~%" *runs*)
    (splice:open-audit-log *big-log*)
    (orders:reset-workload)
    (format t "~%--- C2/C6: ~a-run batches per class~%" *runs*)
    (check-clean-batch)
    (check-fault-batches)
    (check-overhead)
    (splice:close-audit-log)
    (check-operating-characteristics)
    (write-report)
    (format t "~%=== ~:[~a FAILURES~;all criteria passed~]; report: artifacts/criteria-report.md ===~%"
            (null *failures*) (length *failures*))
    (null *failures*)))
