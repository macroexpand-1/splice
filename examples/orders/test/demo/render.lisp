;;;; render.lisp: tests for the demo's renderers and act 3's chain checks

(in-package #:splice-orders/demo-tests)

(def-suite demo-render :in demo :description "Renderers and chain strip, no CLOG.")
(in-suite demo-render)

(defun count-of (needle haystack)
  "How many times NEEDLE occurs in HAYSTACK."
  (loop for start = (search needle haystack) then (search needle haystack :start2 (1+ start))
        while start
        count t))

(defun frame-text (previous next)
  "Every string RENDER-FRAME gives for PREVIOUS to NEXT, joined."
  (format nil "~{~a~}" (d:render-frame previous next)))

(defun role-attribute (svg role attribute)
  "The integer ATTRIBUTE of the first element in SVG whose data-role is ROLE."
  (let* ((at (search (format nil "data-role='~a'" role) svg))
         (start (search "<" svg :from-end t :end2 at))
         (key (search (format nil "~a='" attribute) svg :start2 start)))
    (parse-integer svg :start (+ key (length attribute) 2) :junk-allowed t)))

(defun pending-styles (snapshot)
  "The field style of every order SNAPSHOT holds as :pending."
  (loop for state across (getf snapshot :orders)
        for style across (d::field-styles snapshot)
        when (eq state :pending)
          collect style))

(defun with-three-orders-current (snapshot)
  "SNAPSHOT with its first three orders made :current."
  (let ((orders (copy-seq (getf snapshot :orders))))
    (fill orders :current :end 3)
    (list* :orders orders snapshot)))

(test fresh-page-draws-everything
  (dolist (fixture (all-fixtures))
    (let ((strings (d:render-frame nil fixture)))
      (is (= 7 (length strings)))
      (is (equal (d::set-mode "live") (first strings))))))

(test idle-frame-draws-nothing
  (dolist (fixture (all-fixtures))
    (is (null (d:render-frame fixture fixture)))))

(test field-diff
  (let* ((old (load-fixture "act-1-canary-25"))
         (text (frame-text old (with-three-orders-current old))))
    (is (= 3 (count-of "spliceDot(" text)))
    (is (null (search "spliceClear" text)))))

(test stranded-dots
  (let ((promoted (pending-styles (load-fixture "act-1-promoted")))
        (canary (pending-styles (load-fixture "act-1-canary-25"))))
    (is (plusp (length promoted)))
    (is (every (lambda (style) (equal "stranded" style)) promoted))
    (is (plusp (length canary)))
    (is (every (lambda (style) (equal "pending" style)) canary))))

(test bounds-where-they-belong
  (let* ((sprt (getf (load-fixture "act-2-reject") :sprt))
         (svg (d::evidence-svg sprt)))
    (is (< (role-attribute svg "reject" "y1") (role-attribute svg "accept" "y1")))
    (is (= (funcall (d::x-scale (getf sprt :errors) sprt) 50)
           (role-attribute svg "min-n" "x1")))
    (is (search "data-role='arrow'" svg))))

(test version-banner
  (let ((strings (d:render-frame nil (list :version (1+ d:+snapshot-version+)))))
    (is (= 1 (length strings)))
    (is (search (d::set-mode "banner") (first strings)))))

(test escaping
  (let ((js (d:js-string "a\"b</script>")))
    (is (equal "\"a\\\"b<\\/script>\"" js))
    (is (null (search "</" js))))
  (is (null (search "<" (d::html-escape "<b>")))))

(test buttons-follow-the-snapshot
  (is (search (d::set-disabled "next" nil) (frame-text nil (load-fixture "act-1-paused-stage-0"))))
  (is (search (d::set-disabled "next" t) (frame-text nil (load-fixture "act-1-promoted"))))
  (dolist (name *fixture-names*)
    (is (eq (string= name "act-1-promoting-held")
            (not (null (search (d::set-disabled "release" nil)
                               (frame-text nil (load-fixture name)))))))))

(test faults-badge
  (let ((fixture (load-fixture "act-1-canary-25")))
    (is (search (d::set-hidden "faults" nil)
                (frame-text nil (list* :faults '("recorder: disk full") fixture))))
    (is (search (d::set-hidden "faults" t)
                (frame-text nil (list* :faults '() fixture))))))

(test chain-strip-buckets
  (is (= 100 (count-of "var(--accept)" (d:chain-strip-svg 200 nil))))
  (let ((svg (d:chain-strip-svg 200 101)))
    (is (= 50 (count-of "var(--accept)" svg)))
    (is (= 50 (count-of "var(--reject)" svg)))))

(test chain-result-off-by-one
  (with-demo-log (path)
    (dotimes (i 60) (splice:audit :demo-test-entry :i i))
    (splice:close-audit-log)
    (let ((original (d:chain-result path)))
      (is-true (getf original :ok))
      (is (= 60 (getf original :entries))))
    (let ((result (d::chain-result (d::tamper-copy path))))
      (is (= 60 (getf result :entries)))
      (is (= 42 (getf result :break-seq)))
      (is (= 41 (getf result :first-bad-seq))))))
