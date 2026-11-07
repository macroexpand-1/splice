;;;; decisions.lisp: the operator restarts at canary decision points,
;;;; without a live set. The live-set cases are in integration/decisions.lisp.

(in-package #:splice-tests)

(def-suite operator-decisions :in splice-tests)
(in-suite operator-decisions)

(test the-restart-functions-need-an-open-decision
  (signals control-error (splice:roll-back-patch))
  (signals control-error (splice:freeze-patch))
  (signals control-error (splice:promote-anyway))
  (signals control-error (splice:let-splice-decide)))

(test a-lossy-set-s-rollback-default-is-a-freeze
  (let ((lossy (splice::make-patch-set
                :name 'lossy-probe
                :class-patches (list (splice::make-class-patch :class-name 'nothing
                                                               :lossy-p t))))
        (plain (splice::make-patch-set :name 'plain-probe)))
    (is (equal '(:freeze (:lossy-reversal-needs-human :trigger (:sprt-reject)))
               (multiple-value-list (splice::rollback-default lossy '(:sprt-reject)))))
    (is (equal '(:roll-back (:sprt-reject))
               (multiple-value-list (splice::rollback-default plain '(:sprt-reject)))))))
