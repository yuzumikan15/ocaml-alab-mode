;; set the path to expander*
(defvar path "/Users/YukiIshii/lab/expander/expander")

(defun set-alab-mode-key ()
  (interactive)
  (mapc 'set-global-key '(
			  ("\C-cg" . 'agda2-go)
			  ("\C-cr" . 'refine-goal)
			  ("\C-c," . 'refine-goal-with-argument)
			  ("\C-cm" . 'match-variable)
			  ("\C-cc" . 'agda2-forget-this-goal)
			  ("\C-cf" . 'agda2-forget-all-goals)
			  ("\C-ci" . 'refine-if-statement)
			  ("\C-cs" . 'show-goal)
			  ("\C-ch" . 'put-hole)
			  )
	))

(defun set-global-key (key)
  (global-set-key (car key) (car (last key))))

;; goal position and number
(defun agda2-goal-at(pos)
  "Return (goal overlay, goal number) at POS, or nil."
  (let ((os (and pos (overlays-at pos))) o g)
    (while (and os (not(setq g (overlay-get (setq o (pop os)) 'agda2-gn)))))
    (if g (list o g))))

(defun agda2-goal-overlay (g)
  "Returns the overlay of goal number G, if any."
  (car
   (remove nil
           (mapcar (lambda (o) (if (equal (overlay-get o 'agda2-gn) g) o))
                   (overlays-in (point-min) (point-max))))))

(defun agda2-range-of-goal (g)
  "The range of goal G."
  (let ((o (agda2-goal-overlay g)))
    (if o (list (overlay-start o) (overlay-end o)))))

;; from annotation.el
(defmacro annotation-preserve-mod-p-and-undo (&rest code)
  "Run CODE preserving both the undo data and the modification bit.
Modification hooks are also disabled."
  (let ((modp (make-symbol "modp")))
  `(let ((,modp (buffer-modified-p))
         ;; Don't check if the file is being modified by some other process.
         (buffer-file-name nil)
         ;; Don't record those changes on the undo-log.
         (buffer-undo-list t)
         ;; Don't run modification hooks.
         (inhibit-modification-hooks t))
     (unwind-protect
         (progn ,@code)
       (restore-buffer-modified-p ,modp)))))

;; Annotation for a goal
;; exit(*{ ... }*)3
;; ----------------  overlay: agda2-gn num, face highlight, after-string num,
;;                            modification-hooks (agda2-protect-goal-markers)
;; -------           text-props: category agda2-delim1
;;             ----  text-props: category agda2-delim2

;; Char categories for the goal
(defvar agda2-open-brace "{")
(defvar agda2-close-brace " }")
(setplist 'agda2-delim1 `(display ,agda2-open-brace rear-nonsticky t
				  agda2-delim1 t))
(setplist 'agda2-delim2 `(display ,agda2-close-brace rear-nonsticky t
				  agda2-delim2 t))

(defun agda2-make-goal (p q r)
  "Make a goal at exit(\*{<p>...<q>}\*)n<r>."
  (annotation-preserve-mod-p-and-undo
   (let ((n (buffer-substring (+ q 3) r))
	 (o (make-overlay (- p 7) r nil t nil)))
      ;;(print n)
      (add-text-properties (- p 7) p '(category agda2-delim1))
      (add-text-properties q r '(category agda2-delim2))
      (overlay-put o 'agda2-gn           n)
      (overlay-put o 'modification-hooks '(agda2-protect-goal-markers))
      (overlay-put o 'face               'highlight)
      (overlay-put o 'after-string       (propertize (format "%s" n) 'face 'highlight))
      o )))

(defun agda2-protect-goal-markers (ol action beg end &optional length)
  "Ensures that the goal markers cannot be tampered with.
Except if `inhibit-read-only' is non-nil or /all/ of the goal is
modified."
  (if action
      ;; This is the after-change hook.
      nil
    ;; This is the before-change hook.
    (cond
     ((and (<= beg (overlay-start ol)) (>= end (overlay-end ol)))
      ;; The user is trying to remove the whole goal:
      ;; manually evaporate the overlay and add an undo-log entry so
      ;; it gets re-added if needed.
      (when (listp buffer-undo-list)
        (push (list 'apply 0 (overlay-start ol) (overlay-end ol)
                    'move-overlay ol (overlay-start ol) (overlay-end ol))
              buffer-undo-list))
      (delete-overlay ol))
     ((or (< beg (+ (overlay-start ol) 2))
          (> end (- (overlay-end ol) 2)))
      (unless inhibit-read-only
        (signal 'text-read-only nil))))))

;; for gensym
(defvar hole-number 0)

(defun gensym ()
  (setq hole-number (+ hole-number 1))
  )

(defun insert-hole-number (start)
  (goto-char start)
  (insert (number-to-string hole-number))
  )

(defun agda2-search-goal ()
  (if (re-search-forward "exit(\\*{" nil t 1)
    (let ((p (point))) ;; exit(\\*{<p>...
      (if (re-search-forward "}\\*)" nil t 1)
	  (progn
	    (let ((q (- (point) 3))) ;; <q>}\\*)
	      ;; remove hole number if the hole has
	      (goto-char q)
	      (cond ((re-search-forward "}\\*)[ \t\n\r\f\v]" nil t 1)
		     (let ((start (- (point) 1))) ;; }\\*)<start>
		       ;; no need to delete hole number
		       (progn
			 (insert-hole-number start)
			 (goto-char q)
			 (if (re-search-forward "}\\*)[0-9]+" nil t 1)
			     (let ((r (point))) ;; }\\*)123<r>
			       (agda2-make-goal p q r)))
		       )))
		    ((re-search-forward "}\\*)[0-9]+" nil t 1)
		     (progn
		       (let ((end (point))) ;; }\\*)[0-9]+<end>
			 (re-search-backward "[0-9]+" nil t 1)
			 (let ((start (point))) ;; }\\*)<start>[0-9]+
			   (delete-region start end)
			   (insert-hole-number start)
			   (let ((r (point))) ;; }\\*)123<r>
			     (agda2-make-goal p q r)
			   ))))
		     )))
	      )))))

(defun agda2-go ()
  (interactive)
  (progn
    (agda2-forget-all-goals)
    (goto-char (point-min))
    (setq hole-number 0)
    (while (agda2-search-goal)
      (gensym)
      ;;(print hole_number)
	   ; no body
      )))

;; TODO:
;; 9. refine or match goal only when (position) is in the goal
;; 11. compile to check errors before agda2-go (load) before refine and match goal
;; 12. begin ... end
;; 14. support show-goal (and its env): split-window, generate-new-buffer etc.*

(defun get-variable (word)
  (string-match "[a-z0-9A-Z]+" word)
  (match-string 0 word))

(defun put-hole ()
  (interactive)
  (insert "exit(*{ }*)")
  )

(defun refine-goal-with-argument () ;; need to compile to type check
  (interactive)
  (let* ((overlay_and_position (agda2-goal-at (point)))
	 (range (agda2-range-of-goal (car (cdr overlay_and_position))))
	 (start (car range))
	 (end (car (last range)))
	 (word (buffer-substring (+ start 7) (- end 4)))
	 (var (get-variable word))
    	 (filename (buffer-file-name))
	 (num (get-hole-number)))
    (progn
      ;; delete this hole and insert the expression that user input
      (agda2-reset) ;; delete this hole
      (insert word) ;; insert expression ;; TODO: fix the regular expression to get `word`
      ;; create buffer for return value from expander
      (generate-new-buffer "expander-buffer")
      ;; save
      (save-buffer)
      (let ((refine-buffer (buffer-name))) ;; current buffer name
      	;;	(split-window-below)
      	;;	(set-window-buffer nil "expander-buffer")
      	(call-process path nil "expander-buffer" nil filename num "RefineArg" var)
	(let ((answer (with-current-buffer "expander-buffer"
			(buffer-string))
      			))
	  (if (or (string-match "Error:*" answer)  (string-match "Warning*" answer))
	      (message "%s" answer)
	    (progn
	      (insert answer)
	      (ocp-indent-buffer)
	      (save-buffer)
	      (agda2-go) ;; reset all the hole numbers
	      ))
	  (kill-buffer "expander-buffer")
      	    ))
      )))
      
      ;; ;; create buffer for return value from expander
      ;; (generate-new-buffer "expander-buffer")
      ;; ;; save
      ;; (save-buffer)
      ;; (let ((refine-buffer (buffer-name))) ;; current buffer name
      ;; 	;;	(split-window-below)
      ;; 	;;	(set-window-buffer nil "expander-buffer")
      ;; 	(call-process "/Users/YukiIshii/lab/expander/expander" nil "expander-buffer" nil filename num "RefineArg" var)
      ;; 	(progn
      ;; 	  (let ((answer (with-current-buffer "expander-buffer"
      ;; 			  (buffer-string))
      ;; 			))
      ;; 	    (if (or (string-match "Error:*" answer)  (string-match "Warning*" answer))
      ;; 		(message "%s" answer)
      ;; 	      (progn
      ;; 		(print answer)
      ;; 		(agda2-reset)
      ;; 		(insert answer)
      ;; 		(ocp-indent-buffer)
      ;; 		(save-buffer)
      ;; 		(agda2-go) ;; reset all the hole numbers
      ;; 		)
      ;; 	      )
      ;; 	    (kill-buffer "expander-buffer")
      ;; 	    ))
      ;; 	  ))))
  
 (defun refine-goal ()
  (interactive)
  (let ((filename (buffer-file-name))
	(num (get-hole-number)))
    (progn
      ;; create buffer for return value from expander
      (generate-new-buffer "expander-buffer")
      ;; save
      (save-buffer)
      (let ((refine-buffer (buffer-name))) ;; current buffer name
;;	(split-window-below)
;;	(set-window-buffer nil "expander-buffer")
	(call-process path nil "expander-buffer" nil filename num "Refine")
	(progn
	  (let ((answer (with-current-buffer "expander-buffer"
			  (buffer-string))
			  ))
	    (if (or (string-match "Error:*" answer)  (string-match "Warning*" answer))
		(message "%s" answer)
	      (progn
		(agda2-reset)
		(insert answer)
		(ocp-indent-buffer)
		(save-buffer)
		;;(agda2-go)
		)
	      )
	    (kill-buffer "expander-buffer")
	    ))
	))))

(defun match-variable ()
  (interactive)
   (let* ((overlay_and_position (agda2-goal-at (point)))
	 (range (agda2-range-of-goal (car (cdr overlay_and_position))))
	 (start (car range))
	 (end (car (last range)))
	 (word (buffer-substring (+ start 7) (- end 4)))
	 (var (get-variable word))
    	 (filename (buffer-file-name))
	 (num (get-hole-number)))
     (progn
       (generate-new-buffer "expander-buffer")
       (save-buffer)
       (call-process path nil "expander-buffer" nil filename num "Match" var)
       (progn
	 (let ((answer (with-current-buffer "expander-buffer"
			 (buffer-string))
		       ))
	   (if (or (string-match "Error:*" answer) (string-match "Warning*" answer))
	       (message "%s" answer)
	     (progn
	       (agda2-reset)
	       (insert answer)
	       (ocp-indent-buffer)
	       (save-buffer)
	       (agda2-go)
	       ))
	   (kill-buffer "expander-buffer")
	   )))))

(defun refine-if-statement ()
  (interactive)
  (let ((filename (buffer-file-name))
	 (num (get-hole-number)))
    (progn
      (generate-new-buffer "expander-buffer")
      (save-buffer)
      (call-process path nil "expander-buffer" nil filename num "If")
      (progn
	(let ((answer (with-current-buffer "expander-buffer"
			(buffer-string))))
	  (if (or (string-match "Error:*" answer) (string-match "Warning*" answer))
	      (message "%s" answer)
	    (progn
	      (agda2-reset)
	      (insert answer)
	      (ocp-indent-buffer)
	      (save-buffer)
	      (agda2-go)
	      ))
	  (kill-buffer "expander-buffer")
	  )))))

(defun show-goal ()
  (interactive)
   (let ((filename (buffer-file-name))
	 (num (get-hole-number)))
     (progn
      (generate-new-buffer "expander-buffer")
      (save-buffer)
      (call-process path nil "expander-buffer" nil filename num "ShowGoal")
      (progn
	(let ((answer (with-current-buffer "expander-buffer"
			(buffer-string))))
	  (message answer)
	  (kill-buffer "expander-buffer")
	  )))))

(defun get-hole-number ()
   (goto-char (point))
   (if (re-search-backward "{" nil t 1)
       ;;(let ((p (point)))
       (if (re-search-forward "}" nil t 1)
	   ;;(let ((q (- (point) 3)))
	   (if (re-search-forward "[0-9]+" nil t 1)
	       (let ((r (point)))
		 (buffer-substring (- r 1) r)
		 )))))

;; erase hole
;;  (add-text-properties (- p 7) p '(category agda2-delim1))
;;  (add-text-properties q r '(category agda2-delim2))
(defun agda2-remove-hole ()
  (progn
    (agda2-search-hole-backward)
    (goto-char (point))
    ;; remove hole
    (if (re-search-backward "exit(\\*{" nil t 1)
	(let ((p (point)))
	  (if (re-search-forward "}\\*)" nil t 1)
	      (let ((q (- (point) 3)))
		(if (re-search-forward "[0-9]+" nil t 1)
		    (let ((r (point)))
;;		      (print "delete-region")
		      (delete-region p r)))))))
    ))

(defun delete-lays (lays)
  (let (value)
    (dolist (elt lays value)
      (delete-overlay elt)))) ;; e.g. {v }3 with highlight -> {v } without highlight
  
(defun agda2-reset ()
  ;;(interactive)
  (progn
    (goto-char (point))
    ;; (agda2-search-hole)))
    (while (agda2-remove-hole)
      ;; no body
      )))

(defun agda2-search-hole-backward ()
  (if (re-search-backward "exit(\\*{" nil t 1)
    (let ((p (point)))
      (if (re-search-forward "}\\*)" nil t 1)
	(let ((q (point)))
	  (if (re-search-forward "[0-9]+" nil t 1)
	      (let* ((r (point))
		     (lays (overlays-in p r)))
		(delete-lays lays) ;; delete hole number and highlight
		;; remove text properties -> exit(*{ }*)n appears
		(remove-text-properties (- p 7) p '(category agda2-delim1))
		(remove-text-properties (- q 3) r '(category agda2-delim2))
		(goto-char (point))
	  	)
	    )
	  )))))

;; clear all the holes in *.ml
(defun agda2-search-hole ()
  (if (re-search-forward "exit(\\*{" nil t 1)
    (let ((p (point)))
      (if (re-search-forward "}\\*)" nil t 1)
	(let ((q (point)))
	  (if (re-search-forward "[0-9]+" nil t 1)
	      (let* ((r (point))
		     (lays (overlays-in p r)))
		(delete-lays lays) ;; delete hole number and highlight
		;; remove text properties -> exit(*{ }*)n appears
		(remove-text-properties (- p 7) p '(category agda2-delim1))
		(remove-text-properties (- q 3) r '(category agda2-delim2))
		(goto-char (point))
	  	)
	    )
	  )))))

(defun agda2-forget-this-goal ()
  (interactive)
  (goto-char (point))
  (agda2-search-hole-backward)
  (agda2-remove-hole))

(defun agda2-forget-all-goals ()
  (interactive)
  (progn
    (goto-char (point-min))
    (while (agda2-search-hole)
      ;; no body
      )))
