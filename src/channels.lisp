;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-
;;;;
;;;; Copyright © 2009 Josh Marchan
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(in-package :chanl)

;;; Queue
(defstruct (queue (:predicate queuep)
                  (:constructor make-queue (size)))
  head tail size)

(defun queue-peek (queue)
  (car (queue-head queue)))

(defun queue-empty-p (queue)
  (null (queue-head queue)))

(defun queue-full-p (queue)
  (= (length (queue-head queue))
     (queue-size queue)))

(defun queue-count (queue)
  (length (queue-head queue)))

(defun enqueue (object queue)
  (let ((tail-cons (list object)))
    (setf (queue-head queue)
          (nconc (queue-head queue) tail-cons))
    (setf (queue-tail queue) tail-cons)
    object))

(defun dequeue (queue)
  (prog1
      (pop (queue-head queue))
    (when (null (queue-head queue))
      (setf (queue-tail queue) nil))))

;;;
;;; Threads
;;;
(defun current-proc ()
  (bt:current-thread))

(defun proc-alive-p (proc)
  (bt:thread-alive-p proc))

(defun procp (proc)
  (bt:threadp proc))

(defun proc-name (proc)
  (bt:thread-name proc))

(defun kill (proc)
  (bt:destroy-thread proc))

(defun pcall (function &key name (initial-bindings *default-special-bindings*))
  "PCALL -> Parallel Call; calls FUNCTION in a new thread. FUNCTION must be a no-argument
function. Providing NAME will set the thread's name. Refer to Bordeaux-threads documentation
for how INITIAL-BINDINGS works."
  (bt:make-thread function :name name :initial-bindings initial-bindings))

(defmacro pexec ((&key name initial-bindings) &body body)
  "Executes BODY in parallel (a new thread). NAME sets new thread's name. Refer to
Bordeaux-Threads documentation for more information on INITIAL-BINDINGS."
  `(pcall (lambda () ,@body)
          ,@(when name `(:name ,name))
          ,@(when initial-bindings `(:initial-bindings ,initial-bindings))))

(defun all-procs ()
  (bt:all-threads))

;;;
;;; Channels
;;;
(defstruct (channel (:constructor %make-channel)
                    (:predicate channelp))
  buffer buffered-p
  (being-written-p nil :type (member t nil))
  (being-read-p nil :type (member t nil))
  (lock (bt:make-recursive-lock) :read-only t)
  (send-ok (bt:make-condition-variable) :read-only t)
  (recv-ok (bt:make-condition-variable) :read-only t))

(defvar *secret-unbound-value* (gensym "SECRETLY-UNBOUND-"))
(defun make-channel (&optional (buffer-size 0))
  (when (< buffer-size 0)
    (error "buffer size cannot be negative."))
  (let ((channel (%make-channel)))
    (if (> buffer-size 0)
        (progn
          (setf (channel-buffer channel) (make-queue buffer-size))
          (setf (channel-buffered-p channel) t))
        (setf (channel-buffer channel) *secret-unbound-value*))
    channel))

(defun channel-full-p (channel)
  (bt:with-recursive-lock-held ((channel-lock channel))
    (if (channel-buffered-p channel)
        (queue-full-p (channel-buffer channel))
        (not (eq (channel-buffer channel) *secret-unbound-value*)))))

(defun channel-empty-p (channel)
  (bt:with-recursive-lock-held ((channel-lock channel))
    (if (channel-buffered-p channel)
        (queue-empty-p (channel-buffer channel))
        (eq (channel-buffer channel) *secret-unbound-value*))))

(defun send-blocks-p (channel)
  "True if trying to send something into the channel would block."
  (bt:with-recursive-lock-held ((channel-lock channel))
    (if (channel-buffered-p channel)
        (and (channel-full-p channel) (not (channel-being-read-p channel)))
        (or (channel-full-p channel) (not (channel-being-read-p channel))))))

(defun recv-blocks-p (channel)
  "True if trying to recv from the channel would block."
  (bt:with-recursive-lock-held ((channel-lock channel))
    (and (channel-empty-p channel) (not (channel-being-written-p channel)))))

(defmacro with-write-state ((channel) &body body)
  `(unwind-protect
        (progn (setf (channel-being-written-p ,channel) t)
               ,@body)
     (setf (channel-being-written-p ,channel) nil)))

(defun send (channel obj)
  (with-accessors ((lock channel-lock)
                   (recv-ok channel-recv-ok))
      channel
    (bt:with-recursive-lock-held (lock)
      (with-write-state (channel)
        (wait-to-send channel)
        (channel-insert-value channel obj)
        (bt:condition-notify recv-ok)
        obj))))

(defun wait-to-send (channel)
  (loop while (send-blocks-p channel)
     do (bt:condition-wait (channel-send-ok channel) (channel-lock channel))))

(defun channel-insert-value (channel value)
  (if (channel-buffered-p channel)
      (enqueue value (channel-buffer channel))
      (setf (channel-buffer channel) value)))

(defmacro with-read-state ((channel) &body body)
  `(unwind-protect
        (progn (setf (channel-being-read-p ,channel) t)
               ,@body)
     (setf (channel-being-read-p ,channel) nil)))

(defun recv (channel)
  (with-accessors ((lock channel-lock)
                   (send-ok channel-send-ok))
      channel
    (bt:with-recursive-lock-held (lock)
      (with-read-state (channel)
        (bt:condition-notify send-ok)
        (wait-to-recv channel)
        (channel-grab-value channel)))))

(defun wait-to-recv (channel)
  (loop while (recv-blocks-p channel)
     do (bt:condition-wait (channel-recv-ok channel) (channel-lock channel))))

(defun channel-grab-value (channel)
  (if (channel-buffered-p channel)
      (dequeue (channel-buffer channel))
      (prog1 (channel-buffer channel)
        (setf (channel-buffer channel) *secret-unbound-value*))))

;;;
;;; Selecting channels
;;;
(defun recv-select (channels &optional (else-value nil else-value-p))
  "Selects a single channel from CHANNELS (a sequence) with input available and returns the result
of calling RECV on it. If no channels have available input, blocks until it can RECV from one of
them. If ELSE-VALUE is provided, RECV-SELECT returns that value immediately if no channels are
ready."
  (loop for ready-channel = (find-if-not #'recv-blocks-p channels)
     if ready-channel
     return (recv ready-channel)
     else if else-value-p
     return else-value))

(defun send-select (value channels &optional (else-value nil else-value-p))
  "Selects a single channel from CHANNELS (a sequence) that is ready for input and sends VALUE into it.
If no channels are ready for input, blocks until it can SEND to one of them. If ELSE-VALUE is
provided, SEND-SELECT returns that value immediately if no channels are ready."
  (loop for ready-channel = (find-if-not #'send-blocks-p channels)
     if ready-channel
     return (send ready-channel value)
     else if else-value-p
     return else-value))

;;; Select macro
(defmacro select (&body body)
  "Non-deterministically select a non-blocking clause to execute.

The syntax is:

   select clause*
   clause ::= (op form*)
   op ::= (recv chan variable) | (send chan value)
          | (seq-send (list chan*) value) | (seq-recv (list chan*) variable)
          | else | otherwise | t
   chan ::= An evaluated form representing a channel
   variable ::= an unevaluated symbol RECV's return value is to be bound to. Made available to form*.
   value ::= An evaluated form representing a value to send into the channel.

SELECT will first attempt to find a non-blocking channel clause. If all channel clauses would block,
and no else clause is provided, SELECT will block until one of the clauses is available for
execution."
  `(select-from-clauses
    (list ,@(loop for clause in body
               collect (clause->make-clause-object clause)))))

(defun determine-op (clause)
  (cond ((and (not (listp (car clause)))
              (or (eq t (car clause))
                  (equal "ELSE" (symbol-name (car clause)))
                  (equal "OTHERWISE" (symbol-name (car clause)))))
         :else)
        ((listp (car clause))
         (let ((clause-name (symbol-name (caar clause))))
           (cond ((string= clause-name "SEND") :send)
                 ((string= clause-name "RECV") :recv)
                 ((string= clause-name "SEQ-SEND") :seq-send)
                 ((string= clause-name "SEQ-RECV") :seq-recv)
                 (t (error "Invalid clause type ~A" (car clause))))))
        (t (error "Invalid clause type ~A" (car clause)))))

(defun clause->make-clause-object (clause)
  (let ((op (determine-op clause)))
    (multiple-value-bind (channel body)
        (parse-clause op clause)
      `(make-clause-object ,op ,channel ,body))))

(defun parse-clause (op clause)
  (let (channel body)
    (case op
      (:else
       (setf body (cdr clause)))
      (:send
       (setf channel (cadar clause))
       (setf body clause))
      (:recv
       (setf channel (cadar clause))
       (setf body (if (= 3 (length (car clause)))
                      `((let ((,(third (car clause)) ,(butlast (car clause))))
                          ,@(cdr clause)))
                      clause)))
      (:seq-send
       (setf channel (cadar clause))
       (setf body `((chanl::send-select ,(third (car clause)) ,(cadar clause))
                    ,@(cdr clause))))
      (:seq-recv
       (setf channel (cadar clause))
       (setf body (if (= 3 (length (car clause)))
                      `((let ((,(third (car clause)) (chanl::recv-select ,(cadar clause))))
                          ,@(cdr clause)))
                      `((chanl::recv-select (cadar clause)) ,@(cdr clause))))))
    (values channel `(lambda () ,@body))))

;;; Functional stuff
(defun select-from-clauses (clauses)
  ;; TODO - This will cause serious CPU thrashing if there's no else clause in SELECT.
  ;;        Perhaps there's a way to alleviate that using condition-vars? Or even channels?
  (let ((send/recv (remove-if-not (fun (not (eq :else (clause-object-op _))))
                                  clauses))
        (else-clause (find-if (fun (eq :else (clause-object-op _))) clauses)))
    (loop
       for ready-clause = (find-if-not #'clause-blocks-p send/recv)
       if ready-clause
       return (funcall (clause-object-function ready-clause))
       else if else-clause
       return (funcall (clause-object-function else-clause)))))

(defstruct (clause-object (:constructor make-clause-object (op channel function)))
  op channel function)

(defun clause-blocks-p (clause)
  (case (clause-object-op clause)
    ;; This is problematic. There's no guarantee that the clause will be non-blocking by the time
    ;; it actually executes...
    (:send (send-blocks-p (clause-object-channel clause)))
    (:recv (recv-blocks-p (clause-object-channel clause)))
    (:seq-send (find-if #'send-blocks-p (clause-object-channel clause)))
    (:seq-recv (find-if #'recv-blocks-p (clause-object-channel clause)))
    (:else nil)
    (otherwise (error "Invalid clause op."))))
