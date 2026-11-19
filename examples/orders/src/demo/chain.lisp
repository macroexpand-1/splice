;;;; chain.lisp

(in-package #:splice-orders/demo)

(defun chain-result (path)
  "Does the log at PATH chains, how many entries it holds, and the first
one to not trust. :REASON is VERIFY-AUDIT-CHAIN's reason"
  (multiple-value-bind (ok verified break-seq reason) (splice:verify-audit-chain path)
    (declare (ignore verified))
    (list :ok ok
          :reason reason
          :entries (line-count path)
          :break-seq break-seq
          :first-bad-seq (first-bad-seq reason break-seq))))

(defun line-count (path)
  "How many lines the file at PATH holds, whether or not they read"
  (with-open-file (in path :external-format '(:utf-8 :replacement #\?))
    (loop while (read-line in nil nil) count t)))

(defun first-bad-seq (reason break-seq)
  "The first entry not to trust, given VERIFY-AUDIT-CHAIN's REASON and BREAK-SEQ, or NIL.
A hash mismatch at BREAK-SEQ means the entry before it was changed; a line that
doesn't read is itself the bad entry; the anchor reasons name no entry"
  (ecase reason
    (:intact nil)
    (:hash-mismatch (1- break-seq))
    ((:unreadable :torn-tail) break-seq)
    ((:unanchored :truncated :unreadable-checkpoint) nil)))

(defun reconstruction-text (path)
  "One line saying whether state rebuilt from the log, at PATH, matches the live image"
  (multiple-value-bind (ok mismatches) (splice:verify-reconstruction path)
    (if ok
        "State rebuilt from the log matches the live image"
        (format nil "State rebuilt from the log differs in ~d place~:p" (length mismatches)))))

(defun call-with-tampered-copy (path fn &key (line 40))
  "Call FN with the path of a copy of the log at PATH that has one digit changed
on LINE. The copy has a fresh name and is deleted afterwards; PATH is only read.
Returns what FN returns."
  (let ((copy (fresh-temp-path "splice-demo-tampered")))
    (unwind-protect
         (progn (write-tampered-copy path copy line)
                (funcall fn copy))
      (uiop:delete-file-if-exists copy))))

(defun fresh-temp-path (prefix)
  "A path in the temp directory named PREFIX plus a random number, so two runs
on one machine never share it"
  (merge-pathnames (format nil "~a-~d.log" prefix
                           (random most-positive-fixnum (make-random-state t)))
                   (uiop:temporary-directory)))

(defun write-tampered-copy (path copy line)
  (with-open-file (in path)
    (with-open-file (out copy :direction :output :if-exists :error)
      (loop for text = (read-line in nil) while text
            for i from 0
            do (write-line (if (= i line) (substitute #\9 #\1 text :count 1) text) out)))))
