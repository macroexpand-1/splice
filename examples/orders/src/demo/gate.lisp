;;;; gate.lisp

(in-package #:splice-orders/demo)

(defstruct gate
  (lock (sb-thread:make-mutex :name "demo-gate") :read-only t)
  (queue (sb-thread:make-waitqueue) :read-only t)
  ;; mutable
  (opened '())                          ; keys opened but not consumed
  (released nil))                       ; true once every wait passes for good

(defun open-gate (gate key)
  "Open KEY once. Exactly one waiter on KEY (present or future) gets through
Returns KEY"
  (sb-thread:with-mutex ((gate-lock gate))
    (push key (gate-opened gate))
    (sb-thread:condition-broadcast (gate-queue gate))
    key))

(defun release-gate (gate)
  "Let every present and future wait on GATE through, whatever its key. Returns :released"
  (sb-thread:with-mutex ((gate-lock gate))
    (setf (gate-released gate) t)
    (sb-thread:condition-broadcast (gate-queue gate))
    :released))

(defun await-gate (gate key)
  "Block until KEY is opened, then consume it, or until GATE is released. Returns KEY"
  (sb-thread:with-mutex ((gate-lock gate))
    (loop until (or (gate-released gate) (member key (gate-opened gate)))
          do (sb-thread:condition-wait (gate-queue gate) (gate-lock gate)))
    (setf (gate-opened gate) (remove key (gate-opened gate) :count 1))
    key))
