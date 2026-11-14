;;;; audit.lisp: append-only, hash-chained provenance log.
;;;; One plist per line, each carrying the SHA-256 of the previous line.
;;;; RECONSTRUCT-STATE rebuilds expected code state from the log alone;
;;;; VERIFY-RECONSTRUCTION (lifecycle.lisp) compares it to the live image.

(in-package #:splice)

(defstruct (audit-log (:constructor %make-audit-log))
  path stream (seq 0) (prev-hash "genesis") (lock (sb-thread:make-mutex))
  ;; bounded in-memory tail, newest first; the file is the source of truth
  (lines '()) (lines-count 0))

(defvar *boot-id*
  (sha256-hex (format nil "~a-~a-~a" (get-universal-time)
                      (get-internal-real-time) (machine-instance)))
  "Identity of this image incarnation, stamped into every log entry.")

(defvar *audit-log* nil "The active audit log, or NIL for none.")

(defconstant +unix-epoch-universal-time+ 2208988800
  "Universal epoch time (1970-01-01T00:00:00Z)")

;;; ---------------------------------------------------------------------
;;; Writing the log

(defun open-audit-log (path)
  "Start a new log at PATH. Refuses a path that already holds a file:
RESUME-AUDIT-LOG continues one"
  (when (probe-file path)
    (error "audit log ~a already exists; resume-audit-log continues it" path))
  (let ((stream (open path :direction :output :if-exists :error
                           :if-does-not-exist :create)))
    (setf *audit-log* (%make-audit-log :path path :stream stream))))

(defun delete-audit-log (path)
  "Delete the log at PATH, for a caller that means to start it again.
Returns :DELETED or :ABSENT"
  (cond ((probe-file path) (delete-file path) :deleted)
        (t :absent)))

(defun close-audit-log ()
  "Close the open log under its lock, so no entry is cut off mid-write"
  (let ((log *audit-log*))
    (when log
      (sb-thread:with-mutex ((audit-log-lock log))
        (close (audit-log-stream log)))
      (setf *audit-log* nil))))

(defun timestamp-string ()
  "UTC wall clock time in ms, ISO 8601 standard"
  (multiple-value-bind (unix-seconds microseconds) (sb-ext:get-time-of-day)
    (multiple-value-bind (sec min hour day month year)
        (decode-universal-time (+ unix-seconds +unix-epoch-universal-time+) 0)
      (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d.~3,'0dZ"
              year month day hour min sec (floor microseconds 1000)))))

(defun flatten-newlines (string)
  "STRING with line breaks replaced by spaces, so log entries stay
on one line."
  (substitute-if #\Space
                 (lambda (char) (member char '(#\Newline #\Return)))
                 string))

(defun sanitize-for-log (value)
  "Reduce VALUE to something READably printable. Structure instances,
functions, and other unREADable objects become (:opaque <hash-of-printed>)."
  (typecase value
    (string (flatten-newlines value))
    ((or number keyword boolean) value)
    (symbol value)
    (cons (cons (sanitize-for-log (car value))
                (sanitize-for-log (cdr value))))
    (condition (list :condition (string (type-of value))
                     (flatten-newlines (princ-to-string value))))
    (t (list :opaque (subseq (sha256-hex (princ-to-string value)) 0 16)))))

(defun write-entry (log event fields)
  "Appen done entry to LOG and return its seq. Caller holds LOG's lock"
  (let* ((entry (list* :seq (incf (audit-log-seq log))
                       :ts (timestamp-string)
                       :prev-hash (audit-log-prev-hash log)
                       :boot-id (subseq *boot-id* 0 12)
                       :event event
                       (mapcar #'sanitize-for-log fields)))
         (line (with-standard-io-syntax
                 (let ((*print-readably* nil) (*print-pretty* nil)
                       (*package* (find-package :splice)))
                   (prin1-to-string entry)))))
    (write-line line (audit-log-stream log))
    (finish-output (audit-log-stream log))
    (push line (audit-log-lines log))
    (when (> (incf (audit-log-lines-count log)) 6000)
      ;; keep the newest 3000. don't let long batches grow the heap
      (setf (cdr (nthcdr 2999 (audit-log-lines log))) nil
            (audit-log-lines-count log) 3000))
    (setf (audit-log-prev-hash log) (sha256-hex line))
    (audit-log-seq log)))

(defun audit (event &rest fields)
  "Append an entry to the audit log. EVENT is a keyword and FIELDS a plist.
Returns the entry's sequence number or NIL"
  (let ((log *audit-log*))
    (when log
      (sb-thread:with-mutex ((audit-log-lock log))
        (when (open-stream-p (audit-log-stream log))
          (write-entry log event fields))))))

;;; ---------------------------------------------------------------------
;;; Offline: chain verification

(defun map-audit-entries (path fn &key (verify t))
  "Call FN on each entry of the log at PATH, verifying the hash chain.
Returns (values ok count break-seq). Streams, so large logs never sit in
memory."
  (with-open-file (in path)
    (let ((*read-eval* nil)
          (*package* (find-package :splice))
          (expected "genesis")
          (count 0))
      (loop for line = (read-line in nil nil)
            while line
            do (let ((entry (read-from-string line)))
                 (when (and verify
                            (not (equal (getf entry :prev-hash) expected)))
                   (return-from map-audit-entries
                     (values nil count (getf entry :seq))))
                 (setf expected (sha256-hex line))
                 (incf count)
                 (when fn (funcall fn entry))))
      (values t count nil))))

(defun verify-audit-chain (path)
  "Verify the hash chain of the log at PATH. Returns (values ok entry-count
break-seq), where BREAK-SEQ is the first entry whose :prev-hash mismatches."
  (map-audit-entries path nil))

(defun last-line (path)
  "Last line of the file at PATH or :EMPTY"
  (with-open-file (in path)
    (loop with last = :empty
          for line = (read-line in nil nil)
          while line
          do (setf last line)
          finally (return last))))

(defun entry-of-line (line)
  "The audit entry one log LINE holds, read the way that MAP-AUDIT-ENTRIES reads."
  (let ((*read-eval* nil)
        (*package* (find-package :splice)))
    (read-from-string line)))

(defun chain-tail (path)
  "Where the chain at PATH left off: last seq and the hash of the last line"
  (let ((line (if (probe-file path) (last-line path) :empty)))
    (if (eq line :empty)
        (values 0 "genesis")
        (values (getf (entry-of-line line) :seq) (sha256-hex line)))))

(defun check-chain-intact (path)
  "Signal an error when the log at PATH has a broken chain. Return :INTACT"
  (multiple-value-bind (ok count break-seq) (verify-audit-chain path)
    (declare (ignore count))
    (unless ok
      (error "audit chain broken at seq ~a; refusing to append" break-seq))
    :intact))

(defun boot-fields ()
  "What a :BOOT entry records about this process"
  (list :full-boot-id *boot-id*
        :lisp (lisp-implementation-version)
        :machine (machine-instance)
        :core (namestring sb-ext:*core-pathname*)))

(defun resume-audit-log (path)
  "Append to the log at PATH, continuing the chaing, and record this boot"
  (when (probe-file path)
    (check-chain-intact path))
  (multiple-value-bind (seq prev-hash) (chain-tail path)
    (setf *audit-log*
          (%make-audit-log :path path :seq seq :prev-hash prev-hash
                           :stream (open path :direction :output
                                              :if-exists :append
                                              :if-does-not-exist :create))))
  (apply #'audit :boot (boot-fields))
  *audit-log*)

;;; ---------------------------------------------------------------------
;;; Offline: state reconstruction
;;; Reconstruction state is a plist of four alists, each newest first:
;;; :functions (name . impl), :classes (name . shape), :sets (name . state),
;;; and :members (set-name . (:functions fs :classes cs)) from registration.
;;; Every function below returns a new state and leaves its argument alone.

(defun empty-reconstruction ()
  (list :functions '() :classes '() :sets '() :members '()))

(defun replace-entry (alist name value)
  "ALIST with NAME's entry replaced by (NAME . VALUE) at the front."
  (acons name value (remove name alist :key #'car)))

(defun update-field (state key fn)
  "STATE with KEY's value replaced by FN applied to it."
  (let ((copy (copy-list state)))
    (setf (getf copy key) (funcall fn (getf state key)))
    copy))

(defun update-set-state (state set-name set-state)
  "STATE with patch set SET-NAME moved to SET-STATE."
  (update-field state :sets
                (lambda (sets) (replace-entry sets set-name set-state))))

(defun register-members (state set-name functions classes)
  "STATE with SET-NAME's registered FUNCTIONS and CLASSES recorded."
  (update-field state :members
                (lambda (members)
                  (acons set-name (list :functions functions :classes classes)
                         members))))

(defun patch-set-members (state set-name)
  (cdr (assoc set-name (getf state :members))))

(defun retarget-set (state set-name set-state impl shape)
  "STATE with SET-NAME moved to SET-STATE, each of its functions pointing at
IMPL and each of its classes at SHAPE."
  (let ((members (patch-set-members state set-name)))
    (update-field
     (update-field (update-set-state state set-name set-state)
                   :functions
                   (lambda (functions)
                     (reduce (lambda (acc f) (replace-entry acc (getf f :name) impl))
                             (getf members :functions)
                             :initial-value functions)))
     :classes
     (lambda (classes)
       (reduce (lambda (acc c) (replace-entry acc c shape))
               (getf members :classes)
               :initial-value classes)))))

(defun apply-audit-entry (state entry)
  "STATE after folding in one audit log ENTRY. Events that do not move code
state return STATE unchanged."
  (let ((set-name (getf entry :patch-set)))
    (case (getf entry :event)
      (:patch-registered
       (update-set-state (register-members state set-name
                                           (getf entry :functions)
                                           (getf entry :classes))
                         set-name :registered))
      (:contract-result
       (if (eq (getf entry :verdict) :veto)
           (update-set-state state set-name :vetoed)
           state))
      (:install
       (retarget-set state set-name :staged :shimmed :union))
      (:canary-transition
       (update-set-state state set-name (getf entry :to)))
      (:promotion
       (retarget-set state set-name :promoted (list :new set-name) :new))
      (:rollback-complete
       (retarget-set state set-name :rolled-back :original :original))
      (:freeze
       (update-set-state state set-name :frozen))
      (t state))))

(defun reconstruct-state (path)
  "Fold over the audit log to derive the image's expected code state.
Returns a plist: (:functions alist(name . impl) :classes alist(name . shape)
:sets alist(name . final-state)) where IMPL is :original, :shimmed, or
(:new set-name), and SHAPE is :original, :union, or :new."
  (let ((state (empty-reconstruction)))
    ;; MAP-AUDIT-ENTRIES streams for effect, so the fold threads STATE here
    (multiple-value-bind (ok count break-seq)
        (map-audit-entries path (lambda (entry)
                                  (setf state (apply-audit-entry state entry))))
      (declare (ignore count))
      (unless ok
        (error "audit chain broken at seq ~a; refusing to reconstruct"
               break-seq)))
    (list :functions (getf state :functions)
          :classes (getf state :classes)
          :sets (getf state :sets))))
