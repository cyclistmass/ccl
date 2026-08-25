;;; -*- Mode: Lisp -*-
;;; wb-bench.lisp -- multi-thread microbenchmarks for the arm64 write barrier.
;;;
;;; An earlier version crashed at a bench boundary: udf #0 at a heap
;;; PC, right where fresh toplevel closures get compiled mid-run and a new
;;; thread on the other core executes them.  v2 removes ALL mid-run
;;; compilation: every worker and the whole driver are load-time DEFUNs and
;;; one toplevel call runs everything.  If v2 does NOT crash where v1 did,
;;; that is evidence toward the fresh-code-cross-core class (not proof).
;;;
;;; Also changed vs v1: ATOMIC-2T-SEP pads the two cells apart (v1 measured
;;; adjacent conses = false sharing, bimodal 5x); a deliberate
;;; ATOMIC-2T-FALSESHARE bench keeps that measurement on purpose; the
;;; crash-adjacent LOCK-2T-SEP runs LAST so everything else lands first.

(in-package :cl-user)

(defmacro p (fmt &rest args)
  `(progn (format t "~&P| ~@?~%" ,fmt ,@args) (finish-output)))

(defconstant +ns-per-itu+ (floor 1000000000 internal-time-units-per-second))
(defun now-ns () (* (get-internal-real-time) +ns-per-itu+))

(defun run-workers (nthreads fn &key (timeout 120))
  (let* ((start (ccl:make-semaphore))
         (done  (ccl:make-semaphore))
         (ws '()))
    (dotimes (k nthreads)
      (let ((kk k))
        (push (ccl:process-run-function (format nil "bench-w~d" kk)
                                        (lambda ()
                                          (ccl:wait-on-semaphore start)
                                          (funcall fn kk)
                                          (ccl:signal-semaphore done)))
              ws)))
    (let ((t0 (now-ns)))
      (dotimes (k nthreads) (ccl:signal-semaphore start))
      (let ((ok t))
        (dotimes (k nthreads)
          (unless (ccl:timed-wait-on-semaphore done timeout) (setq ok nil)))
        (cond (ok (- (now-ns) t0))
              (t (dolist (w ws) (ignore-errors (ccl:process-kill w)))
                 nil))))))

(defun median (list)
  (let* ((s (sort (copy-list list) #'<)) (n (length s)))
    (if (oddp n) (nth (floor n 2) s)
        (/ (+ (nth (1- (floor n 2)) s) (nth (floor n 2) s)) 2))))

(defun report (bench nt reps-ns ops)
  (let ((i 0))
    (dolist (ns reps-ns)
      (p "BENCH=~a NT=~d REP=~d NS=~d OPS=~d NSOP=~,1f"
         bench nt (incf i) ns ops (/ ns (float ops)))))
  (when reps-ns
    (let* ((m (median reps-ns))
           (spread (if (zerop m) 0
                       (* 100.0 (/ (- (reduce #'max reps-ns) (reduce #'min reps-ns))
                                   (float m))))))
      (p "SUMMARY BENCH=~a NT=~d REPS=~d MEDIAN_NSOP=~,1f SPREAD_PCT=~,1f"
         bench nt (length reps-ns) (/ m (float ops)) spread))))

;;; ---------------- workers (ALL compiled at load) ----------------
(defun atomic-worker (cell m)
  (declare (fixnum m))
  (dotimes (i m) (ccl::atomic-incf (car cell))))

(defun lock-worker (lk m)
  (declare (fixnum m))
  (dotimes (i m) (ccl:with-lock-grabbed (lk))))

(defun wb-worker (v val start end step)
  (declare (optimize (speed 3) (safety 0))
           (simple-vector v) (fixnum start end step))
  (do ((i start (+ i step)))
      ((>= i end) nil)
    (declare (fixnum i))
    (setf (svref v i) val)))

(defun alloc-worker (m)
  (declare (fixnum m) (optimize (speed 3) (safety 0)))
  (let ((x nil))
    (dotimes (i m) (setq x (cons i nil)))
    x))

(defun ping-worker (s1 s2 m)
  (declare (fixnum m))
  (dotimes (i m)
    (ccl:signal-semaphore s1)
    (ccl:wait-on-semaphore s2)))

(defun pong-worker (s1 s2 m)
  (declare (fixnum m))
  (dotimes (i m)
    (ccl:wait-on-semaphore s1)
    (ccl:signal-semaphore s2)))

;;; closure makers, compiled at load; nothing compiles mid-run
(defun make-atomic-fn (c0 c1 m) (lambda (k) (atomic-worker (if (eql k 0) c0 c1) m)))
(defun make-lock-fn (l0 l1 m) (lambda (k) (lock-worker (if (eql k 0) l0 l1) m)))
(defun make-1t-atomic-fn (c m) (lambda (k) (declare (ignore k)) (atomic-worker c m)))
(defun make-1t-lock-fn (l m) (lambda (k) (declare (ignore k)) (lock-worker l m)))
(defun make-1t-alloc-fn (m) (lambda (k) (declare (ignore k)) (alloc-worker m)))
(defun make-1t-wb-fn (v val) (lambda (k) (declare (ignore k)) (wb-worker v val 0 (length v) 2)))
(defun make-wb-far-fn (v val)
  (let ((half (floor (length v) 2)) (n (length v)))
    (lambda (k) (if (eql k 0) (wb-worker v val 0 half 2) (wb-worker v val half n 2)))))
(defun make-wb-near-fn (v val)
  (let ((n (length v)))
    (lambda (k) (if (eql k 0) (wb-worker v val 0 n 4) (wb-worker v val 2 n 4)))))
(defun make-sem-fn (s1 s2 m)
  (lambda (k) (if (eql k 0) (ping-worker s1 s2 m) (pong-worker s1 s2 m))))

(defun far-cells ()
  ;; two counter cells guaranteed on different cache lines
  (let ((c0 (cons 0 nil)))
    (make-string 512)
    (values c0 (cons 0 nil))))

(defun near-cells ()
  ;; two ADJACENT conses: one dnode apart, same 64-byte line (usually)
  (let* ((c0 (cons 0 nil)) (c1 (cons 0 nil)))
    (values c0 c1)))

;;; wb rep: fresh vector, tenure, young value; returns ns or nil
(defun wb-rep (mode)
  (let* ((old-val (cons :old nil))
         (v (make-array (expt 2 20) :initial-element nil)))
    (ccl:gc) (ccl:gc)
    (let* ((young-val (cons :young nil))
           (memo-ok (> (ccl:%address-of young-val) (ccl:%address-of v)))
           (val (ecase mode
                  ((:young :far :near) young-val)
                  (:old old-val)
                  (:fixnum 7))))
      (when (and (not (eq mode :old)) (not (eq mode :fixnum)) (not memo-ok))
        (p "WB WARNING mode=~a memoize path NOT asserted" mode))
      (ecase mode
        ((:young :old :fixnum) (run-workers 1 (make-1t-wb-fn v val)))
        (:far  (run-workers 2 (make-wb-far-fn v val)))
        (:near (run-workers 2 (make-wb-near-fn v val)))))))

(defun bench-reps (n fn)
  (let ((acc '()))
    (dotimes (r n)
      (let ((ns (funcall fn))) (when ns (push ns acc))))
    acc))

(defun run-all ()
  (p "PROV version=~a" (lisp-implementation-version))
  (p "PROV itups=~d" internal-time-units-per-second)
  (let ((ns (run-workers 2 (lambda (k) (declare (ignore k)) nil) :timeout 15)))
    (p "SMOKE threads=2 ~a" (if ns "OK" "TIMEOUT-FAIL")))
  ;; ---- WB ----
  (let ((ops (floor (expt 2 20) 2)))
    (dolist (mode '(:young :old :fixnum))
      (report (format nil "WB-1T-~a" mode) 1 (bench-reps 5 (lambda () (wb-rep mode))) ops))
    (dolist (mode '(:far :near))
      (report (format nil "WB-2T-~a" mode) 2 (bench-reps 5 (lambda () (wb-rep mode))) ops)))
  ;; ---- ALLOC ----
  (let ((m 2000000) (g0 (ccl::full-gccount)))
    (report "ALLOC-1T" 1
            (bench-reps 7 (lambda () (run-workers 1 (make-1t-alloc-fn m)))) m)
    (report "ALLOC-2T-PAR" 2
            (bench-reps 7 (lambda () (run-workers 2 (make-1t-alloc-fn m)))) (* 2 m))
    (report "ALLOC-2T-SEQ-CONTROL" 1
            (bench-reps 5 (lambda ()
                            (let ((n1 (run-workers 1 (make-1t-alloc-fn m)))
                                  (n2 (run-workers 1 (make-1t-alloc-fn m))))
                              (and n1 n2 (+ n1 n2)))))
            (* 2 m))
    (p "ALLOC full-gccount-delta=~d" (- (ccl::full-gccount) g0)))
  ;; ---- SEM ----
  (let ((m 20000))
    (report "SEM-PINGPONG" 2
            (bench-reps 5 (lambda ()
                            (let ((s1 (ccl:make-semaphore)) (s2 (ccl:make-semaphore)))
                              (run-workers 2 (make-sem-fn s1 s2 m)))))
            m))
  ;; ---- ATOMIC ----
  (let ((m 1000000))
    (report "ATOMIC-1T" 1
            (bench-reps 7 (lambda () (run-workers 1 (make-1t-atomic-fn (cons 0 nil) m)))) m)
    (let ((reps '()) (checks '()))
      (dotimes (r 7)
        (let* ((cell (cons 0 nil))
               (ns (run-workers 2 (make-1t-atomic-fn cell m))))
          (when ns (push ns reps) (push (car cell) checks))))
      (report "ATOMIC-2T-SHARED" 2 reps (* 2 m))
      (p "CHECK ATOMIC-2T-SHARED all-ok=~a" (every (lambda (c) (= c (* 2 m))) checks)))
    (report "ATOMIC-2T-SEP" 2
            (bench-reps 7 (lambda ()
                            (multiple-value-bind (c0 c1) (far-cells)
                              (run-workers 2 (make-atomic-fn c0 c1 m)))))
            (* 2 m))
    (report "ATOMIC-2T-FALSESHARE" 2
            (bench-reps 7 (lambda ()
                            (multiple-value-bind (c0 c1) (near-cells)
                              (run-workers 2 (make-atomic-fn c0 c1 m)))))
            (* 2 m)))
  ;; ---- LOCK (crash-adjacent variant LAST) ----
  (let ((m1 200000) (m2 100000))
    (report "LOCK-1T" 1
            (bench-reps 7 (lambda () (run-workers 1 (make-1t-lock-fn (ccl:make-lock "a") m1)))) m1)
    (report "LOCK-2T-SHARED" 2
            (bench-reps 5 (lambda ()
                            (let ((lk (ccl:make-lock "b")))
                              (run-workers 2 (make-1t-lock-fn lk m2)))))
            (* 2 m2))
    (report "LOCK-2T-SEP" 2
            (bench-reps 5 (lambda ()
                            (run-workers 2 (make-lock-fn (ccl:make-lock "c0") (ccl:make-lock "c1") m1))))
            (* 2 m1)))
  (p "DONE wb-bench"))

(run-all)
