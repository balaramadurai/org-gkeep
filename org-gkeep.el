;;; org-gkeep.el --- Google Keep integration for Org-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bala Ramadurai

;; Author: Bala Ramadurai <bala@balaramadurai.net>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.0") (request "0.3.0"))
;; Keywords: convenience org
;; URL: https://github.com/balaramadurai/org-gkeep

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; org-gkeep provides pull + create sync between Google Keep and Org-mode.
;;
;; Features:
;; - Pull Google Keep notes into Org headings with full metadata
;; - Create new notes in Google Keep from Org headings
;; - Text notes become plain body text
;; - List/checklist notes become Org checkboxes (- [ ] / - [X])
;; - Delete notes from Google Keep
;;
;; Limitations (Google Keep API):
;; - No update/PATCH endpoint — notes can only be created or deleted
;; - No labels, colors, pinned, archived, or reminders via API
;; - Requires Google Workspace account (enterprise API)
;;
;; Requirements:
;; - oauth2-auto and aio packages for authentication
;; - request.el for HTTP communication
;; - A Google Cloud project with Keep API enabled
;; - Google Workspace Business Standard or higher
;;
;; Quick start:
;; 1. Set `org-gkeep-account' to your Google account email
;; 2. Ensure `oauth2-auto-google-client-id' and
;;    `oauth2-auto-google-client-secret' are configured
;; 3. Run `M-x org-gkeep-pull' to pull notes into Org

;;; Code:

(require 'org)
(require 'json)
(require 'request)
(require 'subr-x)
(require 'cl-lib)

;; Soft dependencies — loaded at runtime when auth is needed
(declare-function oauth2-auto-access-token "ext:oauth2-auto")
(declare-function aio-wait-for "ext:aio")
(defvar oauth2-auto-google-client-id)
(defvar oauth2-auto-google-client-secret)
(defvar oauth2-auto-additional-providers-alist)


;;; Customization

(defgroup org-gkeep nil
  "Google Keep integration for Org-mode."
  :group 'org
  :prefix "org-gkeep-")

(defcustom org-gkeep-account nil
  "Google account email for OAuth2 authentication."
  :group 'org-gkeep
  :type '(choice (const nil) string))

(defcustom org-gkeep-default-file
  (expand-file-name "gkeep.org" org-directory)
  "Default Org file for Google Keep notes."
  :group 'org-gkeep
  :type 'file)

(defcustom org-gkeep-file nil
  "Target Org file for Google Keep notes.
When nil, uses `org-gkeep-default-file'."
  :group 'org-gkeep
  :type '(choice (const nil) file))

(defcustom org-gkeep-handle-remote-deletion 'ask
  "How to handle notes deleted from Google Keep during pull.
When `ask', prompt for each deleted note.
When `archive', archive the Org heading.
When `delete', remove the Org heading entirely.
When `mark', set the heading to a CANCELLED state.
When nil, leave the heading as-is."
  :group 'org-gkeep
  :type '(choice (const :tag "Ask each time" ask)
                 (const :tag "Archive heading" archive)
                 (const :tag "Delete heading" delete)
                 (const :tag "Mark CANCELLED" mark)
                 (const :tag "Do nothing" nil)))

(defcustom org-gkeep-cancelled-state "CANCELLED"
  "Org TODO keyword for notes deleted or trashed remotely."
  :group 'org-gkeep
  :type 'string)

(defcustom org-gkeep-sync-trashed nil
  "Whether to pull trashed notes from Google Keep.
When nil, trashed notes are excluded via API filter."
  :group 'org-gkeep
  :type 'boolean)


;;; Internal variables

(defconst org-gkeep--api-base "https://keep.googleapis.com"
  "Base URL for Google Keep API.")

(defconst org-gkeep--scope "https://www.googleapis.com/auth/keep"
  "OAuth2 scope for Google Keep API.")


;;; OAuth2 authentication

(defun org-gkeep--ensure-provider ()
  "Register org-gkeep as an OAuth2 provider if not already present."
  (require 'oauth2-auto)
  (unless (assq 'org-gkeep (oauth2-auto-providers-alist))
    (add-to-list 'oauth2-auto-additional-providers-alist
                 `(org-gkeep
                   (authorize_url . "https://accounts.google.com/o/oauth2/auth")
                   (token_url . "https://oauth2.googleapis.com/token")
                   (scope . ,org-gkeep--scope)
                   (client_id . ,oauth2-auto-google-client-id)
                   (client_secret . ,oauth2-auto-google-client-secret)))))

(defun org-gkeep--get-access-token ()
  "Return the OAuth2 access token for the configured account."
  (unless org-gkeep-account
    (user-error "Set `org-gkeep-account' to your Google account email"))
  (org-gkeep--ensure-provider)
  (require 'aio)
  (aio-wait-for (oauth2-auto-access-token org-gkeep-account 'org-gkeep)))


;;; HTTP API layer

(defun org-gkeep--api-request (method endpoint &optional data params)
  "Make an authenticated API request.
METHOD is \"GET\", \"POST\", or \"DELETE\".
ENDPOINT is relative to the API base URL.
DATA is an alist to send as JSON body.
PARAMS is an alist of query parameters.
Returns parsed JSON response as an alist."
  (let* ((token (org-gkeep--get-access-token))
         (url (concat org-gkeep--api-base endpoint))
         (response (request url
                     :type method
                     :headers `(("Authorization" . ,(format "Bearer %s" token))
                                ("Content-Type" . "application/json"))
                     :data (when data (json-encode data))
                     :params params
                     :parser 'json-read
                     :sync t
                     :silent t)))
    (when response
      (let ((status (request-response-status-code response))
            (body (request-response-data response)))
        (cond
         ((and status (>= status 200) (< status 300))
          body)
         ((eq status 401)
          ;; Token expired — retry once
          (let* ((new-token (org-gkeep--get-access-token))
                 (retry (request url
                           :type method
                           :headers `(("Authorization" . ,(format "Bearer %s" new-token))
                                      ("Content-Type" . "application/json"))
                           :data (when data (json-encode data))
                           :params params
                           :parser 'json-read
                           :sync t
                           :silent t)))
            (if (and retry
                     (let ((s (request-response-status-code retry)))
                       (and s (>= s 200) (< s 300))))
                (request-response-data retry)
              (error "Google Keep API request failed after retry: %s %s → %s"
                     method endpoint
                     (request-response-status-code retry)))))
         (t
          (error "Google Keep API request failed: %s %s → %s: %s"
                 method endpoint status body)))))))

(defun org-gkeep--fetch-notes ()
  "Fetch all notes from Google Keep API.
Returns a list of note alists.  Respects `org-gkeep-sync-trashed'."
  (let ((items nil)
        (page-token nil))
    (cl-loop
     do (let* ((params (append (unless org-gkeep-sync-trashed
                                 '(("filter" . "-trashed")))
                               (when page-token
                                 `(("pageToken" . ,page-token)))))
               (response (org-gkeep--api-request "GET" "/v1/notes" nil params)))
          (setq items (append items
                              (append (alist-get 'notes response) nil)))
          (setq page-token (alist-get 'nextPageToken response)))
     while page-token)
    items))

(defun org-gkeep--get-note (note-name)
  "Fetch a single note by NOTE-NAME (e.g. \"notes/abc123\")."
  (org-gkeep--api-request "GET" (format "/v1/%s" note-name)))

(defun org-gkeep--create-note (data)
  "Create a new note with DATA alist.
DATA should contain `title' and `body' keys."
  (org-gkeep--api-request "POST" "/v1/notes" data))

(defun org-gkeep--delete-note (note-name)
  "Delete note by NOTE-NAME (e.g. \"notes/abc123\")."
  (org-gkeep--api-request "DELETE" (format "/v1/%s" note-name)))


;;; Conversion functions

(defun org-gkeep--note-type (note)
  "Detect whether NOTE is a \"text\" or \"list\" note.
Examines the body section structure."
  (let ((body (alist-get 'body note)))
    (cond
     ((alist-get 'list body) "list")
     ((alist-get 'text body) "text")
     (t "text"))))

(defun org-gkeep--text-to-org-body (body)
  "Extract text content from BODY section as plain Org body text."
  (let ((text-content (alist-get 'text body)))
    (when (and text-content (not (string-empty-p text-content)))
      text-content)))

(defun org-gkeep--list-to-org-body (body)
  "Convert ListContent in BODY to Org checkbox items.
Returns a string with `- [ ]' and `- [X]' items."
  (let ((list-content (alist-get 'list body)))
    (when list-content
      (let ((items (alist-get 'listItems list-content)))
        (when items
          (mapconcat
           (lambda (item)
             (let* ((text (or (alist-get 'text (alist-get 'text item)) ""))
                    (checked (eq (alist-get 'checked item) t))
                    (checkbox (if checked "- [X]" "- [ ]"))
                    (children (alist-get 'childListItems item))
                    (main-line (format "%s %s" checkbox text)))
               (if children
                   (concat main-line "\n"
                           (mapconcat
                            (lambda (child)
                              (let* ((child-text (or (alist-get 'text (alist-get 'text child)) ""))
                                     (child-checked (eq (alist-get 'checked child) t))
                                     (child-cb (if child-checked "- [X]" "- [ ]")))
                                (format "  %s %s" child-cb child-text)))
                            (append children nil)
                            "\n"))
                 main-line)))
           (append items nil)
           "\n"))))))

(defun org-gkeep--note-to-org (note &optional level)
  "Convert Google Keep NOTE alist to an Org heading string.
LEVEL is the heading depth (default 2)."
  (let* ((level (or level 2))
         (stars (make-string level ?*))
         (name (alist-get 'name note))
         (title (or (alist-get 'title note) "Untitled"))
         (note-type (org-gkeep--note-type note))
         (body (alist-get 'body note))
         (create-time (alist-get 'createTime note))
         (update-time (alist-get 'updateTime note))
         (trashed (alist-get 'trashed note))
         (props (list (cons "GKEEP_ID" (or name ""))
                      (cons "GKEEP_TYPE" note-type)
                      (cons "GKEEP_CREATED" (or create-time ""))
                      (cons "GKEEP_UPDATED" (or update-time ""))
                      (cons "GKEEP_TRASHED" (if (eq trashed t) "true" "false"))))
         (body-text (pcase note-type
                      ("list" (org-gkeep--list-to-org-body body))
                      (_ (org-gkeep--text-to-org-body body)))))
    (concat stars " " title "\n"
            ":PROPERTIES:\n"
            (mapconcat (lambda (p)
                         (format ":%s: %s" (car p) (cdr p)))
                       props
                       "\n")
            "\n:END:\n"
            (when (and body-text (not (string-empty-p body-text)))
              (concat body-text "\n")))))

(defun org-gkeep--org-to-note-data ()
  "Extract Google Keep API data from Org heading at point.
Returns an alist suitable for POST requests."
  (let* ((title (org-get-heading t t t t))
         (body-text (org-gkeep--get-body-text))
         (note-type (or (org-entry-get nil "GKEEP_TYPE") "text")))
    (if (string= note-type "list")
        (let ((list-items (org-gkeep--org-body-to-list body-text)))
          `((title . ,title)
            (body . ((list . ((listItems . ,(vconcat list-items))))))))
      `((title . ,title)
        (body . ((text . ,(or body-text ""))))))))

(defun org-gkeep--org-body-to-text (body-text)
  "Extract plain text from BODY-TEXT (strip Org markup)."
  body-text)

(defun org-gkeep--org-body-to-list (body-text)
  "Parse Org checkboxes in BODY-TEXT into Google Keep ListItems.
Returns a list of alists suitable for the API."
  (when body-text
    (let ((items nil)
          (current-parent nil)
          (lines (split-string body-text "\n" t)))
      (dolist (line lines)
        (cond
         ;; Child item (indented)
         ((string-match "^  - \\[\\([ X]\\)\\] \\(.*\\)" line)
          (let* ((checked (string= (match-string 1 line) "X"))
                 (text (match-string 2 line))
                 (child `((text . ((text . ,text)))
                          (checked . ,checked))))
            (when current-parent
              (let ((existing (alist-get 'childListItems current-parent)))
                (setf (alist-get 'childListItems current-parent)
                      (vconcat (or existing []) (vector child)))))))
         ;; Top-level item
         ((string-match "^- \\[\\([ X]\\)\\] \\(.*\\)" line)
          (when current-parent
            (push current-parent items))
          (let* ((checked (string= (match-string 1 line) "X"))
                 (text (match-string 2 line)))
            (setq current-parent
                  `((text . ((text . ,text)))
                    (checked . ,checked)))))))
      (when current-parent
        (push current-parent items))
      (nreverse items))))


;;; Org manipulation layer

(defun org-gkeep--get-target-file ()
  "Return the target Org file for Google Keep notes."
  (or org-gkeep-file org-gkeep-default-file))

(defun org-gkeep--find-note-heading (note-name)
  "Find the Org heading for NOTE-NAME by GKEEP_ID property.
Searches the target file first, then agenda files.
Returns a marker or nil."
  (let ((primary-file (expand-file-name (org-gkeep--get-target-file))))
    (or (org-gkeep--search-file-for-note primary-file note-name)
        (cl-some (lambda (file)
                   (unless (string= (expand-file-name file) primary-file)
                     (org-gkeep--search-file-for-note file note-name)))
                 (org-agenda-files t)))))

(defun org-gkeep--search-file-for-note (file note-name)
  "Search FILE for a heading with GKEEP_ID matching NOTE-NAME.
Returns a marker or nil."
  (when (file-exists-p file)
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (let ((found nil))
         (while (and (not found)
                     (re-search-forward ":GKEEP_ID:" nil t))
           (when (string= (string-trim (or (org-entry-get nil "GKEEP_ID") ""))
                           note-name)
             (setq found (point-marker))))
         found)))))

(defun org-gkeep--note-exists-p (note-name)
  "Return non-nil if a note with NOTE-NAME exists in the target file."
  (not (null (org-gkeep--find-note-heading note-name))))

(defun org-gkeep--get-body-text ()
  "Get the body text of the Org heading at point.
Excludes the property drawer, planning lines, and child headings."
  (save-excursion
    (org-back-to-heading t)
    (let ((heading-end (save-excursion (org-end-of-subtree t t) (point))))
      (forward-line 1)
      (when (< (point) heading-end)
        (when (looking-at org-planning-line-re)
          (forward-line 1))
        (when (looking-at org-property-drawer-re)
          (goto-char (match-end 0))
          (when (looking-at "\n") (forward-char 1)))
        (let* ((body-start (point))
               (body-end (if (re-search-forward "^\\*+ " heading-end t)
                             (line-beginning-position)
                           heading-end))
               (text (string-trim
                      (buffer-substring-no-properties body-start body-end))))
          (unless (string-empty-p text) text))))))

(defun org-gkeep--replace-body-text (new-text)
  "Replace the body text of the Org heading at point with NEW-TEXT."
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (contents-begin (org-element-property :contents-begin element))
           (contents-end (org-element-property :contents-end element))
           (end (org-entry-end-position)))
      (when contents-begin
        (goto-char contents-begin)
        (when (looking-at org-planning-line-re)
          (forward-line 1))
        (when (looking-at org-property-drawer-re)
          (goto-char (match-end 0))
          (when (looking-at "\n") (forward-char 1)))
        (let ((body-start (point))
              (body-end (or contents-end end)))
          (delete-region body-start body-end)
          (goto-char body-start)
          (insert new-text "\n"))))))

(defun org-gkeep--insert-note (note)
  "Insert a new Org heading for Google Keep NOTE."
  (let* ((org-text (org-gkeep--note-to-org note 2))
         (file (org-gkeep--get-target-file)))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (point-max))
       (unless (bolp) (insert "\n"))
       (insert org-text)))))

(defun org-gkeep--update-note-entry (note)
  "Update an existing Org heading from Google Keep NOTE data."
  (let* ((note-name (alist-get 'name note))
         (marker (org-gkeep--find-note-heading note-name)))
    (when marker
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (let* ((local-updated (org-entry-get nil "GKEEP_UPDATED"))
                (remote-updated (alist-get 'updateTime note)))
           (when (or (null local-updated)
                     (string< local-updated remote-updated))
             (let ((title (or (alist-get 'title note) "Untitled"))
                   (note-type (org-gkeep--note-type note))
                   (body (alist-get 'body note))
                   (trashed (alist-get 'trashed note)))
               ;; Update title
               (org-edit-headline title)
               ;; Update properties
               (org-entry-put nil "GKEEP_TYPE" note-type)
               (org-entry-put nil "GKEEP_UPDATED" (or remote-updated ""))
               (org-entry-put nil "GKEEP_TRASHED"
                              (if (eq trashed t) "true" "false"))
               ;; Update body
               (let ((body-text (pcase note-type
                                  ("list" (org-gkeep--list-to-org-body body))
                                  (_ (org-gkeep--text-to-org-body body)))))
                 (when body-text
                   (org-gkeep--replace-body-text body-text)))))))))))

(defun org-gkeep--collect-local-note-ids ()
  "Collect all GKEEP_IDs across target file and agenda files."
  (let* ((primary-file (expand-file-name (org-gkeep--get-target-file)))
         (ids (org-gkeep--collect-ids-in-file primary-file)))
    (dolist (file (org-agenda-files t))
      (unless (string= (expand-file-name file) primary-file)
        (setq ids (append ids (org-gkeep--collect-ids-in-file file)))))
    (delete-dups ids)))

(defun org-gkeep--collect-ids-in-file (file)
  "Collect GKEEP_IDs in FILE."
  (let ((ids nil))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward ":GKEEP_ID:" nil t)
           (let ((id (string-trim (or (org-entry-get nil "GKEEP_ID") ""))))
             (when (not (string-empty-p id))
               (push id ids)))
           (org-end-of-subtree t t)))))
    ids))

(defun org-gkeep--handle-deleted-note (note-name)
  "Handle a note that was deleted from Google Keep."
  (let ((marker (org-gkeep--find-note-heading note-name)))
    (when marker
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (let* ((title (org-get-heading t t t t))
                (action org-gkeep-handle-remote-deletion)
                (action (if (eq action 'ask)
                            (intern (completing-read
                                     (format "\"%s\" deleted from Keep. Action: " title)
                                     '("archive" "delete" "mark" "nil")
                                     nil t nil nil "archive"))
                          action)))
           (pcase action
             ('archive
              (org-archive-subtree)
              (message "org-gkeep: archived \"%s\"" title))
             ('delete
              (org-cut-subtree)
              (message "org-gkeep: removed \"%s\"" title))
             ('mark
              (org-todo org-gkeep-cancelled-state)
              (org-entry-delete nil "GKEEP_ID")
              (message "org-gkeep: marked cancelled \"%s\"" title))
             ('nil nil))))))))


;;; Interactive commands

;;;###autoload
(defun org-gkeep-pull ()
  "Pull all notes from Google Keep into Org."
  (interactive)
  (message "org-gkeep: pulling notes from Google Keep...")
  (let* ((notes (org-gkeep--fetch-notes))
         (remote-ids (mapcar (lambda (n) (alist-get 'name n)) notes))
         (local-ids (org-gkeep--collect-local-note-ids))
         (deleted-ids (cl-set-difference local-ids remote-ids :test #'string=))
         (new-count 0)
         (updated-count 0)
         (deleted-count 0))
    ;; Process notes
    (dolist (note notes)
      (let ((note-name (alist-get 'name note)))
        (if (org-gkeep--note-exists-p note-name)
            (progn
              (org-gkeep--update-note-entry note)
              (cl-incf updated-count))
          (org-gkeep--insert-note note)
          (cl-incf new-count))))
    ;; Handle deletions
    (when (and deleted-ids org-gkeep-handle-remote-deletion)
      (dolist (note-name deleted-ids)
        (org-gkeep--handle-deleted-note note-name)
        (cl-incf deleted-count)))
    ;; Save
    (let ((file (org-gkeep--get-target-file)))
      (when (get-file-buffer file)
        (with-current-buffer (get-file-buffer file)
          (save-buffer))))
    (message "org-gkeep: %d new, %d updated, %d deleted"
             new-count updated-count deleted-count)))

;;;###autoload
(defun org-gkeep-create-note ()
  "Create a new Google Keep note.
If at an Org heading, creates from heading content.
Otherwise, prompts interactively for title and body."
  (interactive)
  (let (data result)
    (if (and (derived-mode-p 'org-mode) (org-at-heading-p))
        (setq data (org-gkeep--org-to-note-data))
      (let* ((title (read-string "Note title: "))
             (body (read-string "Note body (empty for none): ")))
        (setq data `((title . ,title)
                     (body . ((text . ,body)))))))
    (setq result (org-gkeep--create-note data))
    ;; Insert into Org
    (org-gkeep--insert-note result)
    ;; If at heading, store the ID
    (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
      (org-entry-put nil "GKEEP_ID" (alist-get 'name result))
      (org-entry-put nil "GKEEP_TYPE" (org-gkeep--note-type result))
      (org-entry-put nil "GKEEP_CREATED" (or (alist-get 'createTime result) ""))
      (org-entry-put nil "GKEEP_UPDATED" (or (alist-get 'updateTime result) "")))
    (message "org-gkeep: created \"%s\"" (alist-get 'title data))))

;;;###autoload
(defun org-gkeep-delete-at-point ()
  "Delete the Google Keep note at point and handle the Org heading."
  (interactive)
  (unless (org-at-heading-p)
    (user-error "Not at an Org heading"))
  (let ((note-name (org-entry-get nil "GKEEP_ID"))
        (title (org-get-heading t t t t)))
    (unless note-name
      (user-error "No Google Keep note at point"))
    (when (yes-or-no-p (format "Delete \"%s\" from Google Keep? " title))
      (org-gkeep--delete-note note-name)
      (let ((action (completing-read
                     "Note deleted from Google Keep. Org heading: "
                     '("archive" "delete" "mark cancelled" "keep as-is")
                     nil t nil nil "archive")))
        (pcase action
          ("archive"
           (org-archive-subtree)
           (message "org-gkeep: deleted and archived \"%s\"" title))
          ("delete"
           (org-cut-subtree)
           (message "org-gkeep: deleted and removed \"%s\"" title))
          ("mark cancelled"
           (org-todo org-gkeep-cancelled-state)
           (org-entry-delete nil "GKEEP_ID")
           (message "org-gkeep: deleted and marked cancelled \"%s\"" title))
          ("keep as-is"
           (org-entry-delete nil "GKEEP_ID")
           (message "org-gkeep: deleted from Keep, kept locally \"%s\"" title)))))))

;;;###autoload
(defun org-gkeep-browse-note ()
  "Open Google Keep in the browser.
If at a heading with GKEEP_ID, opens the specific note."
  (interactive)
  (let ((note-name (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
                     (org-entry-get nil "GKEEP_ID"))))
    (if note-name
        ;; Extract note ID from "notes/abc123" format
        (let ((note-id (if (string-match "notes/\\(.+\\)" note-name)
                           (match-string 1 note-name)
                         note-name)))
          (browse-url (format "https://keep.google.com/u/0/#NOTE/%s" note-id)))
      (browse-url "https://keep.google.com/"))))

(provide 'org-gkeep)

;;; org-gkeep.el ends here
