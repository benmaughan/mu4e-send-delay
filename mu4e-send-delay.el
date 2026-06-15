;;; mu4e-send-delay.el --- Delay sending of mails in mu4e -*- lexical-binding: t -*-

;; Copyright (C) 2016-2017 Benjamin Andresen <benny@in-ulm.de>

;; Author: Benjamin Andresen <benny@in-ulm.de>
;; Maintainer: Benjamin Andresen <benny@in-ulm.de>

;; Version: 20170610.0636
;; URL: https://github.com/jleechpe/outorg-export
;; Package-Requires: ((emacs "26.1"))

;; This file is not part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package adds a send-delay feature to mu4e: emails are saved as drafts
;; with an X-Delay header recording when they should be sent, and a background
;; timer periodically checks for due messages and sends them automatically.
;;
;; org-msg compatibility is included.  When `mu4e-send-delay-enable-org-msg' is
;; t, replies composed with org-msg are handled correctly: the reply-to HTML
;; is preserved alongside the draft so the quoted original email is included
;; when the delayed message is eventually sent.
;;
;; Basic setup:
;;
;;   (add-to-list 'load-path "/path/to/mu4e-send-delay")
;;   (require 'mu4e-send-delay)
;;   (setq mu4e-send-delay-enable-org-msg t)   ; if using org-msg
;;   (add-hook 'mu4e-main-mode-hook #'mu4e-send-delay-setup)
;;
;; Key bindings (add to your config as desired):
;;
;;   ;; Delay the current message (saves to drafts for later sending)
;;   (defun my/mu4e-send-delay ()
;;     (interactive)
;;     (mu4e-send-delay-send-and-exit t))
;;   (add-hook 'mu4e-compose-mode-hook
;;             (lambda ()
;;               (define-key mu4e-compose-mode-map (kbd "C-c C-l")
;;                           #'my/mu4e-send-delay)))
;;
;; Delay format (used in `mu4e-send-delay-default-delay' or interactively):
;;
;;   - <number><unit>  e.g. "10m", "2h", "1d" (minutes/hours/days/weeks/months/years)
;;   - YYYY-MM-DD      send at `mu4e-send-delay-default-hour' on that date
;;   - HH:MM           send at that time today (or tomorrow if already past)

;;; Code:

(require 'cl-lib)

(require 'gnus-util)
(require 'mu4e-view)
(require 'mu4e-compose)
(autoload 'parse-time-string "parse-time" nil nil)

(declare-function org-msg-edit-mode       "org-msg" ())
(declare-function org-msg-sanity-check    "org-msg" ())
(declare-function org-msg-mua-call        "org-msg" (sym &optional default &rest arg))
(declare-function org-msg-get-prop        "org-msg" (prop))
(declare-function org-msg-set-prop        "org-msg" (prop val))
(declare-function org-msg-ctrl-c-ctrl-c   "org-msg" ())


;;;; Customisation

(defgroup mu4e-send-delay nil
  "Customisation for delayed sending of messages in mu4e."
  :group 'mu4e
  :prefix "mu4e-send-delay-")

(defcustom mu4e-send-delay-header "X-Delay"
  "Name of the email header used to store the scheduled send time.
This header is inserted into the draft and read back by the timer
to determine when to send the message.  It is stripped from the
outgoing message before delivery when
`mu4e-send-delay-strip-header-before-send' is non-nil."
  :type 'string
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-strip-header-before-send t
  "If non-nil, remove `mu4e-send-delay-header' before sending.
This prevents recipients from seeing the internal scheduling
header.  Disable only if you have a specific reason to retain it."
  :type 'boolean
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-include-header-in-draft t
  "Whether to pre-populate the delay header when composing a message.
When non-nil, the delay header is inserted into new drafts so the
user can see and edit it.  When nil, the header is added only at
send time using `mu4e-send-delay-default-delay'."
  :type 'boolean
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-default-delay "10m"
  "Default delay to apply when scheduling a message.
Used when no explicit delay has been set in the draft header.
See `mu4e-send-delay-parse-delay-header-string' for accepted
formats."
  :type 'string
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-default-hour 7
  "Hour of the day (0-23) used when a date-only delay is given.
For example, a delay of \"2026-06-15\" will schedule the message
for 07:00 on that date when this is set to 7."
  :type 'integer
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-timer 120
  "Interval in seconds between checks for due delayed messages.
The timer calls `mu4e-send-delay-send-due' at this frequency.
Shorter values mean more responsive sending but slightly more
background activity."
  :type 'integer
  :group 'mu4e-send-delay)

(defcustom mu4e-send-delay-enable-org-msg nil
  "When non-nil, enable compatibility with the org-msg package.
This overrides `org-msg-ctrl-c-ctrl-c' so that C-c C-c in an
org-msg compose buffer delays the message rather than sending it
immediately.  A prefix argument (C-u C-c C-c) sends immediately.

Also enables logic to preserve the quoted reply HTML alongside the
draft so that delayed replies include the original message.

Set this before calling `mu4e-send-delay-setup', or call
`mu4e-send-delay-setup' again after changing it."
  :type 'boolean
  :group 'mu4e-send-delay)


;;;; Internal state

(defvar mu4e-send-delay--setup-done nil
  "Non-nil if `mu4e-send-delay-setup' has already been run.
Guards against double-advising functions when the setup hook
fires more than once in a session.")

(defvar mu4e-send-delay-send-due-timer nil
  "The timer object for `mu4e-send-delay-send-due'.
Set by `mu4e-send-delay-initialize-send-queue-timer' and used to
avoid creating duplicate timers.")


;;;; Delay string parsing

(defun mu4e-send-delay-parse-delay-header-string (delay)
  "Parse DELAY string and return an RFC 2822 date string for the due time.
DELAY can be one of:

  <number><unit>  Offset from now.  Units: m=minutes, h=hours,
                  d=days, w=weeks, M=months, Y=years.
                  Example: \"10m\", \"2h\", \"3d\"

  YYYY-MM-DD      A specific date.  The send time will be
                  `mu4e-send-delay-default-hour':00 on that day.

  HH:MM           A specific time of day (24h).  If this time has
                  already passed today the message is scheduled for
                  the same time tomorrow.

The return value is a date string suitable for use as an email
header value and for passing to `parse-time-string'."
  (let (num unit year month day hour minute deadline)
    (cond
     ;; YYYY-MM-DD
     ((string-match
       "\\([0-9][0-9][0-9][0-9]\\)-\\([0-9]+\\)-\\([0-9]+\\)" delay)
      (setq year  (string-to-number (match-string 1 delay))
            month (string-to-number (match-string 2 delay))
            day   (string-to-number (match-string 3 delay)))
      (setq deadline
            (message-make-date
             (encode-time 0 0 mu4e-send-delay-default-hour
                          day month year))))
     ;; HH:MM
     ((string-match "\\([0-9]+\\):\\([0-9]+\\)" delay)
      (setq hour   (string-to-number (match-string 1 delay))
            minute (string-to-number (match-string 2 delay)))
      (let ((target (apply #'vector (decode-time (current-time)))))
        (aset target 1 minute)
        (aset target 2 hour)
        (let ((secs (float-time (apply #'encode-time (append target nil)))))
          ;; If this time has already passed today, push to tomorrow
          (when (< secs (float-time))
            (setq secs (+ secs 86400)))
          (setq deadline (message-make-date (seconds-to-time secs))))))
     ;; <number><unit>
     ((string-match "\\([0-9]+\\)\\s-*\\([mhdwMY]\\)" delay)
      (setq num  (string-to-number (match-string 1 delay))
            unit (match-string 2 delay))
      (let ((secs (cond ((string= unit "Y") (* num 60 60 24 365))
                        ((string= unit "M") (* num 60 60 24 30))
                        ((string= unit "w") (* num 60 60 24 7))
                        ((string= unit "d") (* num 60 60 24))
                        ((string= unit "h") (* num 60 60))
                        (t                  (* num 60)))))
        (setq deadline (message-make-date
                        (seconds-to-time (+ (float-time) secs))))))
     (t (error "Unrecognised delay format: %S" delay)))
    deadline))


;;;; Reading the delay header from a draft file

(defun mu4e-send-delay-header-value (file-path)
  "Return the delay header value from the draft at FILE-PATH, or nil.
Returns nil if the file does not exist, has no delay header, or
the header value does not look like an already-parsed RFC 2822
date (i.e. it still contains a raw delay string like \"10m\")."
  (when (file-exists-p file-path)
    (with-temp-buffer
      (insert-file-contents file-path)
      (when-let ((raw (message-fetch-field mu4e-send-delay-header)))
        ;; A raw delay string (e.g. "10m") will parse to a *different* date
        ;; string of a different length when round-tripped through the parser,
        ;; whereas an already-formatted RFC 2822 date string round-trips to
        ;; itself and has the same length.  We use string= rather than eq for
        ;; the numeric comparison to stay type-safe.
        (let ((parsed (mu4e-send-delay-parse-delay-header-string raw)))
          (when (= (length raw) (length parsed))
            raw))))))

(defun mu4e-send-delay-elapsed-p (file-path)
  "Return non-nil if the scheduled send time for FILE-PATH has passed."
  (when-let* ((header  (mu4e-send-delay-header-value file-path))
              (ts      (parse-time-string header)))
    ;; parse-time-string returns a list; all-nil means it failed to parse.
    (unless (cl-every #'null ts)
      (not (time-less-p (current-time) (encode-time ts))))))


;;;; org-msg helpers

(defun mu4e-send-delay--org-msg-draft-p ()
  "Return non-nil if the current buffer looks like an org-msg draft.
Detects the #+OPTIONS: line that org-msg always writes at the top
of its compose buffers."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^#\\+OPTIONS:" nil t)))

(defun mu4e-send-delay--reply-to-stable-path (draft-file)
  "Return the stable path for the reply-to HTML file for DRAFT-FILE.
The HTML file is stored next to the draft with a \"-reply-to.html\"
suffix so it can be found again when the timer fires."
  (concat (file-name-sans-extension draft-file) "-reply-to.html"))

(defun mu4e-send-delay--capture-reply-to-file ()
  "Return the path of the org-msg reply-to temp HTML file, or nil.
The temp file exists only during the composition session; it must
be copied to a stable location before the draft is saved and the
buffer is killed."
  (when (and mu4e-send-delay-enable-org-msg
             (mu4e-send-delay--org-msg-draft-p))
    (when-let* ((prop     (org-msg-get-prop "reply-to"))
                (path     (if (listp prop) (car prop) prop)))
      (when (and (stringp path)
                 (string-suffix-p ".html" path)
                 (file-exists-p path))
        path))))

(defun mu4e-send-delay--persist-reply-to (draft-file temp-html)
  "Copy TEMP-HTML to a stable location beside DRAFT-FILE.
Updates the :reply-to property in the saved draft on disk so that
when the timer later opens the file the property points to the
stable copy rather than the now-deleted temp file.

This must be called after `message-dont-send' has saved the draft
(so DRAFT-FILE is known) but before the composition buffer is
killed (which is what deletes TEMP-HTML via `org-msg-kill-buffer')."
  (when (and draft-file (file-exists-p temp-html))
    (let ((stable (mu4e-send-delay--reply-to-stable-path draft-file)))
      (unless (file-equal-p temp-html stable)
        (copy-file temp-html stable t))
      ;; Rewrite :reply-to in the saved draft so it points to the
      ;; stable copy. We do this by reading the file into a temp
      ;; buffer, updating the property, and writing it back. Always
      ;; rewrite :reply-to in case the draft filename changed.
      (with-temp-buffer
        (insert-file-contents draft-file)
        (org-msg-set-prop "reply-to" (list stable))
        (write-region (point-min) (point-max) draft-file)))))

;;;; Scheduling (saving as a delayed draft)

(defun mu4e-send-delay-schedule-and-exit ()
  "Save the current message as a delayed draft and exit the compose buffer.
The X-Delay header is updated with the computed RFC 2822 due time.
For org-msg replies, the quoted reply HTML is preserved alongside
the draft so it is available when the message is eventually sent."
  (condition-case err
      (let* ((raw-delay   (or (message-fetch-field mu4e-send-delay-header)
                              mu4e-send-delay-default-delay))
             (send-time   (mu4e-send-delay-parse-delay-header-string raw-delay))
             ;; Capture current buffer and reply-to path *before*
             ;; message-dont-send can kill the buffer and delete temp files.
             (compose-buf (current-buffer))
             (reply-html  (mu4e-send-delay--capture-reply-to-file)))
        ;; Replace any raw delay string with the computed RFC 2822 date.
        (message-remove-header mu4e-send-delay-header nil)
        (message-add-header (format "%s: %s" mu4e-send-delay-header send-time))
        ;; Record that we replied/forwarded so mu4e can set the parent flags.
        (when (buffer-file-name)
          (mu4e--set-parent-flags (buffer-file-name)))
        ;; Save the draft.  After this call the buffer may have switched but
        ;; compose-buf still refers to the original compose buffer.
        (message-dont-send)
        ;; Now the draft file exists; copy the reply-to HTML next to it.
        (when reply-html
          (mu4e-send-delay--persist-reply-to
           (buffer-file-name compose-buf) reply-html))
        ;; Kill the compose buffer if configured to do so.
        (when message-kill-buffer-on-exit
          (kill-buffer compose-buf))
        (mu4e-message "Mail scheduled to send at %s" send-time))
    (error (message "mu4e-send-delay: error while scheduling: %s" err))))


;;;; Sending immediately or with delay

(defun mu4e-send-delay-send-and-exit (&optional delay)
  "Send the current message, with optional DELAY.
If DELAY is non-nil, save the message as a delayed draft via
`mu4e-send-delay-schedule-and-exit'.  Otherwise strip the delay
header and send immediately via `message-send-and-exit'.

When called interactively, a prefix argument sets DELAY to t."
  (interactive "P")
  (if delay
      (mu4e-send-delay-schedule-and-exit)
    (when mu4e-send-delay-strip-header-before-send
      (message-remove-header mu4e-send-delay-header nil))
    ;; Capture the draft path before message-send-and-exit kills the buffer.
    (let ((draft (buffer-file-name)))
      (message-send-and-exit)
      ;; Clean up any preserved reply-to HTML now that sending is complete
      ;; and org-msg has finished reading it.
      (when draft
        (let ((html (mu4e-send-delay--reply-to-stable-path draft)))
          (when (file-exists-p html)
            (delete-file html)))))))


;;;; Sending due messages

(defmacro mu4e-send-delay--with-context (context &rest body)
  "Evaluate BODY with mu4e CONTEXT active.
Sets `mu4e--context-current' and calls `with-mu4e-context-vars'."
  (declare (indent 1))
  `(let ((mu4e--context-current ,context))
     (with-mu4e-context-vars ,context ,@body)))

(defun mu4e-send-delay-move-or-delete-draft (file-path)
  "Dispose of the draft at FILE-PATH after successful sending.
Also removes any associated reply-to HTML file saved beside it.

The draft is handled according to `mu4e-sent-messages-behavior':
- `sent' or `trash': copy to the FCC folder then delete the draft.
- `delete': simply delete the draft.

Note: if you use Gmail, set `mu4e-sent-messages-behavior' to
`trash' or `delete' to avoid duplicate sent messages (Gmail
automatically adds sent mail to the Sent folder)."
  ;; Clean up any stable reply-to HTML that was preserved alongside the draft.
  (let ((reply-html (mu4e-send-delay--reply-to-stable-path file-path)))
    (when (file-exists-p reply-html)
      (delete-file reply-html)))
  (pcase mu4e-sent-messages-behavior
    ((or 'sent 'trash)
     (with-temp-buffer
       (insert-file-contents file-path)
       (when-let ((fcc (message-fetch-field "fcc")))
         (message-remove-header "fcc" nil)
         (message-remove-header mu4e-send-delay-header nil)
         (write-file fcc)
         (set-buffer-modified-p nil)))
     (delete-file file-path))
    ('delete
     (delete-file file-path))))

(defun mu4e-send-delay-send-if-due (file-path)
  "Send the draft at FILE-PATH if it is due and not currently open.
Returns t if the message was processed (sent or attempted), nil
otherwise.

For org-msg drafts (detected by a #+OPTIONS: line), the buffer is
set up with `org-msg-edit-mode' before sending so that org-msg can
run its full conversion pipeline.  Plain message-mode drafts are
sent directly via `message-send'.

A draft that is currently open in a buffer is skipped to avoid
interfering with active editing."
  (when (and (mu4e-send-delay-elapsed-p file-path)
             (not (get-file-buffer file-path)))
    (condition-case err
        (progn
          (with-current-buffer (find-file-noselect file-path)
            ;; Ensure correct character encoding regardless of what mu4e
            ;; saved the file as.
            (set-buffer-file-coding-system 'utf-8 t)
            (recode-region (point-min) (point-max) 'prefer-utf-8 'utf-8-unix)
            ;; Insert the header separator that message-mode expects between
            ;; the headers and the body.
            (mu4e--delimit-headers)
            (if (and mu4e-send-delay-enable-org-msg
                     (mu4e-send-delay--org-msg-draft-p))
                ;; --- org-msg path ---
                ;; Strip the delay header while still in fundamental/text mode
                ;; before activating org-msg, which does its own buffer setup.
                (progn
                  (message-mode)
                  (when mu4e-send-delay-strip-header-before-send
                    (message-remove-header mu4e-send-delay-header nil))
                  ;; Activating org-msg-edit-mode arms the message-send-hook
                  ;; with org-msg-prepare-to-send, which converts the org
                  ;; source to MIME when message-send-and-exit is called.
                  (org-msg-edit-mode)
                  ;; Call the *original* org-msg send pipeline directly,
                  ;; bypassing our override (which would re-delay the message).
                  ;; Passing 'message-send-and-exit ensures no delay logic runs.
                  ;; Suppress any interactive prompts (e.g. missing images)
                  ;; since this runs from a timer with no user present.
                  (cl-letf (((symbol-function 'yes-or-no-p)   (lambda (&rest _) t))
                            ((symbol-function 'y-or-n-p)       (lambda (&rest _) t))
                            ((symbol-function 'read-file-name) (lambda (&rest _) "")))
                    (org-msg-mua-call 'send-and-exit 'message-send-and-exit)))
              ;; --- plain message-mode path ---
              (message-mode)
              (when mu4e-send-delay-strip-header-before-send
                (message-remove-header mu4e-send-delay-header nil))
              (message-send)))
          ;; Draft sent successfully; move or delete it.
          (mu4e-send-delay-move-or-delete-draft file-path)
          t)
      (error
       (message "mu4e-send-delay: failed to send %s: %s" file-path err)
       nil))))

(defun mu4e-send-delay-send-due ()
  "Send all delayed drafts whose scheduled time has passed.
Scans the drafts/cur folder for every active mu4e context (or the
default drafts folder if no contexts are configured) and calls
`mu4e-send-delay-send-if-due' on each file found.

Triggers a mu4e index update if any messages were sent, so the
drafts folder reflects the change promptly."
  (interactive)
  (when (mu4e-root-maildir)
    (let* ((dirs
            (if mu4e-contexts
                (mapcar (lambda (ctx)
                          (mu4e-send-delay--with-context ctx
                            (expand-file-name
                             "cur"
                             (concat (mu4e-root-maildir)
                                     (mu4e-get-drafts-folder)))))
                        mu4e-contexts)
              (list (expand-file-name
                     "cur"
                     (concat (mu4e-root-maildir)
                             (mu4e-get-drafts-folder))))))
           (any-sent
            (cl-some
             (lambda (dir)
               (when (file-directory-p dir)
                 (cl-some #'mu4e-send-delay-send-if-due
                          ;; Exclude dotfiles (. and ..) but also any hidden files.
                          (directory-files dir t "^[^.]"))))
             dirs)))
      (when any-sent
        (mu4e-update-index)))))


;;;; Timer management

(defun mu4e-send-delay-initialize-send-queue-timer ()
  "Start the timer that periodically calls `mu4e-send-delay-send-due'.
Uses `mu4e-send-delay-timer' as the interval.  Does nothing if
the timer is already running."
  (interactive)
  (unless mu4e-send-delay-send-due-timer
    (setq mu4e-send-delay-send-due-timer
          (run-with-timer 0 mu4e-send-delay-timer #'mu4e-send-delay-send-due))))


;;;; org-msg integration

(defun mu4e-send-delay-org-msg-ctrl-c-ctrl-c ()
  "Replacement for `org-msg-ctrl-c-ctrl-c' with send-delay support.
In an org-msg compose buffer:

  C-c C-c         Delay the message (save as draft for later sending).
  C-u C-c C-c     Send immediately, bypassing the delay.

This function is installed as an :override advice on
`org-msg-ctrl-c-ctrl-c' when `mu4e-send-delay-enable-org-msg' is
non-nil.  It must be interactive because it replaces a command
that is bound to a key."
  (interactive)
  (when (eq major-mode 'org-msg-edit-mode)
    (org-msg-sanity-check)
    (if current-prefix-arg
        ;; Send immediately: let org-msg-prepare-to-send run via the
        ;; message-send-hook, then call message-send-and-exit directly.
        ;; We avoid org-msg-mua-call here because for forward buffers it
        ;; fails to resolve the send method correctly.
        (mu4e-send-delay-send-and-exit nil)
      ;; No prefix: save as a delayed draft.  We call
      ;; mu4e-send-delay-schedule-and-exit directly, bypassing org-msg's
      ;; conversion pipeline.  The draft is stored as raw org source.  When
      ;; the timer fires, mu4e-send-delay-send-if-due opens it, activates
      ;; org-msg-edit-mode, and then calls the conversion pipeline before
      ;; sending.
      (mu4e-send-delay-schedule-and-exit))))

;;;; Setup
(defun mu4e-send-delay-setup ()
  "Set up mu4e-send-delay.

Initialises the send queue timer, registers the X-Delay column for
`mu4e-headers-mode' and `mu4e-view-mode', and (when
`mu4e-send-delay-enable-org-msg' is non-nil) installs the org-msg
advice.

This function is idempotent: calling it more than once has no
additional effect.  It is safe to add to `mu4e-main-mode-hook'."
  (interactive)
  (unless mu4e-send-delay--setup-done
    (setq mu4e-send-delay--setup-done t)
    ;; Start the background timer.
    (mu4e-send-delay-initialize-send-queue-timer)
    ;; Register a custom header field so the delay time is visible in the
    ;; headers view and the message view.
    (add-to-list
     'mu4e-header-info-custom
     '(:send-delay
       . (:name      "X-Delay"
                     :shortname "Delay"
                     :help      "Scheduled send time for delayed messages"
                     :function  (lambda (msg)
                                  (or (mu4e-send-delay-header-value
                                       (mu4e-message-field msg :path))
                                      "")))))
    (add-to-list 'mu4e-view-fields :send-delay t))
  ;; org-msg advice is managed outside the idempotency guard so that toggling
  ;; `mu4e-send-delay-enable-org-msg' and re-running setup has the intended
  ;; effect.
  (if mu4e-send-delay-enable-org-msg
      (advice-add 'org-msg-ctrl-c-ctrl-c :override
                  #'mu4e-send-delay-org-msg-ctrl-c-ctrl-c)
    (advice-remove 'org-msg-ctrl-c-ctrl-c
                   #'mu4e-send-delay-org-msg-ctrl-c-ctrl-c)))


(provide 'mu4e-send-delay)
;;; mu4e-send-delay.el ends here
