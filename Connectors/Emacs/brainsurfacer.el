;;; brainsurfacer.el --- Report live Org/Markdown context -*- lexical-binding: t; -*-

;; Copyright (C) 2026 BrainSurfacer contributors

;; Author: BrainSurfacer contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, files, outlines
;; URL: https://github.com/cmore-zz/BrainSurfacer

;;; Commentary:

;; This global minor mode reports the selected, visible, and open file-visiting
;; Org/Markdown buffers to a running BrainSurfacer app.  It invokes the bundled
;; brainsurfacer-context helper asynchronously and sends JSON over standard
;; input, so no temporary file or shell command is involved.
;;
;; Enable it with:
;;
;;   (require 'brainsurfacer)
;;   (brainsurfacer-mode 1)
;;
;; Use `brainsurfacer-diagnose' to inspect discovery and the current snapshot.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'nadvice)
(require 'seq)
(require 'subr-x)

(defgroup brainsurfacer nil
  "Report live editor context to BrainSurfacer."
  :group 'convenience
  :prefix "brainsurfacer-")

(defcustom brainsurfacer-command nil
  "Explicit path or executable name for brainsurfacer-context.

When nil, derive the helper path from a running BrainSurfacer.app, then fall
back to `executable-find'.  Setting this does not bypass
`brainsurfacer-require-running-app'."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'brainsurfacer)

(defcustom brainsurfacer-require-running-app t
  "When non-nil, never invoke the helper unless BrainSurfacer is running.

This prevents an editor-state change from launching BrainSurfacer."
  :type 'boolean
  :group 'brainsurfacer)

(defcustom brainsurfacer-application-paths
  '("/Applications/BrainSurfacer.app" "~/Applications/BrainSurfacer.app")
  "Application bundles to try when launching BrainSurfacer is permitted.

Running application bundles discovered from the process table take priority."
  :type '(repeat directory)
  :group 'brainsurfacer)

(defcustom brainsurfacer-discovery-cooldown 10
  "Seconds to cache helper discovery, including a negative result."
  :type 'number
  :group 'brainsurfacer)

(defcustom brainsurfacer-provider-id "org.gnu.Emacs"
  "Stable provider identifier sent with each editor snapshot.

Keep the `org.gnu.Emacs' value or use an `org.gnu.Emacs.' prefix when
customizing it so BrainSurfacer's Automatic opener recognizes Emacs context."
  :type 'string
  :group 'brainsurfacer)

(defcustom brainsurfacer-time-to-live 60
  "Lifetime in seconds of each reported editor snapshot.

BrainSurfacer currently accepts values from 1 through 300."
  :type 'integer
  :group 'brainsurfacer)

(defcustom brainsurfacer-debounce-delay 0.25
  "Seconds to coalesce file, buffer, window, frame, and focus changes."
  :type 'number
  :group 'brainsurfacer)

(defcustom brainsurfacer-buffer-predicate
  #'brainsurfacer-org-or-markdown-buffer-p
  "Function deciding whether a buffer contributes editor context.

The function receives one buffer and should return non-nil only for a
file-visiting buffer that BrainSurfacer should consider."
  :type 'function
  :group 'brainsurfacer)

(defconst brainsurfacer--maximum-documents 100)
(defconst brainsurfacer--maximum-path-bytes 16384)
(defconst brainsurfacer--minimum-time-to-live 1)
(defconst brainsurfacer--maximum-time-to-live 300)

(defvar brainsurfacer--debounce-timer nil)
(defvar brainsurfacer--heartbeat-timer nil)
(defvar brainsurfacer--pending-force nil)
(defvar brainsurfacer--discovery-cache nil)
(defvar brainsurfacer--last-payload nil)
(defvar brainsurfacer--last-sent-at nil)
(defvar brainsurfacer--last-error nil)
(defvar brainsurfacer-mode nil)

(defconst brainsurfacer--state-hooks
  '(find-file-hook
    after-change-major-mode-hook
    after-set-visited-file-name-hook
    kill-buffer-hook
    buffer-list-update-hook
    window-buffer-change-functions
    window-selection-change-functions
    window-state-change-functions
    window-configuration-change-hook
    after-make-frame-functions
    delete-frame-functions
    server-visit-hook))

(defun brainsurfacer-org-or-markdown-buffer-p (buffer)
  "Return non-nil when BUFFER visits a file in Org or Markdown mode.

Mode semantics, rather than filename extensions, determine eligibility.
Indirect buffers inherit the visited filename of their base buffer."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (let* ((base (or (buffer-base-buffer) buffer))
                (path (buffer-file-name base)))
           (and path
                (not (file-remote-p path))
                (or (derived-mode-p 'org-mode)
                    (derived-mode-p 'markdown-mode)))))))

(defun brainsurfacer--buffer-path (buffer)
  "Return BUFFER's expanded source path when it is eligible."
  (when (and (buffer-live-p buffer)
             (funcall brainsurfacer-buffer-predicate buffer))
    (with-current-buffer buffer
      (let* ((base (or (buffer-base-buffer) buffer))
             (path (buffer-file-name base)))
        (when (and path (not (file-remote-p path)))
          (expand-file-name path))))))

(defun brainsurfacer--selected-editor-window ()
  "Return the selected non-minibuffer editor window, if any."
  (let ((window (selected-window)))
    (if (window-minibuffer-p window)
        (minibuffer-selected-window)
      window)))

(defun brainsurfacer--visible-editor-windows ()
  "Return ordinary windows on visible frames."
  (cl-loop for frame in (frame-list)
           when (eq (frame-visible-p frame) t)
           append (seq-remove #'window-minibuffer-p (window-list frame))))

(defun brainsurfacer--bounded-snapshot (selected visible open)
  "Build a bounded snapshot from SELECTED, VISIBLE, and OPEN paths.

Paths are retained in relevance order, deduplicated, and bounded to the same
document-count and decoded-path-byte limits enforced by the helper."
  (let ((seen (make-hash-table :test #'equal))
        (count 0)
        (path-bytes 0)
        selected-result
        visible-result
        open-result)
    (cl-labels
        ((add-path
          (path destination)
          (let ((bytes (string-bytes path)))
            (when (and (< count brainsurfacer--maximum-documents)
                       (<= (+ path-bytes bytes)
                           brainsurfacer--maximum-path-bytes)
                       (not (gethash path seen)))
              (puthash path t seen)
              (setq count (1+ count)
                    path-bytes (+ path-bytes bytes))
              (pcase destination
                ('selected (push path selected-result))
                ('visible (push path visible-result))
                ('open (push path open-result)))))))
      (dolist (path selected)
        (add-path path 'selected))
      (dolist (path visible)
        (add-path path 'visible))
      (dolist (path open)
        (add-path path 'open)))
    (list :selected (nreverse selected-result)
          :visible (nreverse visible-result)
          :open (nreverse open-result))))

(defun brainsurfacer--snapshot ()
  "Return the current selected, visible, and open buffer snapshot."
  (let* ((selected-window (brainsurfacer--selected-editor-window))
         (selected-path
          (when (window-live-p selected-window)
            (brainsurfacer--buffer-path (window-buffer selected-window))))
         (visible-paths
          (delq nil
                (mapcar
                 (lambda (window)
                   (brainsurfacer--buffer-path (window-buffer window)))
                 (brainsurfacer--visible-editor-windows))))
         (open-paths
          (delq nil (mapcar #'brainsurfacer--buffer-path (buffer-list)))))
    (brainsurfacer--bounded-snapshot
     (if selected-path (list selected-path) nil)
     (sort (delete-dups visible-paths) #'string<)
     (sort (delete-dups open-paths) #'string<))))

(defun brainsurfacer--normalized-time-to-live ()
  "Return the configured TTL constrained to BrainSurfacer's wire limits."
  (let ((value (if (numberp brainsurfacer-time-to-live)
                   brainsurfacer-time-to-live
                 60)))
    (max brainsurfacer--minimum-time-to-live
         (min brainsurfacer--maximum-time-to-live value))))

(defun brainsurfacer--payload (snapshot)
  "Encode SNAPSHOT as connector-friendly JSON."
  (json-serialize
   `((providerID . ,brainsurfacer-provider-id)
     (timeToLive . ,(brainsurfacer--normalized-time-to-live))
     (selected . ,(vconcat (plist-get snapshot :selected)))
     (visible . ,(vconcat (plist-get snapshot :visible)))
     (open . ,(vconcat (plist-get snapshot :open))))))

(defun brainsurfacer--empty-payload ()
  "Return the JSON snapshot that clears this provider."
  (brainsurfacer--payload '(:selected nil :visible nil :open nil)))

(defun brainsurfacer--running-applications-from-process-lines (lines)
  "Extract BrainSurfacer process IDs and application bundles from ps LINES."
  (let ((regexp
         (concat
          "\\`[[:space:]]*\\([0-9]+\\)[[:space:]]+"
          "\\(.+\\.app\\)/Contents/MacOS/BrainSurfacer"
          "\\(?:[[:space:]].*\\)?\\'"))
        applications)
    (dolist (line lines)
      (when (string-match regexp line)
        (let ((application
               (list :pid (string-to-number (match-string 1 line))
                     :bundle (match-string 2 line))))
          (unless (seq-find
                   (lambda (existing)
                     (equal (plist-get existing :bundle)
                            (plist-get application :bundle)))
                   applications)
            (push application applications)))))
    (nreverse applications)))

(defun brainsurfacer--process-lines ()
  "Return full command lines for the local process table."
  (condition-case nil
      (process-lines "/bin/ps" "-ww" "-axo" "pid=,command=")
    (error nil)))

(defun brainsurfacer--process-id-live-p (process-id)
  "Return non-nil when local PROCESS-ID still exists."
  (and (integerp process-id)
       (condition-case nil
           (and (process-attributes process-id) t)
         (error nil))))

(defun brainsurfacer--resolve-command (command)
  "Resolve COMMAND to an executable path, or nil."
  (when command
    (let ((candidate
           (if (file-name-absolute-p command)
               (expand-file-name command)
             (executable-find command))))
      (when (and candidate (file-executable-p candidate))
        candidate))))

(defun brainsurfacer--helper-in-bundle (bundle)
  "Return the executable helper inside BUNDLE, or nil."
  (brainsurfacer--resolve-command
   (expand-file-name "Contents/Helpers/brainsurfacer-context" bundle)))

(defun brainsurfacer--discover-helper (&optional force)
  "Return an eligible helper path, refreshing discovery when FORCE is non-nil."
  (let* ((now (float-time))
         (checked-at (plist-get brainsurfacer--discovery-cache :checked-at)))
    (if (and (not force)
             checked-at
             (< (- now checked-at) brainsurfacer-discovery-cooldown))
        (if (and brainsurfacer-require-running-app
                 (plist-get brainsurfacer--discovery-cache :running)
                 (not (brainsurfacer--process-id-live-p
                       (plist-get brainsurfacer--discovery-cache :pid))))
            (brainsurfacer--discover-helper t)
          (plist-get brainsurfacer--discovery-cache :command))
      (let* ((running-applications
              (brainsurfacer--running-applications-from-process-lines
               (brainsurfacer--process-lines)))
             (running (and running-applications t))
             (candidate-applications
              (if (or running brainsurfacer-require-running-app)
                  running-applications
                (append
                 running-applications
                 (mapcar
                  (lambda (bundle)
                    (list :bundle (expand-file-name bundle)))
                  brainsurfacer-application-paths))))
             (configured
              (when (or running (not brainsurfacer-require-running-app))
                (brainsurfacer--resolve-command brainsurfacer-command)))
             (bundled-match
              (unless brainsurfacer-command
                (seq-some
                 (lambda (application)
                   (when-let* ((helper
                                (brainsurfacer--helper-in-bundle
                                 (plist-get application :bundle))))
                     (cons helper application)))
                 candidate-applications)))
             (bundled (car-safe bundled-match))
             (path-helper
              (when (and (or running (not brainsurfacer-require-running-app))
                         (not brainsurfacer-command))
                (brainsurfacer--resolve-command "brainsurfacer-context")))
             (command
              (if brainsurfacer-command
                  configured
                (or bundled path-helper)))
             (selected-application
              (if bundled
                  (cdr bundled-match)
                (car running-applications))))
        (setq brainsurfacer--discovery-cache
              (list :checked-at now
                    :running running
                    :pid (plist-get selected-application :pid)
                    :application (plist-get selected-application :bundle)
                    :command command))
        command))))

(defun brainsurfacer-clear-discovery-cache ()
  "Forget cached running-app and helper discovery."
  (interactive)
  (setq brainsurfacer--discovery-cache nil))

(defun brainsurfacer--process-sentinel (process _event)
  "Record failures and clean up PROCESS output."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (if (zerop (process-exit-status process))
              (setq brainsurfacer--last-error nil)
            (setq brainsurfacer--last-error
                  (if (buffer-live-p buffer)
                      (string-trim
                       (with-current-buffer buffer (buffer-string)))
                    (format "Helper exited with status %s"
                            (process-exit-status process)))
                  brainsurfacer--last-payload nil
                  brainsurfacer--discovery-cache nil))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun brainsurfacer--helper-arguments ()
  "Return helper arguments targeting the discovered application process."
  (append
   (when-let* ((process-id
                (plist-get brainsurfacer--discovery-cache :pid)))
     (list "--process" (number-to-string process-id)))
   (when-let* ((application
                (plist-get brainsurfacer--discovery-cache :application)))
     (list "--application" application))
   '("--input" "-")))

(defun brainsurfacer--send-payload (payload &optional synchronous)
  "Send PAYLOAD through a discovered helper.

When SYNCHRONOUS is non-nil, wait for completion.  Return non-nil when a helper
was invoked."
  (when-let* ((command (brainsurfacer--discover-helper)))
    (let ((arguments (brainsurfacer--helper-arguments)))
      (condition-case error-data
          (progn
            (if synchronous
                (with-temp-buffer
                  (insert payload)
                  (unless (zerop
                           (apply #'call-process-region
                                  (point-min) (point-max) command nil nil nil
                                  arguments))
                    (error "BrainSurfacer context helper failed")))
              (let* ((buffer (generate-new-buffer " *brainsurfacer-context*"))
                     (process
                      (make-process
                       :name "brainsurfacer-context"
                       :buffer buffer
                       :command (cons command arguments)
                       :connection-type 'pipe
                       :noquery t
                       :sentinel #'brainsurfacer--process-sentinel)))
                (process-send-string process payload)
                (process-send-eof process)))
            t)
        (error
         (setq brainsurfacer--last-error (error-message-string error-data)
               brainsurfacer--last-payload nil
               brainsurfacer--discovery-cache nil)
         nil)))))

(defun brainsurfacer--send-snapshot (&optional force)
  "Send current editor state when it changed, or unconditionally with FORCE."
  (when brainsurfacer-mode
    (let* ((payload (brainsurfacer--payload (brainsurfacer--snapshot)))
           (changed (not (equal payload brainsurfacer--last-payload))))
      (when (and (or force changed)
                 (brainsurfacer--send-payload payload))
        (setq brainsurfacer--last-payload payload
              brainsurfacer--last-sent-at (current-time))))))

(defun brainsurfacer--flush-scheduled-update ()
  "Send the update accumulated by the debounce timer."
  (setq brainsurfacer--debounce-timer nil)
  (let ((force brainsurfacer--pending-force))
    (setq brainsurfacer--pending-force nil)
    (brainsurfacer--send-snapshot force)))

(defun brainsurfacer--schedule (&optional force)
  "Schedule a complete snapshot, preserving any FORCE request."
  (when brainsurfacer-mode
    (setq brainsurfacer--pending-force
          (or brainsurfacer--pending-force force))
    (when (timerp brainsurfacer--debounce-timer)
      (cancel-timer brainsurfacer--debounce-timer))
    (setq brainsurfacer--debounce-timer
          (run-at-time brainsurfacer-debounce-delay nil
                       #'brainsurfacer--flush-scheduled-update))))

(defun brainsurfacer--handle-state-change (&rest _arguments)
  "Coalesce any editor-state hook arguments into one snapshot."
  (brainsurfacer--schedule))

(defun brainsurfacer--handle-focus-change (&rest _arguments)
  "Schedule context after Emacs focus changes without bypassing cooldown."
  (brainsurfacer--schedule))

(defun brainsurfacer--heartbeat ()
  "Refresh the current snapshot before its TTL expires."
  (brainsurfacer--send-snapshot t))

(defun brainsurfacer--heartbeat-interval ()
  "Return a refresh interval safely shorter than the configured TTL."
  (max 0.5
       (/ (float (brainsurfacer--normalized-time-to-live)) 2.0)))

(defun brainsurfacer--install-hooks ()
  "Install available state hooks globally."
  (dolist (hook brainsurfacer--state-hooks)
    (when (boundp hook)
      (add-hook hook #'brainsurfacer--handle-state-change)))
  (add-function :after after-focus-change-function
                #'brainsurfacer--handle-focus-change))

(defun brainsurfacer--remove-hooks ()
  "Remove installed state hooks."
  (dolist (hook brainsurfacer--state-hooks)
    (when (boundp hook)
      (remove-hook hook #'brainsurfacer--handle-state-change)))
  (remove-function after-focus-change-function
                   #'brainsurfacer--handle-focus-change))

(defun brainsurfacer--start-heartbeat ()
  "Start the TTL refresh timer."
  (when (timerp brainsurfacer--heartbeat-timer)
    (cancel-timer brainsurfacer--heartbeat-timer))
  (let ((interval (brainsurfacer--heartbeat-interval)))
    (setq brainsurfacer--heartbeat-timer
          (run-at-time interval interval #'brainsurfacer--heartbeat))))

(defun brainsurfacer--cancel-timers ()
  "Cancel connector debounce and heartbeat timers."
  (when (timerp brainsurfacer--debounce-timer)
    (cancel-timer brainsurfacer--debounce-timer))
  (when (timerp brainsurfacer--heartbeat-timer)
    (cancel-timer brainsurfacer--heartbeat-timer))
  (setq brainsurfacer--debounce-timer nil
        brainsurfacer--heartbeat-timer nil
        brainsurfacer--pending-force nil))

(defun brainsurfacer--clear-synchronously ()
  "Clear Emacs context during orderly shutdown."
  (ignore-errors
    (brainsurfacer--send-payload (brainsurfacer--empty-payload) t)))

;;;###autoload
(defun brainsurfacer-report-now ()
  "Clear discovery cache and immediately report the current snapshot."
  (interactive)
  (brainsurfacer-clear-discovery-cache)
  (brainsurfacer--send-snapshot t))

;;;###autoload
(defun brainsurfacer-diagnose ()
  "Display helper discovery and the current editor snapshot."
  (interactive)
  (let* ((command (brainsurfacer--discover-helper t))
         (snapshot (brainsurfacer--snapshot))
         (cache brainsurfacer--discovery-cache))
    (with-help-window "*BrainSurfacer Diagnostics*"
      (princ (format "BrainSurfacer mode:       %s\n"
                     (if brainsurfacer-mode "enabled" "disabled")))
      (princ (format "Application running:     %s\n"
                     (if (plist-get cache :running) "yes" "no")))
      (princ (format "Application bundle:      %s\n"
                     (or (plist-get cache :application) "not found")))
      (princ (format "Connector helper:        %s\n"
                     (or command "not found")))
      (princ (format "Last sent:               %s\n"
                     (if brainsurfacer--last-sent-at
                         (format-time-string "%Y-%m-%d %H:%M:%S"
                                             brainsurfacer--last-sent-at)
                       "never")))
      (princ (format "Last error:              %s\n\n"
                     (or brainsurfacer--last-error "none")))
      (princ "Current snapshot:\n")
      (princ (brainsurfacer--payload snapshot))
      (princ "\n"))))

;;;###autoload
(define-minor-mode brainsurfacer-mode
  "Report live Org/Markdown editor context to BrainSurfacer."
  :global t
  :group 'brainsurfacer
  (if brainsurfacer-mode
      (progn
        (setq brainsurfacer--last-payload nil
              brainsurfacer--last-error nil)
        (brainsurfacer--install-hooks)
        (add-hook 'kill-emacs-hook #'brainsurfacer--clear-synchronously)
        (brainsurfacer--start-heartbeat)
        (brainsurfacer--schedule t))
    (brainsurfacer--remove-hooks)
    (remove-hook 'kill-emacs-hook #'brainsurfacer--clear-synchronously)
    (brainsurfacer--cancel-timers)
    (brainsurfacer--send-payload (brainsurfacer--empty-payload))
    (setq brainsurfacer--last-payload nil)))

(provide 'brainsurfacer)

;;; brainsurfacer.el ends here
