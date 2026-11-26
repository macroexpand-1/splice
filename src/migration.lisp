;;;; migration.lisp: reversible class redefinition.
;;;; During canary the class has the UNION shape (old + new slots) so old code
;;;; stays correct; promotion applies the final shape, rollback the original.
;;;; Forward migration journals each instance's pre-state for an exact
;;;; reversal. Canary-born instances get author-defined backward synthesis.

(in-package #:splice)

;;; ---------------------------------------------------------------------
;;; Migration state
;;; One bundle holds everything class migration tracks. Tables use strong
;;; keys: SBCL 2.2.9 weak tables corrupt ("Corrupt NEXT-chain") under GC
;;; pressure even when mutex-guarded. Ledger tables change only under LOCK.

(defstruct (journal-record (:copier nil))
  "An instance's old slots just before and just after the :migrate-forward ran.
Each is a list of slot states: (name :bound values) or (name :unbound)"
  (seq 0 :read-only t)
  (before '() :read-only t)
  (after '() :read-only t))

(defstruct (reversal (:copier nil))
  "How the instance came back at rollback. KIND is one of the following:
:journal-exact, :synthesized, :old-born-unchanged, :untouched, or :failed.
CAUSE is the error"
  (kind :untouched :read-only t)
  (slots-undone 0 :read-only t)
  (cause :none :read-only t))

(defstruct (class-ledger (:copier nil))
  "What a patch set recorded about a class. Keeps a JOURNAL, a BIRTHS record,
and OUTCOMES of the migration. The tables change in place"
  (set-name nil :read-only t)
  (class-name nil :read-only t)
  (journal (make-hash-table :test #'eq) :read-only t)   ; instance => journal-record
  (births (make-hash-table :test #'eq) :read-only t)    ; instance => routes that made it
  (outcomes (make-hash-table :test #'eq) :read-only t)) ; instance => reversal

(defstruct (migration-entry (:copier nil))
  "A class patch in flight: the set that owns it, the ledger it writes, and
what touching an obsolete instance does. PHASE is :forward, :backward or
:finalize; a phase change files a new entry. Every slot is required."
  (class-patch (error "migration-entry needs :class-patch") :read-only t)
  (patch-set (error "migration-entry needs :patch-set") :read-only t)
  (ledger (error "migration-entry needs :ledger") :read-only t)
  (phase (error "migration-entry needs :phase") :read-only t))

(defstruct (migration-state (:copier nil))
  "Everything class migration tracks. The ledger outlives the entry until
a rollback or sealing"
  (lock (sb-thread:make-mutex :name "splice migration") :read-only t)
  (registry (make-hash-table :test #'eq) :read-only t)   ; class name => migration entry (in-flight)
  (ledgers (make-hash-table :test #'equal) :read-only t) ; (set-name . class-name) => class-ledger
  ;; mutable
  (journal-seq 0))

(defvar *migration-state* (make-migration-state)
  "The image's class migration status. The global methods that read it are:
UPDATE-INSTANCE-FOR-REDEFINED-CLASS and INITIALIZE-INSTANCE")

(defmacro with-migration-lock (&body body)
  `(sb-thread:with-mutex ((migration-state-lock *migration-state*))
     ,@body))

;;; ---------------------------------------------------------------------
;;; Capturing and rebuilding class shapes via the MOP

(defun canonicalize-slot-spec (spec)
  "defclass-style slot spec -> ensure-class canonical plist."
  (destructuring-bind (name &rest opts) (if (listp spec) spec (list spec))
    (let ((initform nil) (initfunction nil) (initargs '())
          (readers '()) (writers '()) (type t))
      (loop for (key val) on opts by #'cddr
            do (ecase key
                 (:initform (setf initform val
                                  initfunction (compile nil `(lambda () ,val))))
                 (:initarg (push val initargs))
                 (:reader (push val readers))
                 (:writer (push val writers))
                 (:accessor (push val readers)
                  (push `(setf ,val) writers))
                 (:type (setf type val))))
      (list :name name :initform initform :initfunction initfunction
            :initargs (nreverse initargs) :readers (nreverse readers)
            :writers (nreverse writers) :type type))))

(defun capture-class-shape (class-name)
  "Current direct-slot specs and superclass names: what rollback restores."
  (let ((class (find-class class-name)))
    (sb-mop:finalize-inheritance class)
    (values
     (mapcar (lambda (sd)
               (list :name (sb-mop:slot-definition-name sd)
                     :initform (sb-mop:slot-definition-initform sd)
                     :initfunction (sb-mop:slot-definition-initfunction sd)
                     :initargs (sb-mop:slot-definition-initargs sd)
                     :readers (sb-mop:slot-definition-readers sd)
                     :writers (sb-mop:slot-definition-writers sd)
                     :type (sb-mop:slot-definition-type sd)))
             (sb-mop:class-direct-slots class))
     (mapcar #'class-name (sb-mop:class-direct-superclasses class)))))

(defun apply-class-shape (class-name slot-specs superclass-names)
  (sb-mop:ensure-class class-name
                       :direct-superclasses superclass-names
                       :direct-slots slot-specs
                       :metaclass (class-of (find-class class-name))))

(defun class-patch-union-slots (cp)
  "Old slots plus added ones; dropped slots stay until promotion."
  (append (class-patch-old-slot-specs cp)
          (remove-if (lambda (spec)
                       (find (getf spec :name)
                             (class-patch-old-slot-specs cp)
                             :key (lambda (s) (getf s :name))))
                     (mapcar #'canonicalize-slot-spec
                             (class-patch-add-slots cp)))))

(defun class-patch-final-slots (cp)
  "Old slots − dropped + added: the shape promotion makes permanent."
  (append (remove-if (lambda (spec)
                       (member (getf spec :name) (class-patch-drop-slots cp)))
                     (class-patch-old-slot-specs cp))
          (remove-if (lambda (spec)
                       (find (getf spec :name)
                             (class-patch-old-slot-specs cp)
                             :key (lambda (s) (getf s :name))))
                     (mapcar #'canonicalize-slot-spec
                             (class-patch-add-slots cp)))))

(defun slot-state (instance name)
  (if (slot-boundp instance name)
      (list name :bound (slot-value instance name))
      (list name :unbound)))

(defun slot-states (instance slot-specs)
  "State of each slot in SLOT-SPECS (in order)"
  (mapcar (lambda (spec) (slot-state instance (getf spec :name))) slot-specs))

(defun bound-values (states)
  "The plist of STATES' bound slots. :migrate-forward receives these"
  (loop for (name kind value) in states
        when (eq kind :bound)
          append (list name value)))

(defun same-slot-state-p (a b)
  (and (eq (second a) (second b))
       (eql (third a) (third b))))

(defun restore-slot-state (instance state)
  (destructuring-bind (name kind &optional value) state
    (ecase kind
      (:bound (setf (slot-value instance name) value))
      (:unbound (slot-makunbound instance name)))))

;;; ---------------------------------------------------------------------
;;; Ledgers and the registry

(defun ledger-key (set-name class-name)
  (cons set-name class-name))

(defun ledger-named (set-name class-name)
  "Ledger for SET-NAME and CLASS-NAME or :NONE"
  (with-migration-lock
    (gethash (ledger-key set-name class-name)
             (migration-state-ledgers *migration-state*) :none)))

(defun ledger-of (ps cp)
  "PS's ledger for CP's class or :NONE"
  (ledger-named (patch-set-name ps) (class-patch-class-name cp)))

(defun open-ledger (ps cp)
  "File a fresh ledger for PS + CP's class. Return it"
  (let ((ledger (make-class-ledger :set-name (patch-set-name ps)
                                   :class-name (class-patch-class-name cp))))
    (with-migration-lock
      (setf (gethash (ledger-key (patch-set-name ps) (class-patch-class-name cp))
                     (migration-state-ledgers *migration-state*))
            ledger))
    ledger))

(defun close-ledger (ledger)
  "Drop LEDGER from state and empty its tables (releasing everything)
Returns how many journal records it held"
  (with-migration-lock
    (remhash (ledger-key (class-ledger-set-name ledger)
                         (class-ledger-class-name ledger))
             (migration-state-ledgers *migration-state*))
    (prog1 (hash-table-count (class-ledger-journal ledger))
      (clrhash (class-ledger-journal ledger))
      (clrhash (class-ledger-births ledger))
      (clrhash (class-ledger-outcomes ledger)))))

(defun release-births (ledger)
  (with-migration-lock
    (clrhash (class-ledger-births ledger))))

(defun ledger-instances (ledger)
  "Every instance LEDGER journed or saw born. Unique"
  (with-migration-lock
    (let ((journal (class-ledger-journal ledger)))
      (append (loop for instance being the hash-keys of journal
                    collect instance)
              (loop for instance being the hash-keys of (class-ledger-births ledger)
                    unless (nth-value 1 (gethash instance journal))
                      collect instance)))))

(defun entry-for-class (class-name)
  "Migration entry for CLASS-NAME or :UNTRACKED"
  (gethash class-name (migration-state-registry *migration-state*) :untracked))

(defun entry-of (ps cp)
  "PS's migration entry for CP's class. Signals when the class has no entry or another set's"
  (let ((entry (entry-for-class (class-patch-class-name cp))))
    (unless (and (migration-entry-p entry)
                 (eq ps (migration-entry-patch-set entry)))
      (error "~a holds no migration entry for ~a"
             (patch-set-name ps) (class-patch-class-name cp)))
    entry))

(defun file-entry (entry)
  (setf (gethash (class-patch-class-name (migration-entry-class-patch entry))
                 (migration-state-registry *migration-state*))
        entry))

(defun entry-in-phase (entry phase)
  "Copy of ENTRY in PHASE"
  (make-migration-entry :class-patch (migration-entry-class-patch entry)
                        :patch-set (migration-entry-patch-set entry)
                        :ledger (migration-entry-ledger entry)
                        :phase phase))

(defun retire-entry (entry)
  (remhash (class-patch-class-name (migration-entry-class-patch entry))
           (migration-state-registry *migration-state*)))

;;; ---------------------------------------------------------------------
;;; Instance migration
;;; One :AFTER method on STANDARD-OBJECT consults the registry, instead of
;;; generating a method per class. Untracked classes pay one hash lookup.

;;; Forward

(defun run-migrate-forward (entry instance before)
  "Run the author's :migrate-forward on INSTANCE. Returns :MIGRATED, or the
error it signaled."
  (let ((forward (class-patch-migrate-forward (migration-entry-class-patch entry))))
    (handler-case (progn (when forward
                           (funcall forward instance (bound-values before)))
                         :migrated)
      (error (e) e))))

(defun journal-forward (entry instance before after)
  "Record INSTANCE's old-slot states in ENTRY's ledger. Returns the seq."
  (with-migration-lock
    (let ((seq (incf (migration-state-journal-seq *migration-state*))))
      (setf (gethash instance (class-ledger-journal (migration-entry-ledger entry)))
            (make-journal-record :seq seq :before before :after after))
      seq)))

(defun entry-audit-fields (entry)
  (list :patch-set (class-ledger-set-name (migration-entry-ledger entry))
        :class (class-patch-class-name (migration-entry-class-patch entry))))

(defun audit-forward (entry seq before)
  (apply #'audit :instance-migration :direction :forward :journal-seq seq
                                     :pre-state (bound-values before)
                                     (entry-audit-fields entry)))

(defun audit-beside-failure (event &rest fields)
  "Audit EVENT for a failure already in hand. Returns the entry's seq,
:UNLOGGED, or :REFUSED when the log has stopped, so a stopped log never
replaces the failure being reported."
  (handler-case (apply #'audit event fields)
    (error () :refused)))

(defun fail-forward (entry instance condition)
  "Arm the set's hard trigger, audit the failure, then signal
MIGRATION-FAILURE. An old-routed task may have fired this, and no shim would
see it."
  (let ((ps (migration-entry-patch-set entry)))
    (arm-hard-trigger ps (list :migration-failure (princ-to-string condition)))
    (apply #'audit-beside-failure :instance-migration :direction :forward
                                                      :outcome :failed :cause (princ-to-string condition)
                                                      (entry-audit-fields entry))
    (error 'migration-failure :patch-set ps :instance instance
                              :direction :forward :cause condition)))

(defun migrate-instance-forward (entry instance)
  "Run the author's forward migration on INSTANCE and journal its old slots
from just before and just after. A failure arms the set's hard trigger and
signals MIGRATION-FAILURE. Returns :MIGRATED."
  (let* ((old-specs (class-patch-old-slot-specs (migration-entry-class-patch entry)))
         (before (slot-states instance old-specs))
         (outcome (run-migrate-forward entry instance before)))
    (unless (eq outcome :migrated)
      (fail-forward entry instance outcome))
    (audit-forward entry
                   (journal-forward entry instance before
                                    (slot-states instance old-specs))
                   before)
    :migrated))

;;; Backward

(defun instance-history (ledger instance)
  "What LEDGER knows of INSTANCE: :JOURNALED, :NEW-BORN, :OLD-BORN or
:UNTOUCHED."
  (with-migration-lock
    (if (nth-value 1 (gethash instance (class-ledger-journal ledger)))
        :journaled
        (ecase (gethash instance (class-ledger-births ledger) :unborn)
          (:new :new-born)
          (:old :old-born)
          (:unborn :untouched)))))

(defun undo-slot (instance before after)
  "Put one old slot back to BEFORE while it still holds AFTER, the state
:migrate-forward left. Returns :UNDONE, :UNCHANGED when forward never
changed it, or :KEPT when something wrote it since."
  (cond ((same-slot-state-p before after) :unchanged)
        ((same-slot-state-p (slot-state instance (first after)) after)
         (restore-slot-state instance before)
         :undone)
        (t :kept)))

(defun undo-journaled (ledger instance)
  "Undo what :migrate-forward wrote to INSTANCE's old slots. Returns the
reversal."
  (let ((record (with-migration-lock
                  (gethash instance (class-ledger-journal ledger)))))
    (make-reversal :kind :journal-exact
                   :slots-undone (count :undone
                                        (mapcar (lambda (before after)
                                                  (undo-slot instance before after))
                                                (journal-record-before record)
                                                (journal-record-after record))))))

(defun synthesize-old-slots (entry instance property-list)
  "Run the author's :migrate-backward on INSTANCE. Returns the reversal."
  (let ((backward (class-patch-migrate-backward (migration-entry-class-patch entry))))
    (when backward
      (funcall backward instance property-list))
    (make-reversal :kind :synthesized)))

(defun reverse-instance (entry instance property-list)
  "Reverse INSTANCE by its history. Returns the reversal; an error in the
author's code makes it a :FAILED one."
  (let ((ledger (migration-entry-ledger entry)))
    (handler-case
        (ecase (instance-history ledger instance)
          (:journaled (undo-journaled ledger instance))
          (:new-born (synthesize-old-slots entry instance property-list))
          (:old-born (make-reversal :kind :old-born-unchanged))
          (:untouched (make-reversal :kind :untouched)))
      (error (e) (make-reversal :kind :failed :cause e)))))

(defun record-reversal (entry instance reversal)
  "Record INSTANCE's REVERSAL in ENTRY's ledger. A recorded failure stays,
so a later retry that succeeds cannot hide it. Returns the reversal kept."
  (with-migration-lock
    (let ((outcomes (class-ledger-outcomes (migration-entry-ledger entry))))
      (if (eq :failed (reversal-kind (gethash instance outcomes
                                              (make-reversal :kind :untouched))))
          (gethash instance outcomes)
          (setf (gethash instance outcomes) reversal)))))

(defun journal-seq-of (entry instance)
  (with-migration-lock
    (journal-record-seq (gethash instance (class-ledger-journal
                                           (migration-entry-ledger entry))))))

(defun audit-journal-exact (entry instance reversal)
  (apply #'audit :instance-migration :direction :backward :mode :journal-exact
                                     :journal-seq (journal-seq-of entry instance)
                                     :slots-undone (reversal-slots-undone reversal)
                                     (entry-audit-fields entry)))

(defun fail-backward (entry instance reversal)
  "Audit a failed reversal and then signal MIGRATION-FAILURE. The reversal is
already recorded so the rollback sees it whichever thread touched INSTANCE"
  (apply #'audit-beside-failure :instance-migration :direction :backward
                                                    :outcome :failed :cause (princ-to-string (reversal-cause reversal))
                                                    (entry-audit-fields entry))
  (error 'migration-failure :patch-set (migration-entry-patch-set entry)
                            :instance instance :direction :backward
                            :cause (reversal-cause reversal)))

(defun migrate-instance-backward (entry instance property-list)
  "Reverse INSTANCE by what ENTRY's ledger knows of it, and record the
reversal there. Signals MIGRATION-FAILURE when reversing failed. Returns the
reversal."
  (let ((reversal (reverse-instance entry instance property-list)))
    (record-reversal entry instance reversal)
    (ecase (reversal-kind reversal)
      (:failed (fail-backward entry instance reversal))
      (:journal-exact (audit-journal-exact entry instance reversal))
      ;; no instance identity to log: ROLLBACK-CLASS-PATCH's counts carry them
      ((:synthesized :old-born-unchanged :untouched)))
    reversal))

;;; The two methods

(defun migrate-instance (entry instance property-list)
  "Run ENTRY's phase on INSTANCE, just brought to its class's current shape."
  (ecase (migration-entry-phase entry)
    (:forward (migrate-instance-forward entry instance))
    (:backward (migrate-instance-backward entry instance property-list))
    ;; nothing per instance: PROMOTE-CLASS-PATCH audits the count
    (:finalize :finalized)))

(defmethod update-instance-for-redefined-class :after
    ((instance standard-object) added-slots discarded-slots property-list
     &rest initargs)
  (declare (ignore initargs added-slots discarded-slots))
  (let ((entry (entry-for-class (class-name (class-of instance)))))
    (unless (eq entry :untracked)
      (migrate-instance entry instance property-list))))

(defun note-birth (entry instance)
  "Record INSTANCE, made during ENTRY's canary, with the route that made it."
  (when (eq :forward (migration-entry-phase entry))
    (let ((route (task-route-for (migration-entry-patch-set entry))))
      (with-migration-lock
        (setf (gethash instance (class-ledger-births (migration-entry-ledger entry)))
              route)))))

;;; Track canary-born instances, which never pass through forward migration.
(defmethod initialize-instance :after ((instance standard-object)
                                       &rest initargs)
  (declare (ignore initargs))
  (let ((entry (entry-for-class (class-name (class-of instance)))))
    (unless (eq entry :untracked)
      (note-birth entry instance))))

;;; ---------------------------------------------------------------------
;;; Phase drivers
;;; Called by the lifecycle controller.

(defun begin-class-canary (ps cp)
  "Open PS's ledger for CP's class, file a :forward entry, and apply the union
shape. Forward migration then runs lazily, on first touch."
  (file-entry (make-migration-entry :class-patch cp :patch-set ps
                                    :ledger (open-ledger ps cp) :phase :forward))
  (apply-class-shape (class-patch-class-name cp)
                     (class-patch-union-slots cp)
                     (class-patch-old-superclass-names cp))
  (audit :class-shape :class (class-patch-class-name cp) :shape :union
                      :patch-set (patch-set-name ps)
                      :added (mapcar (lambda (s) (getf (canonicalize-slot-spec s) :name))
                                     (class-patch-add-slots cp))
                      :retained-drops (class-patch-drop-slots cp)))

(defun touch-instance (instance)
  "Force a pending instance update. Only slot access trips the trap."
  (let ((slots (sb-mop:class-slots (class-of instance))))
    (when slots
      (slot-boundp instance (sb-mop:slot-definition-name (first slots))))))

(defun touch-for-reversal (instance)
  "Touch INSTANCE so it reverses now. A failure is already in the ledger, so
it is not raised here. Returns :TOUCHED or :RECORDED."
  (handler-case (progn (touch-instance instance) :touched)
    (migration-failure () :recorded)))

(defun ledger-reversals (ledger)
  (with-migration-lock
    (loop for reversal being the hash-values of (class-ledger-outcomes ledger)
          collect reversal)))

(defun reversal-counts (ledger)
  "LEDGER's reversals counted by kind, with the slots they undid."
  (let ((reversals (ledger-reversals ledger)))
    (flet ((count-kind (kind) (count kind reversals :key #'reversal-kind)))
      (list :journal-exact (count-kind :journal-exact)
            :synthesized (count-kind :synthesized)
            :old-born-unchanged (count-kind :old-born-unchanged)
            :untouched (count-kind :untouched)
            :failed (count-kind :failed)
            :slots-undone (reduce #'+ reversals :key #'reversal-slots-undone)))))

(defun failure-summary (ledger counts)
  (format nil "~d instance~:p failed to reverse, the first with: ~a"
          (getf counts :failed)
          (reversal-cause (find :failed (ledger-reversals ledger)
                                :key #'reversal-kind))))

(defun rollback-class-patch (ps cp)
  "Put CP's class back in its original shape, reverse every instance PS's
ledger knows, then close the ledger. Signals ROLLBACK-FAILURE when any
instance failed to reverse, on this thread or another. Returns the counts."
  (let* ((entry (entry-of ps cp))
         (ledger (migration-entry-ledger entry)))
    (file-entry (entry-in-phase entry :backward))
    (apply-class-shape (class-patch-class-name cp)
                       (class-patch-old-slot-specs cp)
                       (class-patch-old-superclass-names cp))
    (mapc #'touch-for-reversal (ledger-instances ledger))
    (let ((counts (reversal-counts ledger)))
      (when (plusp (getf counts :failed))
        (error 'rollback-failure :patch-set ps
                                 :cause (failure-summary ledger counts)))
      (retire-entry entry)
      (close-ledger ledger)
      (audit :class-shape :class (class-patch-class-name cp) :shape :original
                          :patch-set (patch-set-name ps) :reversal-counts counts)
      counts)))

(defun promote-class-patch (ps cp)
  "Apply the final shape, finish every instance PS's ledger knows, and release
its births. The ledger and its journal stay until sealing."
  (let* ((entry (entry-of ps cp))
         (ledger (migration-entry-ledger entry))
         (instances (ledger-instances ledger)))
    (file-entry (entry-in-phase entry :finalize))
    (apply-class-shape (class-patch-class-name cp)
                       (class-patch-final-slots cp)
                       (class-patch-old-superclass-names cp))
    (mapc #'touch-instance instances)
    (retire-entry entry)
    (release-births ledger)
    (audit :class-shape :class (class-patch-class-name cp) :shape :new
                        :patch-set (patch-set-name ps)
                        :dropped (class-patch-drop-slots cp)
                        :finalized (length instances))))

(defun seal-class-journal (ps)
  "Close PS's ledgers; rollback is no longer offered. Returns how many journal
records were released."
  (let ((released (loop for cp in (patch-set-class-patches ps)
                        for ledger = (ledger-of ps cp)
                        unless (eq ledger :none)
                          sum (close-ledger ledger))))
    (audit :journal-expired :patch-set (patch-set-name ps) :released released)
    released))

(defun migration-journal-count (&optional (set-name :all))
  "Journal records held for SET-NAME, or for every set."
  (with-migration-lock
    (loop for ledger being the hash-values of (migration-state-ledgers *migration-state*)
          when (or (eq set-name :all) (eq set-name (class-ledger-set-name ledger)))
            sum (hash-table-count (class-ledger-journal ledger)))))
