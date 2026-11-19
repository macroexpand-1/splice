;;;; snapshot.lisp: the snapshot contract's tests

(in-package #:splice-orders/demo-tests)

(def-suite demo-snapshot :in demo)
(in-suite demo-snapshot)

;;; ---------------------------------------------------------------------
;;; Helpers

(defun plain-data-p (form)
  "True when FORM only holds symbols, numbers, strings, conses, and
   simple vectors"
  (typecase form
    ((or symbol number string) t)
    (cons (and (plain-data-p (car form)) (plain-data-p (cdr form))))
    (simple-vector (every #'plain-data-p form))
    (t nil)))

(defun same-data-p (a b)
  "True when A and B are the same plain data: EQUAL on atoms and strings, so case
and 25 against 25.0 both count, walking conses and simple vectors"
  (typecase a
    (cons (and (consp b) (same-data-p (car a) (car b)) (same-data-p (cdr a) (cdr b))))
    (simple-vector (and (simple-vector-p b)
                        (= (length a) (length b))
                        (every #'same-data-p a b)))
    (t (equal a b))))

(defun round-trip (form)
  (with-input-from-string (in (with-output-to-string (out) (d:write-snapshot form out)))
    (d:read-snapshot in)))

(defun sprt-step-entry (stage errors slow)
  (list :event :sprt-step :stage stage :errors errors :slow slow))

(defun walk-after (walk steps &key (tail :complete))
  "WALK folded with STEPS as one frame with the act 2 bounds"
  (d::next-sprt walk (list :sprt-steps steps :tail tail
                           :bounds '(:upper 5.2983174 :budget 9004))))

;;; ---------------------------------------------------------------------
;;; Fixtures

(test fixtures-round-trip
  (dolist (snapshot (all-fixtures))
    (is (same-data-p snapshot (round-trip snapshot)))))

(test fixtures-hold-plain-data
  (dolist (snapshot (all-fixtures))
    (is (plain-data-p snapshot)))
  (is (not (plain-data-p (list :orders (vector (orders:make-test-order)))))))

;;; ---------------------------------------------------------------------
;;; Folding the SPRT walk

(test fold-same-stage-appends
  (let ((walk (walk-after (d::start-walk 0)
                          (list (sprt-step-entry 0 '(1 . -0.02) '(0 . 0.0))
                                (sprt-step-entry 0 '(2 . 3.02) '(0 . 0.0))))))
    (is (equal '((1 . -0.02) (2 . 3.02)) (getf walk :errors)))
    (is (equal '() (getf walk :slow)))
    (is (= 9004 (getf walk :budget)))))

(test fold-new-stage-starts-over
  (let* ((stage-0 (walk-after (d::start-walk 0)
                              (list (sprt-step-entry 0 '(149 . -3.0) '(149 . -3.1)))))
         (stage-1 (walk-after stage-0 (list (sprt-step-entry 1 '(1 . -0.02) '(0 . 0.0))))))
    (is (eql 1 (getf stage-1 :stage)))
    (is (equal '((1 . -0.02)) (getf stage-1 :errors)))))

(test trimmed-sticks-until-the-stage-changes
  (let* ((trimmed (walk-after (d::start-walk 0) '() :tail :trimmed))
         (later (walk-after trimmed (list (sprt-step-entry 0 '(5 . -0.1) '(0 . 0.0)))))
         (next-stage (walk-after later (list (sprt-step-entry 1 '(1 . -0.02) '(0 . 0.0))))))
    (is (eq t (getf trimmed :trimmed)))
    (is (eq t (getf later :trimmed)))
    (is (eq nil (getf next-stage :trimmed)))))

;;; ---------------------------------------------------------------------
;;; Sessions and reading

(test another-session-folds-from-empty
  (let ((snapshot (list :seq 40 :audit-seq 900 :session '(:started 100))))
    (is (eq snapshot (d::snapshot-for-session snapshot 100)))
    (is (= -1 (getf (d::snapshot-for-session snapshot 200) :seq)))))

(test unknown-field-signals
  (is (eql 1 (d:snapshot-get (load-fixture "act-2-reject") :version)))
  (signals error (d:snapshot-get (load-fixture "act-2-reject") :oders)))

(test cut-line-reads-as-eof
  (with-input-from-string (in (format nil "(:version 1 :seq 0)~%(:version 1 :se"))
    (is (equal '((:version 1 :seq 0)) (d:read-all-snapshots in)))))
