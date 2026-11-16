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

(defvar *audit-log* nil "The active audit log or NIL.")

(defconstant +unix-epoch-universal-time+ 2208988800
  "Universal epoch time (1970-01-01T00:00:00Z)")

(defun truncate-file (path length)
  "Cut the file at PATH to LENGTH octets. Returns LENGTH"
  (let ((result (sb-alien:alien-funcall
                 (sb-alien:extern-alien "truncate"
                                        (function sb-alien:int sb-alien:c-string
                                                  (sb-alien:signed 64)))
                 (sb-ext:native-namestring (truename path))
                 length)))
    (unless (zerop result)
      (error "truncating ~a to ~a octets failed" path length))
    length))

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
Returns the entry's sequence number or :UNLOGGED"
  (let ((log *audit-log*))
    (if log
        (sb-thread:with-mutex ((audit-log-lock log))
          (if (open-stream-p (audit-log-stream log))
              (write-entry log event fields)
              :unlogged))
        :unlogged)))

;;; ---------------------------------------------------------------------
;;; Offline: chain verification

(defun read-entry-or-unreadable (line)
  "The entry LINE holds or :UNREADABLE"
  (handler-case (let ((entry (entry-of-line line)))
                  (if (and (consp entry) (integerp (getf entry :seq)))
                      entry
                      :unreadable))
    (error () :unreadable)))

(defun map-audit-entries (path fn &key (verify t))
  "Call FN on each entry of the log at PATH, verifying the hash chain.
Returns (values ok count break-seq reason). REASON is :INTACT, :HASH-MISMATCH,
:UNREADABLE (a whole line that doesn't read) or :TORN-TAIL (a last line that
doesn't read and has no newline, as a crash mid-write leaves). With VERIFY
NIL, an unreadable line signals instead, so a reader that ignores OK never
gets a short list. Streams, so large logs never sit in memory."
  (with-open-file (in path :external-format '(:utf-8 :replacement #\?))
    (let ((expected "genesis")
          (count 0))
      (loop for (line missing-newline-p) = (multiple-value-list (read-line in nil nil))
            while line
            do (let ((entry (read-entry-or-unreadable line)))
                 (when (eq entry :unreadable)
                   (unless verify
                     (error "audit log ~a has an unreadable line after entry ~a" path count))
                   (return-from map-audit-entries
                     (values nil count (1+ count)
                             (if missing-newline-p :torn-tail :unreadable))))
                 (when (and verify
                            (not (equal (getf entry :prev-hash) expected)))
                   (return-from map-audit-entries
                     (values nil count (getf entry :seq) :hash-mismatch)))
                 (setf expected (sha256-hex line))
                 (incf count)
                 (when fn (funcall fn entry))))
      (values t count nil :intact))))

(defun verify-audit-chain (path)
  "Verify the hash chain of the log at PATH. Returns (values ok entry-count
break-seq), where BREAK-SEQ is the first entry whose :prev-hash mismatches."
  (map-audit-entries path nil))

(defun last-two-lines (path)
  "Last line of the file at PATH and the one before it. Eaach can be :EMPTY"
  (with-open-file (in path :external-format '(:utf-8 :replacement #\?))
    (loop with previous = :empty
          with last = :empty
          for line = (read-line in nil nil)
          while line
          do (setf previous last
                   last line)
          finally (return (values last previous)))))

(defun tail-line (path)
  "The line the chain at PATH continues from. Last line that doesn't read is
torn or still being written - chain continues."
  (multiple-value-bind (last previous) (last-two-lines path)
    (if (and (stringp last) (eq :unreadable (read-entry-or-unreadable last)))
        previous
        last)))

(defun entry-of-line (line)
  "The audit entry one log LINE holds, read the way that MAP-AUDIT-ENTRIES reads."
  (let ((*read-eval* nil)
        (*package* (find-package :splice)))
    (read-from-string line)))

(defun chain-tail (path)
  "Where the chain at PATH left off: last seq and the hash of the line it continues from"
  (let ((line (if (probe-file path) (tail-line path) :empty)))
    (if (eq line :empty)
        (values 0 "genesis")
        (values (getf (entry-of-line line) :seq) (sha256-hex line)))))

(defun last-newline-end (path)
  "Octet offeset past the last newline in the file at PATH or 0"
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (loop for pos from (1- (file-length in)) downto 0
          do (file-position in pos)
             (when (= 10 (read-byte in))
               (return (1+ pos)))
          finally (return 0))))

(defun tail-octets (path start)
  "Octets of the file at PATH from START to its end"
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((octets (make-array (- (file-length in) start)
                              :element-type '(unsigned-byte 8))))
      (file-position in start)
      (read-sequence octets in)
      octets)))

(defun cut-torn-tail (path)
  "Cut the torn last line off the log at PATH. Returns :TORN-TAIL fields"
  (let* ((start (last-newline-end path))
         (octets (tail-octets path start)))
    (truncate-file path start)
    (list :after-seq (chain-tail path)
          :bytes (length octets)
          :sha256 (sha256-octets-hex octets))))

(defun missing-final-newline-p (path)
  "Tree when the file at PATH ends i a line with no newline"
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (and (plusp (file-length in))
         (progn (file-position in (1- (file-length in)))
                (/= 10 (read-byte in))))))

(defun terminate-last-line (path)
  "Append the newline a complete last line is missing. Returns :NEWLINE-ADDED"
  (with-open-file (out path :direction :output :if-exists :append)
    (terpri out))
  :newline-added)

(defun refuse-broken-chain (path)
  "Signal unless the log at PATH verifies. Returns :INTACT"
  (multiple-value-bind (ok count break-seq reason) (verify-audit-chain path)
    (declare (ignore count))
    (unless ok
      (error "audit log ~a does not verify (~(~a~)~@[ at seq ~a~]); refusing to append"
             path reason break-seq))
    :intact))

(defun repair-or-refuse (path)
  "Make the PATH safe to append to. Returns :INTACT, :NEWLIE-ADDED, or the fields
of a cut torn tale; singals on any other break"
  (multiple-value-bind (ok count break-seq reason) (verify-audit-chain path)
    (declare (ignore count break-seq))
    (cond ((and ok (missing-final-newline-p path)) (terminate-last-line path))
          (ok :intact)
          ((eq reason :torn-tail) (let ((cut (cut-torn-tail path)))
                                    (refuse-broken-chain path)
                                    cut))
          (t (refuse-broken-chain path)))))

(defun boot-fields ()
  "What a :BOOT entry records about this process"
  (list :full-boot-id *boot-id*
        :lisp (lisp-implementation-version)
        :machine (machine-instance)
        :core (namestring sb-ext:*core-pathname*)))

(defun resume-audit-log (path)
  "Append to the log at PATH, continuing the chaing, and record this boot"
  (let ((repair (if (probe-file path) (repair-or-refuse path) :intact)))
    (multiple-value-bind (seq prev-hash) (chain-tail path)
      (setf *audit-log*
            (%make-audit-log :path path :seq seq :prev-hash prev-hash
                             :stream (open path :direction :output
                                                :if-exists :append
                                                :if-does-not-exist :create))))
    (when (consp repair)
      (apply #'audit :torn-tail repair))
    (apply #'audit :boot (boot-fields))
    *audit-log*))

;;; ---------------------------------------------------------------------
;;; Offline: state reconstruction
;;; Reconstruction state is a plist of four alists, each newest first:
;;; :functions (name . impl), :classes (name . shape), :sets (name . state),
;;; and :members (set-name . (:functions fs :classes cs)) from registration.
;;; An impl or shape is (kind set-name), naming the set whose code it is, so
;;; a lookup can never land in a different set that patched the same name.
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

(defun retarget-set (state set-name set-state impl-kind shape-kind)
  "STATE with SET-NAME moved to SET-STATE, each of its functions pointing at
(IMPL-KIND SET-NAME) and each of its classes at (SHAPE-KIND SET-NAME)."
  (let ((members (patch-set-members state set-name))
        (impl (list impl-kind set-name))
        (shape (list shape-kind set-name)))
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
       (retarget-set state set-name :promoted :new :new))
      (:rollback-complete
       (retarget-set state set-name :rolled-back :original :original))
      (:freeze
       (update-set-state state set-name :frozen))
      (t state))))

(defun reconstruct-state (path)
  "Fold over the audit log to derive the image's expected code state.
Returns a plist: (:functions alist(name . impl) :classes alist(name . shape)
:sets alist(name . final-state)) where IMPL is (:original set-name),
(:shimmed set-name) or (:new set-name), and SHAPE is (:original set-name),
(:union set-name) or (:new set-name)."
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
