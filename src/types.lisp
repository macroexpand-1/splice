;;;; types.lisp: patch-set structs, the registry, and lifecycle-state
;;;; predicates.

(in-package #:splice)

;;; ---------------------------------------------------------------------
;;; Structs and registry

(defstruct fn-patch
  (name nil :read-only t)            ; symbol naming the function
  (new-fn nil :read-only t)          ; compiled new implementation
  (new-source nil :read-only t)      ; source form of the new implementation (for the audit log)
  (new-source-hash nil :read-only t)
  ;; mutable
  old-fn          ; captured original fdefinition (in case of rollback)
  old-source-hash ; hash of the original's identity (printed repr)
  shim)           ; installed dispatch shim, while in canary

(defstruct method-patch
  (gf-name nil :read-only t)
  (qualifiers nil :read-only t)
  (specializer-names nil :read-only t)
  (new-fn nil :read-only t)
  (new-source nil :read-only t)
  (new-source-hash nil :read-only t)
  ;; mutable
  old-method      ; captured method object (add-method'd back on rollback)
  shim-method)    ; installed routing method, while in canary

(defstruct class-patch
  (class-name nil :read-only t)
  (add-slots nil :read-only t)        ; defclass-style slot specs to add
  (drop-slots nil :read-only t)       ; slot names dropped by the new shape (retained during canary)
  (migrate-forward nil :read-only t)  ; (instance old-values-plist) -> populates new slots
  (migrate-backward nil :read-only t) ; (instance new-values-plist) -> synthesizes old slots
  (lossy-p nil :read-only t)          ; author declares reversal lossy => rollback needs a human
  ;; mutable
  old-slot-specs  ; captured canonicalized direct-slot specs of the original
  old-superclass-names)

(defstruct contract
  (name nil :read-only t)
  (check-fn nil :read-only t)
  (source nil :read-only t))

(defstruct (patch-set (:print-object print-patch-set))
  name description ticket
  fn-patches method-patches class-patches contracts
  (ramp '(5 25 100))
  (state :registered)
  (current-fraction 0)
  (stage-index -1)                     ; index into RAMP; -1 = not yet canarying
  (lock (sb-thread:make-mutex))
  (paired-fallback nil)                 ; opt-in
  (alpha 0.01d0) (beta 0.05d0)
  (min-effect 0.3d0)
  (stage-limit 40000)
  (stage :none)
  control-ring
  (confound-threshold 0.15)          ; control failure rate above this => FROZEN
  (runtime-contract-interval 200)    ; run contracts every N canary observations
  (pinned-new 0) (pinned-old 0)      ; in-flight task counts, per route
  (hard-trigger :unarmed)            ; set by anomaly capture; forces rollback
  (history '())                  ; (state . timestamp) transitions, newest first
  (freeze-reason nil)
  (last-reversal-report :not-rolled-back) ; reversal counts from the last rollback
  (sealed nil))               ; journal released; rollback no longer offered

(defvar *patch-sets* (make-hash-table :test #'eq #+sbcl :synchronized #+sbcl t)
  "Registry of every patch set this image has seen, terminal states included.")

(defvar *deferred-effects*)             ; unbound outside WITH-SET-LOCK, so stray DEFER errors

(defun print-patch-set (ps stream)
  (print-unreadable-object (ps stream :type t)
    (format stream "~a ~a ~a%" (patch-set-name ps) (patch-set-state ps)
            (patch-set-current-fraction ps))))

(defun find-patch-set (name)
  (gethash name *patch-sets*))

(defun resolve-patch-set (name-or-ps)
  "The patch set NAME-OR-PS names. Signals UNKNOWN-PATCH-SET for a name
nothing registered"
  (cond ((patch-set-p name-or-ps) name-or-ps)
        ((find-patch-set name-or-ps))
        (t (error 'unknown-patch-set :name name-or-ps))))

;;; ---------------------------------------------------------------------
;;; Lifecycle state

(defun stage-keyword (fraction)
  (intern (format nil "CANARY-~d" fraction) :keyword))

(defun arm-hard-trigger (ps trigger)
  "Arm PS's hard trigger unless one is already armed; the first cause wins."
  (sb-ext:compare-and-swap (patch-set-hard-trigger ps) :unarmed trigger))

(defun take-hard-trigger (ps)
  "PS's armed trigger or :UNARMED, leaving the slot :UNARMED"
  (loop for seen = (patch-set-hard-trigger ps)
        when (or (eq seen :unarmed)
                 (eq seen (sb-ext:compare-and-swap (patch-set-hard-trigger ps)
                                                   seen :unarmed)))
          return seen))

(defun canary-stage-p (state)
  (let ((s (symbol-name state)))
    (and (> (length s) 7) (string= "CANARY-" (subseq s 0 7)))))

;; Rollback and promotion each take two states: the first until the drain
;; ends (a freeze can still stop it), the second once the completion thread
;; has claimed the set and started changing code.
(defun rolling-back-p (state)
  (member state '(:rolling-back :restoring)))

(defun promoting-p (state)
  (member state '(:promoting :swapping)))

(defun active-canary-sets ()
  "Patch sets that fresh tasks must pin against: canary stages, plus
promoting ones (pin :new across the swap) and rolling-back or :frozen ones
(pin :old)."
  (let ((out '()))
    (maphash (lambda (name ps)
               (declare (ignore name))
               (when (or (canary-stage-p (patch-set-state ps))
                         (rolling-back-p (patch-set-state ps))
                         (promoting-p (patch-set-state ps))
                         (eq :frozen (patch-set-state ps)))
                 (push ps out)))
             *patch-sets*)
    out))

;;; ---------------------------------------------------------------------
;;; Set lock

(defun defer (thunk)
  "Run THUNK once the enclosing WITH-SET-LOCK releases"
  (push thunk *deferred-effects*))

(defmacro with-set-lock ((ps) &body body)
  "BODY under PS's lock, then deferred effects (in order) after release."
  `(let ((*deferred-effects* '()))
     (multiple-value-prog1
         (sb-thread:with-mutex ((patch-set-lock ,ps)) ,@body)
       (mapc #'funcall (reverse *deferred-effects*)))))
