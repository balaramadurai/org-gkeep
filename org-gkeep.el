;;; org-gkeep.el --- Google Keep integration for Org-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bala Ramadurai

;; Author: Bala Ramadurai <bala@balaramadurai.net>
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (org "9.0"))
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

;; org-gkeep provides bidirectional sync between Google Keep and Org-mode.
;;
;; Features:
;; - Pull Google Keep notes into Org headings with full metadata
;; - Create and update notes in Google Keep from Org headings
;; - Text notes become plain body text
;; - List/checklist notes become Org checkboxes (- [ ] / - [X])
;; - Labels synced as Org tags
;; - Colors stored as GKEEP_COLOR property
;; - Pinned/archived state tracking
;; - Delete/trash notes from Google Keep
;;
;; Requirements:
;; - Python 3 with gkeepapi package (pip install gkeepapi)
;; - A Google account (personal or Workspace)
;;
;; Quick start:
;; 1. pip install gkeepapi
;; 2. Set `org-gkeep-email' and `org-gkeep-master-token'
;; 3. Run `M-x org-gkeep-pull' to pull notes into Org

;;; Code:

(require 'org)
(require 'json)
(require 'subr-x)
(require 'cl-lib)


;;; Customization

(defgroup org-gkeep nil
  "Google Keep integration for Org-mode."
  :group 'org
  :prefix "org-gkeep-")

(defcustom org-gkeep-email nil
  "Google account email for gkeepapi authentication."
  :group 'org-gkeep
  :type '(choice (const nil) string))

(defcustom org-gkeep-master-token nil
  "Master token for gkeepapi authentication.
Generate with: python3 -c \"import gpsoauth; help(gpsoauth)\".
Store securely — this grants full account access."
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

(defcustom org-gkeep-target-heading nil
  "Heading path under which to insert new Google Keep notes.
A list of strings representing the heading hierarchy, e.g.
\\='(\"Inbox\" \"Google Keep\") means notes go under:
  * Inbox
  ** Google Keep
  *** <note here>

When nil, new notes are appended to the end of the file.
The headings are created automatically if they don't exist."
  :group 'org-gkeep
  :type '(choice (const nil) (repeat string)))

(defcustom org-gkeep-python-executable "python3"
  "Python executable for running the gkeep bridge script."
  :group 'org-gkeep
  :type 'string)

(defcustom org-gkeep-bridge-script nil
  "Path to gkeep_bridge.py.
When nil, auto-detected from package directory."
  :group 'org-gkeep
  :type '(choice (const nil) file))

(defcustom org-gkeep-state-file
  (expand-file-name "gkeep-state.json" user-emacs-directory)
  "Path to gkeepapi state cache file.
Speeds up subsequent syncs by caching note state."
  :group 'org-gkeep
  :type 'file)

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
  "Whether to pull trashed notes from Google Keep."
  :group 'org-gkeep
  :type 'boolean)

(defcustom org-gkeep-sync-archived nil
  "Whether to pull archived notes from Google Keep."
  :group 'org-gkeep
  :type 'boolean)

(defcustom org-gkeep-process-timeout 120
  "Timeout in seconds for Python bridge calls."
  :group 'org-gkeep
  :type 'integer)


;;; Python bridge layer

(defun org-gkeep--bridge-script ()
  "Return the path to gkeep_bridge.py."
  (or org-gkeep-bridge-script
      (expand-file-name "gkeep_bridge.py"
                        (file-name-directory
                         (or load-file-name buffer-file-name
                             (locate-library "org-gkeep"))))))

(defun org-gkeep--call-bridge (&rest args)
  "Call the Python bridge with ARGS and return parsed JSON.
Sets GKEEP_EMAIL, GKEEP_MASTER_TOKEN, and GKEEP_STATE_FILE
environment variables for the subprocess."
  (unless org-gkeep-email
    (user-error "Set `org-gkeep-email' to your Google account email"))
  (unless org-gkeep-master-token
    (user-error "Set `org-gkeep-master-token' for authentication"))
  (let* ((script (org-gkeep--bridge-script))
         (process-environment
          (append (list (format "GKEEP_EMAIL=%s" org-gkeep-email)
                        (format "GKEEP_MASTER_TOKEN=%s" org-gkeep-master-token)
                        (format "GKEEP_STATE_FILE=%s" org-gkeep-state-file))
                  process-environment))
         (cmd (append (list org-gkeep-python-executable script) args))
         (buf (generate-new-buffer " *org-gkeep-bridge*"))
         (stderr-file (make-temp-file "org-gkeep-stderr")))
    (unwind-protect
        (let ((exit-code (apply #'call-process
                                (car cmd) nil (list buf stderr-file) nil (cdr cmd))))
          (with-current-buffer buf
            (goto-char (point-min))
            (if (zerop exit-code)
                (condition-case nil
                    (json-read)
                  (error
                   (error "org-gkeep: failed to parse bridge output: %s"
                          (buffer-string))))
              (error "org-gkeep: bridge failed (exit %d): %s"
                     exit-code (buffer-string)))))
      (kill-buffer buf)
      (delete-file stderr-file))))


;;; API functions (via bridge)

(defun org-gkeep--fetch-notes ()
  "Fetch all notes from Google Keep via Python bridge."
  (let ((args (list "pull")))
    (when org-gkeep-sync-trashed
      (setq args (append args '("--include-trashed"))))
    (when org-gkeep-sync-archived
      (setq args (append args '("--include-archived"))))
    (apply #'org-gkeep--call-bridge args)))

(defun org-gkeep--get-note (note-id)
  "Fetch a single note by NOTE-ID."
  (org-gkeep--call-bridge "get" "--id" note-id))

(defun org-gkeep--create-note-api (title &optional text labels color pinned list-items)
  "Create a new note via bridge.
TITLE is required.  Optional TEXT, LABELS (comma-separated), COLOR,
PINNED, and LIST-ITEMS (JSON string)."
  (let ((args (list "create" "--title" title)))
    (when text (setq args (append args (list "--text" text))))
    (when labels (setq args (append args (list "--labels" labels))))
    (when color (setq args (append args (list "--color" color))))
    (when pinned (setq args (append args '("--pinned"))))
    (when list-items (setq args (append args (list "--list-items" list-items))))
    (apply #'org-gkeep--call-bridge args)))

(defun org-gkeep--update-note-api (note-id &optional title text labels color pinned archived list-items)
  "Update note NOTE-ID via bridge."
  (let ((args (list "update" "--id" note-id)))
    (when title (setq args (append args (list "--title" title))))
    (when text (setq args (append args (list "--text" text))))
    (when labels (setq args (append args (list "--labels" labels))))
    (when color (setq args (append args (list "--color" color))))
    (when pinned (setq args (append args (list "--pinned" pinned))))
    (when archived (setq args (append args (list "--archived" archived))))
    (when list-items (setq args (append args (list "--list-items" list-items))))
    (apply #'org-gkeep--call-bridge args)))

(defun org-gkeep--delete-note (note-id)
  "Delete note NOTE-ID via bridge."
  (org-gkeep--call-bridge "delete" "--id" note-id))

(defun org-gkeep--trash-note (note-id)
  "Trash note NOTE-ID via bridge."
  (org-gkeep--call-bridge "trash" "--id" note-id))

(defun org-gkeep--fetch-labels ()
  "Fetch all labels from Google Keep."
  (org-gkeep--call-bridge "labels"))

(defun org-gkeep--create-label (name)
  "Create a new label with NAME."
  (org-gkeep--call-bridge "create-label" "--name" name))


;;; Conversion functions

(defun org-gkeep--note-type (note)
  "Detect whether NOTE is a \"text\" or \"list\" note."
  (alist-get 'type note "text"))

(defun org-gkeep--items-to-org-body (items)
  "Convert list ITEMS to Org checkbox string."
  (when items
    (mapconcat
     (lambda (item)
       (let* ((text (or (alist-get 'text item) ""))
              (checked (eq (alist-get 'checked item) t))
              (indented (eq (alist-get 'indented item) t))
              (checkbox (if checked "- [X]" "- [ ]"))
              (prefix (if indented "  " "")))
         (format "%s%s %s" prefix checkbox text)))
     (append items nil)
     "\n")))

(defun org-gkeep--labels-to-tags (labels)
  "Convert LABELS list to Org tag string."
  (when (and labels (> (length labels) 0))
    (let ((tag-list (mapcar (lambda (l)
                              (replace-regexp-in-string "[^[:alnum:]_@]" "_" l))
                            (append labels nil))))
      (concat ":" (string-join tag-list ":") ":"))))

(defun org-gkeep--note-to-org (note &optional level)
  "Convert Google Keep NOTE alist to an Org heading string.
LEVEL is the heading depth (default 2)."
  (let* ((level (or level 2))
         (stars (make-string level ?*))
         (id (alist-get 'id note))
         (title (or (alist-get 'title note) "Untitled"))
         (note-type (org-gkeep--note-type note))
         (color (or (alist-get 'color note) "DEFAULT"))
         (pinned (alist-get 'pinned note))
         (archived (alist-get 'archived note))
         (trashed (alist-get 'trashed note))
         (labels (alist-get 'labels note))
         (timestamps (alist-get 'timestamps note))
         (created (alist-get 'created timestamps))
         (updated (alist-get 'updated timestamps))
         (tags (org-gkeep--labels-to-tags labels))
         (props (list (cons "GKEEP_ID" (or id ""))
                      (cons "GKEEP_TYPE" note-type)
                      (cons "GKEEP_COLOR" color)
                      (cons "GKEEP_PINNED" (if (eq pinned t) "true" "false"))
                      (cons "GKEEP_ARCHIVED" (if (eq archived t) "true" "false"))
                      (cons "GKEEP_TRASHED" (if (eq trashed t) "true" "false"))
                      (cons "GKEEP_CREATED" (or created ""))
                      (cons "GKEEP_UPDATED" (or updated ""))))
         (body-text (pcase note-type
                      ("list" (org-gkeep--items-to-org-body
                               (alist-get 'items note)))
                      (_ (alist-get 'text note)))))
    (concat stars " " title
            (when tags (concat " " tags))
            "\n"
            ":PROPERTIES:\n"
            (mapconcat (lambda (p)
                         (format ":%s: %s" (car p) (cdr p)))
                       props
                       "\n")
            "\n:END:\n"
            (when (and body-text (not (string-empty-p body-text)))
              (concat body-text "\n")))))

(defun org-gkeep--org-to-note-data ()
  "Extract Google Keep data from Org heading at point.
Returns an alist with title, text/list-items, labels, color."
  (let* ((title (org-get-heading t t t t))
         (body-text (org-gkeep--get-body-text))
         (note-type (or (org-entry-get nil "GKEEP_TYPE") "text"))
         (color (org-entry-get nil "GKEEP_COLOR"))
         (tags (org-get-tags))
         (labels (when tags (string-join tags ","))))
    (list (cons 'title title)
          (cons 'type note-type)
          (cons 'text (if (string= note-type "text") body-text nil))
          (cons 'list-items (if (string= note-type "list")
                                (org-gkeep--org-body-to-list-json body-text)
                              nil))
          (cons 'labels labels)
          (cons 'color color))))

(defun org-gkeep--org-body-to-list (body-text)
  "Parse Org checkboxes in BODY-TEXT into list item alists."
  (when body-text
    (let ((items nil)
          (lines (split-string body-text "\n" t)))
      (dolist (line lines)
        (cond
         ;; Indented child item
         ((string-match "^  - \\[\\([ X]\\)\\] \\(.*\\)" line)
          (push `((text . ,(match-string 2 line))
                  (checked . ,(string= (match-string 1 line) "X"))
                  (indented . t))
                items))
         ;; Top-level item
         ((string-match "^- \\[\\([ X]\\)\\] \\(.*\\)" line)
          (push `((text . ,(match-string 2 line))
                  (checked . ,(string= (match-string 1 line) "X"))
                  (indented . :json-false))
                items))))
      (nreverse items))))

(defun org-gkeep--org-body-to-list-json (body-text)
  "Parse Org checkboxes in BODY-TEXT into JSON string for bridge."
  (let ((items (org-gkeep--org-body-to-list body-text)))
    (when items (json-encode items))))


;;; Org manipulation layer

(defun org-gkeep--get-target-file ()
  "Return the target Org file for Google Keep notes."
  (or org-gkeep-file org-gkeep-default-file))

(defun org-gkeep--find-note-heading (note-id)
  "Find the Org heading for NOTE-ID by GKEEP_ID property.
Searches the target file first, then agenda files.
Returns a marker or nil."
  (let ((primary-file (expand-file-name (org-gkeep--get-target-file))))
    (or (org-gkeep--search-file-for-note primary-file note-id)
        (cl-some (lambda (file)
                   (unless (string= (expand-file-name file) primary-file)
                     (org-gkeep--search-file-for-note file note-id)))
                 (org-agenda-files t)))))

(defun org-gkeep--search-file-for-note (file note-id)
  "Search FILE for a heading with GKEEP_ID matching NOTE-ID.
Returns a marker or nil."
  (when (file-exists-p file)
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (let ((found nil))
         (while (and (not found)
                     (re-search-forward ":GKEEP_ID:" nil t))
           (when (string= (string-trim (or (org-entry-get nil "GKEEP_ID") ""))
                           note-id)
             (setq found (point-marker))))
         found)))))

(defun org-gkeep--note-exists-p (note-id)
  "Return non-nil if a note with NOTE-ID exists."
  (not (null (org-gkeep--find-note-heading note-id))))

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

(defun org-gkeep--ensure-heading-path (headings)
  "Ensure HEADINGS hierarchy exists, creating if needed.
HEADINGS is a list of strings like (\"Inbox\" \"Google Keep\").
Leaves point at the end of the deepest heading's subtree.
Returns the level of the deepest heading."
  (let ((level 0))
    (goto-char (point-min))
    (dolist (title headings)
      (cl-incf level)
      (let ((stars (make-string level ?*))
            (found nil))
        ;; Search for this heading at the correct level
        (save-excursion
          (when (> level 1)
            ;; Stay within parent subtree
            (org-back-to-heading t))
          (let ((bound (if (> level 1)
                           (save-excursion (org-end-of-subtree t t) (point))
                         (point-max))))
            (while (and (not found)
                        (re-search-forward
                         (format "^%s %s$" (regexp-quote stars)
                                 (regexp-quote title))
                         bound t))
              (setq found (point)))))
        (if found
            (progn
              (goto-char found)
              (org-back-to-heading t))
          ;; Create the heading
          (if (= level 1)
              (progn
                (goto-char (point-max))
                (unless (bolp) (insert "\n")))
            (org-end-of-subtree t t)
            (unless (bolp) (insert "\n")))
          (insert (format "%s %s\n" stars title))
          (forward-line -1)
          (org-back-to-heading t))))
    level))

(defun org-gkeep--insert-note (note)
  "Insert a new Org heading for Google Keep NOTE.
When `org-gkeep-target-heading' is set, inserts under that heading path."
  (let* ((file (org-gkeep--get-target-file)))
    (with-current-buffer (find-file-noselect file)
      (org-with-wide-buffer
       (if org-gkeep-target-heading
           (let* ((parent-level (org-gkeep--ensure-heading-path
                                 org-gkeep-target-heading))
                  (note-level (1+ parent-level))
                  (org-text (org-gkeep--note-to-org note note-level)))
             (org-end-of-subtree t t)
             (unless (bolp) (insert "\n"))
             (insert org-text))
         (let ((org-text (org-gkeep--note-to-org note 2)))
           (goto-char (point-max))
           (unless (bolp) (insert "\n"))
           (insert org-text)))))))

(defun org-gkeep--update-note-entry (note)
  "Update an existing Org heading from Google Keep NOTE data."
  (let* ((note-id (alist-get 'id note))
         (marker (org-gkeep--find-note-heading note-id)))
    (when marker
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (let* ((local-updated (org-entry-get nil "GKEEP_UPDATED"))
                (timestamps (alist-get 'timestamps note))
                (remote-updated (alist-get 'updated timestamps)))
           (when (or (null local-updated)
                     (string< local-updated (or remote-updated "")))
             (let ((title (or (alist-get 'title note) "Untitled"))
                   (note-type (org-gkeep--note-type note))
                   (color (or (alist-get 'color note) "DEFAULT"))
                   (pinned (alist-get 'pinned note))
                   (archived (alist-get 'archived note))
                   (trashed (alist-get 'trashed note))
                   (labels (alist-get 'labels note)))
               ;; Update title
               (org-edit-headline title)
               ;; Update tags from labels
               (let ((tags (when (and labels (> (length labels) 0))
                             (mapcar (lambda (l)
                                       (replace-regexp-in-string
                                        "[^[:alnum:]_@]" "_" l))
                                     (append labels nil)))))
                 (org-set-tags (or tags nil)))
               ;; Update properties
               (org-entry-put nil "GKEEP_TYPE" note-type)
               (org-entry-put nil "GKEEP_COLOR" color)
               (org-entry-put nil "GKEEP_PINNED" (if (eq pinned t) "true" "false"))
               (org-entry-put nil "GKEEP_ARCHIVED" (if (eq archived t) "true" "false"))
               (org-entry-put nil "GKEEP_TRASHED" (if (eq trashed t) "true" "false"))
               (org-entry-put nil "GKEEP_UPDATED" (or remote-updated ""))
               ;; Update body
               (let ((body-text (pcase note-type
                                  ("list" (org-gkeep--items-to-org-body
                                           (alist-get 'items note)))
                                  (_ (alist-get 'text note)))))
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

(defun org-gkeep--collect-headings-in-file (file)
  "Collect headings with GKEEP_ID in FILE.
Returns a list of (marker . note-id) pairs."
  (let ((results nil))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward ":GKEEP_ID:" nil t)
           (let ((id (string-trim (or (org-entry-get nil "GKEEP_ID") ""))))
             (when (not (string-empty-p id))
               (push (cons (point-marker) id) results)))
           (org-end-of-subtree t t)))))
    (nreverse results)))

(defun org-gkeep--collect-all-headings ()
  "Collect all headings with GKEEP_ID across target file and agenda files.
Returns a list of (marker . note-id) pairs."
  (let* ((primary-file (expand-file-name (org-gkeep--get-target-file)))
         (results (org-gkeep--collect-headings-in-file primary-file)))
    (dolist (file (org-agenda-files t))
      (unless (string= (expand-file-name file) primary-file)
        (setq results (append results
                              (org-gkeep--collect-headings-in-file file)))))
    results))

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

(defun org-gkeep--handle-deleted-note (note-id)
  "Handle a note that was deleted from Google Keep."
  (let ((marker (org-gkeep--find-note-heading note-id)))
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
         (remote-ids (mapcar (lambda (n) (alist-get 'id n))
                             (append notes nil)))
         (local-ids (org-gkeep--collect-local-note-ids))
         (deleted-ids (cl-set-difference local-ids remote-ids :test #'string=))
         (new-count 0)
         (updated-count 0)
         (deleted-count 0))
    ;; Process notes
    (dolist (note (append notes nil))
      (let ((note-id (alist-get 'id note)))
        (if (org-gkeep--note-exists-p note-id)
            (progn
              (org-gkeep--update-note-entry note)
              (cl-incf updated-count))
          (org-gkeep--insert-note note)
          (cl-incf new-count))))
    ;; Handle deletions
    (when (and deleted-ids org-gkeep-handle-remote-deletion)
      (dolist (note-id deleted-ids)
        (org-gkeep--handle-deleted-note note-id)
        (cl-incf deleted-count)))
    ;; Save
    (let ((file (org-gkeep--get-target-file)))
      (when (get-file-buffer file)
        (with-current-buffer (get-file-buffer file)
          (save-buffer))))
    (message "org-gkeep: %d new, %d updated, %d deleted"
             new-count updated-count deleted-count)))

;;;###autoload
(defun org-gkeep-sync ()
  "Synchronize Org headings with Google Keep.
Pulls remote changes first, then pushes all local headings
that have a GKEEP_ID property."
  (interactive)
  (message "org-gkeep: starting sync...")
  (org-gkeep-pull)
  (org-gkeep-push-all)
  (message "org-gkeep: sync complete"))

(defun org-gkeep--push-at-marker (marker)
  "Push the Org heading at MARKER to Google Keep.
Non-interactive version of `org-gkeep-push-at-point' for batch use.
The heading must have a GKEEP_ID property (always an update).
Returns t on success, nil on error."
  (condition-case err
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (org-back-to-heading t)
         (let* ((note-id (org-entry-get nil "GKEEP_ID"))
                (data (org-gkeep--org-to-note-data))
                (title (alist-get 'title data))
                (text (alist-get 'text data))
                (list-items (alist-get 'list-items data))
                (labels (alist-get 'labels data))
                (color (alist-get 'color data))
                (result (org-gkeep--update-note-api
                         note-id title text labels color nil nil list-items))
                (ts (alist-get 'timestamps result)))
           (org-entry-put nil "GKEEP_UPDATED" (or (alist-get 'updated ts) ""))
           t)))
    (error
     (message "org-gkeep: push failed at %S: %s" marker (error-message-string err))
     nil)))

;;;###autoload
(defun org-gkeep-push-at-point ()
  "Push the Org heading at point to Google Keep.
Creates a new note if no GKEEP_ID, otherwise updates the existing note."
  (interactive)
  (unless (org-at-heading-p)
    (user-error "Not at an Org heading"))
  (let* ((note-id (org-entry-get nil "GKEEP_ID"))
         (data (org-gkeep--org-to-note-data))
         (title (alist-get 'title data))
         (text (alist-get 'text data))
         (list-items (alist-get 'list-items data))
         (labels (alist-get 'labels data))
         (color (alist-get 'color data))
         result)
    (if note-id
        ;; Update existing
        (progn
          (setq result (org-gkeep--update-note-api
                        note-id title text labels color nil nil list-items))
          (message "org-gkeep: updated \"%s\"" title))
      ;; Create new
      (setq result (org-gkeep--create-note-api
                    title text labels color nil list-items))
      (message "org-gkeep: created \"%s\"" title))
    ;; Store properties from result
    (org-entry-put nil "GKEEP_ID" (alist-get 'id result))
    (org-entry-put nil "GKEEP_TYPE" (or (alist-get 'type result) "text"))
    (org-entry-put nil "GKEEP_COLOR" (or (alist-get 'color result) "DEFAULT"))
    (let ((ts (alist-get 'timestamps result)))
      (org-entry-put nil "GKEEP_CREATED" (or (alist-get 'created ts) ""))
      (org-entry-put nil "GKEEP_UPDATED" (or (alist-get 'updated ts) "")))))

;;;###autoload
(defun org-gkeep-push-all ()
  "Push all Org headings with GKEEP_ID to Google Keep.
Iterates over all headings that have a GKEEP_ID property across
the target file and agenda files, updating each in Google Keep."
  (interactive)
  (let* ((headings (org-gkeep--collect-all-headings))
         (total (length headings))
         (success 0)
         (failed 0))
    (if (zerop total)
        (message "org-gkeep: no headings with GKEEP_ID found")
      (message "org-gkeep: pushing %d notes to Google Keep..." total)
      (cl-loop for (marker . _note-id) in headings
               for i from 1
               do (message "org-gkeep: pushing %d/%d..." i total)
               (if (org-gkeep--push-at-marker marker)
                   (cl-incf success)
                 (cl-incf failed)))
      ;; Save modified buffers
      (let ((saved-buffers nil))
        (dolist (entry headings)
          (let ((buf (marker-buffer (car entry))))
            (when (and buf (buffer-modified-p buf)
                       (not (member buf saved-buffers)))
              (with-current-buffer buf (save-buffer))
              (push buf saved-buffers)))))
      (message "org-gkeep: pushed %d/%d notes (%d failed)"
               success total failed))))

;;;###autoload
(defun org-gkeep-create-note ()
  "Create a new Google Keep note.
If at an Org heading, creates from heading content.
Otherwise, prompts interactively and inserts into the target file."
  (interactive)
  (let* ((at-heading (and (derived-mode-p 'org-mode) (org-at-heading-p))))
    (if at-heading
        (org-gkeep-push-at-point)
      ;; Interactive creation
      (let* ((title (read-string "Note title: "))
             (body (read-string "Note body (empty for none): "))
             (result (org-gkeep--create-note-api title (unless (string-empty-p body) body))))
        (org-gkeep--insert-note result)
        (message "org-gkeep: created \"%s\"" title)))))

;;;###autoload
(defun org-gkeep-delete-at-point ()
  "Delete the Google Keep note at point and handle the Org heading."
  (interactive)
  (unless (org-at-heading-p)
    (user-error "Not at an Org heading"))
  (let ((note-id (org-entry-get nil "GKEEP_ID"))
        (title (org-get-heading t t t t)))
    (unless note-id
      (user-error "No Google Keep note at point"))
    (when (yes-or-no-p (format "Delete \"%s\" from Google Keep? " title))
      (org-gkeep--delete-note note-id)
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
  "Open Google Keep in the browser."
  (interactive)
  (let ((note-id (when (and (derived-mode-p 'org-mode) (org-at-heading-p))
                   (org-entry-get nil "GKEEP_ID"))))
    (if note-id
        (browse-url (format "https://keep.google.com/u/0/#NOTE/%s" note-id))
      (browse-url "https://keep.google.com/"))))

;;;###autoload
(defun org-gkeep-list-labels ()
  "Display Google Keep labels."
  (interactive)
  (let ((labels (org-gkeep--fetch-labels)))
    (if (= (length labels) 0)
        (message "org-gkeep: no labels found")
      (with-current-buffer (get-buffer-create "*Google Keep Labels*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Google Keep Labels\n")
          (insert (make-string 40 ?=) "\n\n")
          (dolist (label (append labels nil))
            (insert (format "%s\n" (alist-get 'name label))))
          (goto-char (point-min))
          (special-mode))
        (display-buffer (current-buffer))))))

;;;###autoload
(defun org-gkeep-auth-test ()
  "Test Google Keep authentication."
  (interactive)
  (message "org-gkeep: testing authentication...")
  (let ((result (org-gkeep--call-bridge "auth-test")))
    (if (eq (alist-get 'success result) t)
        (message "org-gkeep: auth OK — %d notes, %d labels"
                 (alist-get 'note_count result)
                 (alist-get 'label_count result))
      (message "org-gkeep: auth FAILED — %s" (alist-get 'error result)))))

(provide 'org-gkeep)

;;; org-gkeep.el ends here
