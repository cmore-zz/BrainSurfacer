;;; brainsurfacer-tests.el --- Tests for brainsurfacer.el -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'org)
(require 'brainsurfacer)

(defvar brainsurfacer-test-eligible nil)

(defun brainsurfacer-test-buffer-predicate (buffer)
  "Return BUFFER's test eligibility marker."
  (buffer-local-value 'brainsurfacer-test-eligible buffer))

(defun brainsurfacer-test-make-buffer (name path)
  "Create an eligible test buffer named NAME visiting PATH logically."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (setq buffer-file-name path)
      (setq-local brainsurfacer-test-eligible t))
    buffer))

(ert-deftest brainsurfacer-mode-based-eligibility-ignores-extension ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/outline.txt")
    (org-mode)
    (should (brainsurfacer-org-or-markdown-buffer-p (current-buffer)))
    (fundamental-mode)
    (should-not (brainsurfacer-org-or-markdown-buffer-p (current-buffer)))))

(ert-deftest brainsurfacer-buffer-path-omits-remote-files ()
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name "/ssh:example.test:/notes/remote.org")
    (should-not
     (brainsurfacer-org-or-markdown-buffer-p (current-buffer)))
    (should-not (brainsurfacer--buffer-path (current-buffer)))))

(ert-deftest brainsurfacer-snapshot-classifies-selected-visible-and-open ()
  (let* ((selected-buffer
          (brainsurfacer-test-make-buffer
           " *brainsurfacer-selected*" "/notes/selected.org"))
         (visible-buffer
          (brainsurfacer-test-make-buffer
           " *brainsurfacer-visible*" "/notes/visible.md"))
         (open-buffer
          (brainsurfacer-test-make-buffer
           " *brainsurfacer-open*" "/notes/open.org"))
         (brainsurfacer-buffer-predicate
          #'brainsurfacer-test-buffer-predicate))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-window-buffer (selected-window) selected-buffer)
          (let ((other-window (split-window-right)))
            (set-window-buffer other-window visible-buffer))
          (let ((snapshot (brainsurfacer--snapshot)))
            (should (equal (plist-get snapshot :selected)
                           '("/notes/selected.org")))
            (should (equal (plist-get snapshot :visible)
                           '("/notes/visible.md")))
            (should (equal (plist-get snapshot :open)
                           '("/notes/open.org")))))
      (mapc (lambda (buffer)
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))
            (list selected-buffer visible-buffer open-buffer)))))

(ert-deftest brainsurfacer-snapshot-bounds-paths-in-relevance-order ()
  (let* ((selected '("/notes/selected.org"))
         (visible (mapcar (lambda (index)
                            (format "/notes/visible-%03d.md" index))
                          (number-sequence 0 9)))
         (open (mapcar (lambda (index)
                         (format "/notes/open-%03d.md" index))
                       (number-sequence 0 119)))
         (snapshot
          (brainsurfacer--bounded-snapshot selected visible open))
         (all-paths
          (append (plist-get snapshot :selected)
                  (plist-get snapshot :visible)
                  (plist-get snapshot :open))))
    (should (= (length all-paths) brainsurfacer--maximum-documents))
    (should (equal (car (plist-get snapshot :selected))
                   "/notes/selected.org"))
    (should (= (length (plist-get snapshot :visible)) 10))
    (should (<= (apply #'+ (mapcar #'string-bytes all-paths))
                brainsurfacer--maximum-path-bytes))))

(ert-deftest brainsurfacer-payload-uses-grouped-json-arrays ()
  (let* ((brainsurfacer-provider-id "test.emacs")
         (brainsurfacer-time-to-live 90)
         (payload
          (brainsurfacer--payload
           '(:selected ("/notes/selected.org")
             :visible ("/notes/visible.md")
             :open ("/notes/open.org"))))
         (decoded
          (json-parse-string payload :object-type 'alist :array-type 'list)))
    (should (equal (alist-get 'providerID decoded)
                   "test.emacs"))
    (should (= (alist-get 'timeToLive decoded) 90))
    (should (equal (alist-get 'selected decoded)
                   '("/notes/selected.org")))
    (should (equal (alist-get 'visible decoded)
                   '("/notes/visible.md")))
    (should (equal (alist-get 'open decoded)
                   '("/notes/open.org")))))

(ert-deftest brainsurfacer-time-to-live-is-normalized ()
  (dolist (case '((-20 1) (60 60) (600 300)))
    (let* ((brainsurfacer-time-to-live (car case))
           (payload
            (brainsurfacer--payload
             '(:selected nil :visible nil :open nil)))
           (decoded (json-parse-string payload :object-type 'alist)))
      (should (= (alist-get 'timeToLive decoded) (cadr case)))
      (should (= (brainsurfacer--normalized-time-to-live) (cadr case))))))

(ert-deftest brainsurfacer-finds-running-app-bundles-with-spaces ()
  (should
   (equal
    (brainsurfacer--running-applications-from-process-lines
     (list
      "  100 /Applications/Other.app/Contents/MacOS/Other"
      (concat
       "  4242 /Users/test/Build Products/BrainSurfacer Debug.app/Contents/MacOS/"
       "BrainSurfacer -NSDocumentRevisionsDebugMode YES")))
    '((:pid 4242
       :bundle "/Users/test/Build Products/BrainSurfacer Debug.app")))))

(ert-deftest brainsurfacer-process-discovery-is-cached ()
  (let* ((temporary-root (make-temp-file "brainsurfacer app " t))
         (bundle (expand-file-name "BrainSurfacer.app" temporary-root))
         (helper
          (expand-file-name
           "Contents/Helpers/brainsurfacer-context" bundle))
         (command
          (concat "  4242 " bundle "/Contents/MacOS/BrainSurfacer"))
         (brainsurfacer-command nil)
         (brainsurfacer-require-running-app t)
         (brainsurfacer-discovery-cooldown 10)
         (brainsurfacer--discovery-cache nil)
         (calls 0))
    (unwind-protect
        (progn
          (make-directory (file-name-directory helper) t)
          (write-region "" nil helper nil 'silent)
          (set-file-modes helper #o755)
          (cl-letf (((symbol-function 'brainsurfacer--process-lines)
                     (lambda ()
                       (setq calls (1+ calls))
                       (list command)))
                    ((symbol-function 'brainsurfacer--process-id-live-p)
                     (lambda (_process-id) t)))
            (should (equal (brainsurfacer--discover-helper) helper))
            (should (equal (brainsurfacer--discover-helper) helper))
            (should (= calls 1))))
      (delete-directory temporary-root t))))

(ert-deftest brainsurfacer-stale-running-process-invalidates-cache ()
  (let* ((temporary-root (make-temp-file "brainsurfacer app " t))
         (bundle (expand-file-name "BrainSurfacer.app" temporary-root))
         (helper
          (expand-file-name
           "Contents/Helpers/brainsurfacer-context" bundle))
         (command
          (concat "  4242 " bundle "/Contents/MacOS/BrainSurfacer"))
         (brainsurfacer-command nil)
         (brainsurfacer-require-running-app t)
         (brainsurfacer-discovery-cooldown 10)
         (brainsurfacer--discovery-cache nil)
         (calls 0))
    (unwind-protect
        (progn
          (make-directory (file-name-directory helper) t)
          (write-region "" nil helper nil 'silent)
          (set-file-modes helper #o755)
          (cl-letf (((symbol-function 'brainsurfacer--process-lines)
                     (lambda ()
                       (setq calls (1+ calls))
                       (when (= calls 1) (list command))))
                    ((symbol-function 'brainsurfacer--process-id-live-p)
                     (lambda (_process-id) nil)))
            (should (equal (brainsurfacer--discover-helper) helper))
            (should-not (brainsurfacer--discover-helper))
            (should (= calls 2))))
      (delete-directory temporary-root t))))

(ert-deftest brainsurfacer-negative-process-discovery-is-cached ()
  (let ((brainsurfacer-command nil)
        (brainsurfacer-require-running-app t)
        (brainsurfacer-discovery-cooldown 10)
        (brainsurfacer--discovery-cache nil)
        (calls 0))
    (cl-letf (((symbol-function 'brainsurfacer--process-lines)
               (lambda ()
                 (setq calls (1+ calls))
                 nil)))
      (should-not (brainsurfacer--discover-helper))
      (should-not (brainsurfacer--discover-helper))
      (should (= calls 1)))))

(ert-deftest brainsurfacer-mode-installs-file-window-and-focus-hooks ()
  (brainsurfacer-mode -1)
  (let ((after-focus-change-function #'ignore)
        (focus-schedules 0))
    (cl-letf (((symbol-function 'brainsurfacer--schedule)
               (lambda (&optional _force)
                 (setq focus-schedules (1+ focus-schedules))))
              ((symbol-function 'brainsurfacer--start-heartbeat) #'ignore)
              ((symbol-function 'brainsurfacer--send-payload) #'ignore))
      (unwind-protect
          (progn
            (brainsurfacer-mode 1)
            (should (memq #'brainsurfacer--handle-state-change find-file-hook))
            (when (boundp 'window-buffer-change-functions)
              (should
               (memq #'brainsurfacer--handle-state-change
                     window-buffer-change-functions)))
            (setq focus-schedules 0)
            (funcall after-focus-change-function)
            (should (= focus-schedules 1)))
        (brainsurfacer-mode -1)))
    (setq focus-schedules 0)
    (funcall after-focus-change-function)
    (should (= focus-schedules 0)))
  (should-not (memq #'brainsurfacer--handle-state-change find-file-hook))
  (should-not
   (advice-member-p #'brainsurfacer--handle-focus-change
                    after-focus-change-function)))

(provide 'brainsurfacer-tests)

;;; brainsurfacer-tests.el ends here
