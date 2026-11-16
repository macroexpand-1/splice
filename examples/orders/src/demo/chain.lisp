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

(defun tamper-copy (path &key (line 40))
  "Copy the log at PATH to temp directory with one digit changed on LINE.
Returns the copy's path - PATH is read only."
  (let ((copy (merge-pathnames "splice-demo-audit-tampered.log" (uiop:temporary-directory))))
    (with-open-file (in path)
      (with-open-file (out copy :direction :output :if-exists :supersede)
        (loop for text = (read-line in nil) while text
              for i from 0
              do (write-line (if (= i line) (substitute #\9 #\1 text :count 1) text) out))))
    copy))
