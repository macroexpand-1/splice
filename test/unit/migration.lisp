;;;; migration.lisp: slot specs and class shapes, the pure end of class
;;;; migration.

(in-package #:splice-tests)

(def-suite migration :in splice-tests)
(in-suite migration)

(defparameter *migrant-slots*
  '((dollars :initarg :dollars)
    (status :initarg :status :initform :new)
    (note))
  "MIGRANT's original direct slots. Every migration test starts from them.")

(defclass shape-base () ())
(defclass shape-probe (shape-base)
  ((p :initarg :p :reader p-of)
   (q :initform 5 :accessor q-of)
   (r)))

(defun names-of (specs)
  (mapcar (lambda (spec) (getf spec :name)) specs))

(defun spec-named (name specs)
  (find name specs :key (lambda (spec) (getf spec :name))))

;;; ---------------------------------------------------------------------
;;; Slot specs

(test a-bare-symbol-is-a-slot-with-defaults
  (is (equal '(:name x :initform nil :initfunction nil :initargs () :readers ()
               :writers () :type t)
             (splice::canonicalize-slot-spec 'x))))

(test every-option-lands-in-the-canonical-plist
  (let ((spec (splice::canonicalize-slot-spec
               '(x :initform (+ 1 2) :initarg :x :initarg :ex
                   :accessor x-of :type integer))))
    (is (eq 'x (getf spec :name)))
    (is (equal '(+ 1 2) (getf spec :initform)))
    (is (= 3 (funcall (getf spec :initfunction))))
    (is (equal '(:x :ex) (getf spec :initargs)))
    (is (equal '(x-of) (getf spec :readers)))
    (is (equal '((setf x-of)) (getf spec :writers)))
    (is (eq 'integer (getf spec :type)))))

(test readers-and-writers-accumulate-in-order
  (let ((spec (splice::canonicalize-slot-spec
               '(x :reader r1 :reader r2 :writer w1))))
    (is (equal '(r1 r2) (getf spec :readers)))
    (is (equal '(w1) (getf spec :writers)))))

;;; ---------------------------------------------------------------------
;;; Union and final shapes

(defun class-patch-over-old (&key add drop)
  (splice::make-class-patch
   :class-name 'shape-probe
   :old-slot-specs (mapcar #'splice::canonicalize-slot-spec '(a (b :initform 1)))
   :add-slots add
   :drop-slots drop))

(test the-union-adds-new-slots-and-keeps-dropped-ones
  (let ((cp (class-patch-over-old :add '(c) :drop '(b))))
    (is (equal '(a b c) (names-of (splice::class-patch-union-slots cp))))))

(test the-final-shape-drops-slots
  (let ((cp (class-patch-over-old :add '(c) :drop '(b))))
    (is (equal '(a c) (names-of (splice::class-patch-final-slots cp))))))

(test an-added-slot-never-replaces-an-old-one
  (let* ((cp (class-patch-over-old :add '((b :initform 99) c)))
         (union (splice::class-patch-union-slots cp)))
    (is (equal '(a b c) (names-of union)))
    (is (eql 1 (getf (spec-named 'b union) :initform)))))

;;; ---------------------------------------------------------------------
;;; Capturing a live class

(test capture-class-shape-reads-the-direct-slots
  (multiple-value-bind (slots supers) (splice::capture-class-shape 'shape-probe)
    (is (equal '(p q r) (names-of slots)))
    (is (equal '(shape-base) supers))
    (is (equal '(:p) (getf (spec-named 'p slots) :initargs)))
    (is (equal '(p-of) (getf (spec-named 'p slots) :readers)))
    (is (eql 5 (getf (spec-named 'q slots) :initform)))
    (is (equal '((setf q-of)) (getf (spec-named 'q slots) :writers)))))

(test slot-states-record-unbound-slots
  (let* ((instance (make-instance 'shape-probe :p 1))
         (states (splice::slot-states instance
                                      (splice::capture-class-shape 'shape-probe))))
    (is (equal '((p :bound 1) (q :bound 5) (r :unbound)) states))
    (is (equal '(p 1 q 5) (splice::bound-values states)))))

;;; ---------------------------------------------------------------------
;;; A class to migrate
;;; The tests redefine MIGRANT, so each one starts by putting it back.

(defun reset-migrant ()
  "Give MIGRANT its original shape, whatever the last test left it with."
  (sb-mop:ensure-class 'migrant
                       :direct-superclasses '(standard-object)
                       :direct-slots (mapcar #'splice::canonicalize-slot-spec
                                             *migrant-slots*)))

(defmacro with-migration-tables (&body body)
  "Run BODY against a fresh migration state, with MIGRANT in its original shape."
  `(let ((splice::*migration-state* (splice::make-migration-state)))
     (reset-migrant)
     ,@body))

(defun direct-slot-names (class-name)
  (mapcar #'sb-mop:slot-definition-name
          (sb-mop:class-direct-slots (find-class class-name))))

(defun dollars-to-cents (instance old-values)
  "The forward migration: CENTS from the old DOLLARS."
  (setf (slot-value instance 'cents) (* 100 (getf old-values 'dollars 0))))

(defun cents-to-dollars (instance new-values)
  "The backward migration: DOLLARS from the discarded CENTS."
  (setf (slot-value instance 'dollars) (/ (getf new-values 'cents 0) 100)))

(defun dollars-to-cents-noting (instance old-values)
  "A forward migration that also writes the old NOTE slot."
  (dollars-to-cents instance old-values)
  (setf (slot-value instance 'note) :migrated))

(defun refuse-migration (instance values)
  (declare (ignore instance values))
  (error "probe migration refused"))

(defun refuse-first-migration ()
  "A backward migration that fails on its first call, as a traffic thread's
touch might, and synthesizes DOLLARS on every later one."
  (let ((calls 0))
    (lambda (instance new-values)
      (when (= 1 (incf calls))
        (error "probe migration refused"))
      (cents-to-dollars instance new-values))))

(defun migrant-patch (&key (add '((cents :initform 0))) (drop '(dollars))
                        (forward #'dollars-to-cents) (backward #'cents-to-dollars))
  "A class patch on MIGRANT, dollars to cents unless told otherwise."
  (splice::make-class-patch :class-name 'migrant :add-slots add :drop-slots drop
                            :migrate-forward forward :migrate-backward backward))

(defun migrant-set (name cp)
  "An unregistered patch set holding CP, with MIGRANT's current shape captured
as registration captures it."
  (let ((ps (splice::make-patch-set :name name :class-patches (list cp))))
    (splice::capture-old-class ps cp)
    ps))

(defun make-migrant-routed (ps route &rest initargs)
  "A MIGRANT made inside a task pinned to ROUTE for PS."
  (let ((splice::*task-epochs* (list (list ps route))))
    (apply #'make-instance 'migrant initargs)))

(defun open-backward-window (ps cp)
  "Take the first two steps of ROLLBACK-CLASS-PATCH: file PS's entry for CP's
class as :backward and put its original shape back. A touch now lands where a
traffic thread's touch would during a rollback."
  (splice::file-entry (splice::entry-in-phase (splice::entry-of ps cp) :backward))
  (splice::apply-class-shape 'migrant
                             (splice::class-patch-old-slot-specs cp)
                             (splice::class-patch-old-superclass-names cp)))

(defun stop-audit-log ()
  "Mark the open log as stopped by a failed write, as a full disk would."
  (setf (splice::audit-log-failure splice:*audit-log*)
        (make-condition 'simple-error :format-control "probe write failure")))

;;; ---------------------------------------------------------------------
;;; Class migration on one thread
;;; Each test drives the phase functions itself, against empty tables.

(test a-pre-existing-instance-migrates-forward-on-first-touch
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'forward-probe cp)))
      (splice::begin-class-canary ps cp)
      (is (eql 2000 (slot-value o 'cents)))
      (is (eql 20 (slot-value o 'dollars)))
      (is (= 1 (splice:migration-journal-count 'forward-probe))))))

(test rollback-restores-the-original-shape
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'shape-probe-set cp)))
      (splice::begin-class-canary ps cp)
      (slot-value o 'cents)
      (splice::rollback-class-patch ps cp)
      (is (equal '(dollars status note) (direct-slot-names 'migrant)))
      (is (eql 20 (slot-value o 'dollars)))
      (is-false (slot-exists-p o 'cents))
      (is (= 0 (splice:migration-journal-count 'shape-probe-set))))))

(test rollback-reverses-each-kind-of-instance
  (with-migration-tables
    (let* ((touched (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'kinds-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value touched 'cents)
      (let ((new-born (make-migrant-routed ps :new))
            (old-born (make-migrant-routed ps :old :dollars 7)))
        (setf (slot-value new-born 'cents) 1500)
        (is (equal '(:journal-exact 1 :synthesized 1 :old-born-unchanged 1
                     :untouched 0 :failed 0 :slots-undone 0)
                   (splice::rollback-class-patch ps cp)))
        (is (eql 15 (slot-value new-born 'dollars)))
        (is (eql 7 (slot-value old-born 'dollars)))))))

(test promotion-applies-the-final-shape-and-keeps-the-journal
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'promote-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value o 'cents)
      (splice::promote-class-patch ps cp)
      (is (equal '(status note cents) (direct-slot-names 'migrant)))
      (is (eql 2000 (slot-value o 'cents)))
      (is-false (slot-exists-p o 'dollars))
      (is (= 1 (splice:migration-journal-count 'promote-probe))))))

(test sealing-releases-the-journal
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'seal-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value o 'cents)
      (splice::promote-class-patch ps cp)
      (is (= 1 (splice::seal-class-journal ps)))
      (is (= 0 (splice:migration-journal-count 'seal-probe))))))

(test a-failed-forward-migration-arms-the-hard-trigger
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch :forward #'refuse-migration))
           (ps (migrant-set 'forward-failure-probe cp)))
      (splice::begin-class-canary ps cp)
      (signals splice::migration-failure (slot-value o 'cents))
      (is (eq :migration-failure (first (splice::patch-set-hard-trigger ps)))))))

(test a-failed-backward-migration-fails-the-rollback
  (with-migration-tables
    (let* ((cp (migrant-patch :backward #'refuse-migration))
           (ps (migrant-set 'backward-failure-probe cp)))
      (splice::begin-class-canary ps cp)
      (make-migrant-routed ps :new)
      (signals splice::rollback-failure (splice::rollback-class-patch ps cp)))))

(test rolling-back-one-set-keeps-another-sets-journal
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp-a (migrant-patch))
           (a (migrant-set 'set-a cp-a)))
      (splice::begin-class-canary a cp-a)
      (slot-value o 'cents)
      (splice::promote-class-patch a cp-a)
      (let* ((cp-b (migrant-patch :add '((memo :initform :none)) :drop '()
                                  :forward nil :backward nil))
             (b (migrant-set 'set-b cp-b)))
        (splice::begin-class-canary b cp-b)
        (slot-value o 'memo)
        (splice::rollback-class-patch b cp-b)
        (is (= 1 (splice:migration-journal-count 'set-a)))
        (is (= 0 (splice:migration-journal-count 'set-b)))))))

(test an-untouched-instance-is-left-alone-in-the-rollback-window
  (with-migration-tables
    (let* ((untouched (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'untouched-probe cp)))
      (splice::begin-class-canary ps cp)
      (open-backward-window ps cp)
      (is (eql 20 (slot-value untouched 'dollars)))
      (is (= 1 (getf (splice::rollback-class-patch ps cp) :untouched))))))

(test rollback-unbinds-a-slot-forward-migration-bound
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20))
           (cp (migrant-patch :forward #'dollars-to-cents-noting))
           (ps (migrant-set 'unbound-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value o 'cents)
      (splice::rollback-class-patch ps cp)
      (is-false (slot-boundp o 'note)))))

(test rollback-keeps-old-code-writes
  (with-migration-tables
    (let* ((o (make-instance 'migrant :dollars 20 :status :priced))
           (cp (migrant-patch))
           (ps (migrant-set 'old-write-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value o 'cents)
      ;; an old-routed task invoices the order under the union shape
      (setf (slot-value o 'dollars) 18
            (slot-value o 'status) :invoiced)
      (is (= 0 (getf (splice::rollback-class-patch ps cp) :slots-undone)))
      (is (eql 18 (slot-value o 'dollars)))
      (is (eq :invoiced (slot-value o 'status))))))

(test a-backward-failure-on-a-traffic-thread-fails-the-rollback
  (with-migration-tables
    (let* ((cp (migrant-patch :backward (refuse-first-migration)))
           (ps (migrant-set 'traffic-failure-probe cp)))
      (splice::begin-class-canary ps cp)
      (let ((born (make-migrant-routed ps :new)))
        (open-backward-window ps cp)
        ;; a traffic thread touches it first and gets the failure
        (signals splice::migration-failure (slot-value born 'dollars))
        (signals splice::rollback-failure (splice::rollback-class-patch ps cp))))))

(test a-forward-failure-with-a-stopped-log-arms-and-signals
  (with-audit-log (path)
    (with-migration-tables
      (let* ((o (make-instance 'migrant :dollars 20))
             (cp (migrant-patch :forward #'refuse-migration))
             (ps (migrant-set 'stopped-log-probe cp)))
        (splice::begin-class-canary ps cp)
        (stop-audit-log)
        (signals splice::migration-failure (slot-value o 'cents))
        (is (eq :migration-failure (first (splice::patch-set-hard-trigger ps))))))))

(test rollback-undoes-a-slot-only-forward-migration-wrote
  (with-migration-tables
    (let* ((kept (make-instance 'migrant :dollars 20))
           (undone (make-instance 'migrant :dollars 30))
           (cp (migrant-patch :forward #'dollars-to-cents-noting))
           (ps (migrant-set 'undo-probe cp)))
      (splice::begin-class-canary ps cp)
      (slot-value kept 'cents)
      (slot-value undone 'cents)
      ;; old code writes one note after forward migration set both
      (setf (slot-value kept 'note) :later)
      (is (= 1 (getf (splice::rollback-class-patch ps cp) :slots-undone)))
      (is (eq :later (slot-value kept 'note)))
      (is-false (slot-boundp undone 'note)))))

;;; ---------------------------------------------------------------------
;;; Pinned defects
;;; Each test asserts today's wrong behavior; the guide named in its
;;; docstring rewrites it.

(defclass shared-probe ()
  ((tally :allocation :class :initform 0)
   (label :documentation "A label.")))

(test capture-drops-allocation-and-documentation
  "Pins T14. Guide 03 (03-shape-fidelity.md) rewrites it."
  (let ((slots (splice::capture-class-shape 'shared-probe)))
    (is (null (getf (spec-named 'tally slots) :allocation)))
    (is (null (getf (spec-named 'label slots) :documentation)))))

(test canonicalizing-documentation-signals
  "Pins T25: the option ECASE knows no :DOCUMENTATION. Guide 03 rewrites it."
  (signals type-error
    (splice::canonicalize-slot-spec '(x :documentation "An x."))))

(test each-union-compiles-a-fresh-initfunction
  "Pins T68. Guide 03 rewrites it."
  (let ((cp (class-patch-over-old :add '((c :initform 3)))))
    (is-false (eq (getf (spec-named 'c (splice::class-patch-union-slots cp))
                        :initfunction)
                  (getf (spec-named 'c (splice::class-patch-union-slots cp))
                        :initfunction)))))

(test dropping-and-re-adding-a-slot-loses-it
  "Pins T131. Guide 03 rewrites it."
  (let ((cp (class-patch-over-old :add '((b :initform 99)) :drop '(b))))
    (is (equal '(a) (names-of (splice::class-patch-final-slots cp))))))

(test a-class-with-subclasses-is-not-vetoed
  "Pins T4: decision 0004's veto is not built. Guide 03 rewrites it."
  (let* ((cp (splice::make-class-patch :class-name 'shape-base :add-slots '(extra)))
         (ps (splice::make-patch-set :name 'subclass-probe :class-patches (list cp))))
    (is (eq :no-veto (veto-of (lambda () (splice::capture-old-class ps cp)))))))

(test the-class-tables-are-unsynchronized
  "Pins T66: read on hot paths while install threads write them. Guide 03
rewrites it."
  (is-false (sb-ext:hash-table-synchronized-p
             (splice::migration-state-registry splice::*migration-state*)))
  (is-false (sb-ext:hash-table-synchronized-p splice::*shim-factories*)))

(test promotion-leaves-an-untouched-instance-unmigrated
  "Pins T2: the registry entry goes at promotion, so a later first touch
skips :migrate-forward. Guide 04 (04-after-promotion.md) rewrites it."
  (with-migration-tables
    (let* ((untouched (make-instance 'migrant :dollars 20))
           (cp (migrant-patch))
           (ps (migrant-set 'straggler-probe cp)))
      (splice::begin-class-canary ps cp)
      (splice::promote-class-patch ps cp)
      (is (eql 0 (slot-value untouched 'cents))))))

(test the-forward-audit-records-pre-state-values
  "Pins T67's audit half: application data lands in the log. Guide 04
rewrites it."
  (with-audit-log (path)
    (with-migration-tables
      (let* ((o (make-instance 'migrant :dollars 20))
             (cp (migrant-patch))
             (ps (migrant-set 'audit-probe cp)))
        (splice::begin-class-canary ps cp)
        (slot-value o 'cents)
        (let ((entry (find :instance-migration (log-entries path)
                           :key (lambda (e) (getf e :event)))))
          (is (member 20 (getf entry :pre-state))))))))
