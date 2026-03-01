;;; org-gkeep-test.el --- Tests for org-gkeep -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for org-gkeep pure/deterministic functions.

;;; Code:

(require 'ert)
(require 'org-gkeep)

;;; Note type detection

(ert-deftest org-gkeep-test-note-type-text ()
  "Test text note type detection."
  (let ((note '((type . "text"))))
    (should (string= (org-gkeep--note-type note) "text"))))

(ert-deftest org-gkeep-test-note-type-list ()
  "Test list note type detection."
  (let ((note '((type . "list"))))
    (should (string= (org-gkeep--note-type note) "list"))))

(ert-deftest org-gkeep-test-note-type-default ()
  "Test missing type defaults to text."
  (let ((note '((title . "No type"))))
    (should (string= (org-gkeep--note-type note) "text"))))

;;; Items to Org body

(ert-deftest org-gkeep-test-items-to-org-body ()
  "Test checklist items to Org checkboxes."
  (let ((items [((text . "Buy milk") (checked . :json-false) (indented . :json-false))
                ((text . "Buy eggs") (checked . t) (indented . :json-false))]))
    (let ((result (org-gkeep--items-to-org-body items)))
      (should (string-match-p "- \\[ \\] Buy milk" result))
      (should (string-match-p "- \\[X\\] Buy eggs" result)))))

(ert-deftest org-gkeep-test-items-to-org-body-indented ()
  "Test indented checklist items."
  (let ((items [((text . "Parent") (checked . :json-false) (indented . :json-false))
                ((text . "Child") (checked . t) (indented . t))]))
    (let ((result (org-gkeep--items-to-org-body items)))
      (should (string-match-p "^- \\[ \\] Parent" result))
      (should (string-match-p "^  - \\[X\\] Child" result)))))

;;; Labels to tags

(ert-deftest org-gkeep-test-labels-to-tags ()
  "Test label-to-tag conversion."
  (should (string= (org-gkeep--labels-to-tags '("work" "urgent"))
                   ":work:urgent:"))
  (should-not (org-gkeep--labels-to-tags nil))
  (should-not (org-gkeep--labels-to-tags [])))

(ert-deftest org-gkeep-test-labels-to-tags-special-chars ()
  "Test labels with special characters become valid Org tags."
  (let ((result (org-gkeep--labels-to-tags '("my-list" "to do"))))
    (should (string-match-p ":my_list:" result))
    (should (string-match-p ":to_do:" result))))

;;; Note-to-Org conversion

(ert-deftest org-gkeep-test-note-to-org-text ()
  "Test text note to Org heading conversion."
  (let* ((note '((id . "abc123")
                 (title . "Meeting Notes")
                 (type . "text")
                 (text . "Discussion about project X")
                 (color . "Blue")
                 (pinned . t)
                 (archived . :json-false)
                 (trashed . :json-false)
                 (labels . ["work"])
                 (timestamps . ((created . "2026-01-15 10:30:00")
                                (updated . "2026-01-15 14:22:00")))))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Meeting Notes :work:" result))
    (should (string-match-p ":GKEEP_ID: abc123" result))
    (should (string-match-p ":GKEEP_TYPE: text" result))
    (should (string-match-p ":GKEEP_COLOR: Blue" result))
    (should (string-match-p ":GKEEP_PINNED: true" result))
    (should (string-match-p "Discussion about project X" result))))

(ert-deftest org-gkeep-test-note-to-org-list ()
  "Test list note to Org heading conversion."
  (let* ((note '((id . "def456")
                 (title . "Shopping List")
                 (type . "list")
                 (color . "DEFAULT")
                 (pinned . :json-false)
                 (archived . :json-false)
                 (trashed . :json-false)
                 (labels . [])
                 (items . [((text . "Milk") (checked . :json-false) (indented . :json-false))
                           ((text . "Bread") (checked . t) (indented . :json-false))])
                 (timestamps . ((created . "2026-01-15 10:00:00")
                                (updated . "2026-01-15 12:00:00")))))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Shopping List" result))
    (should (string-match-p ":GKEEP_TYPE: list" result))
    (should (string-match-p "- \\[ \\] Milk" result))
    (should (string-match-p "- \\[X\\] Bread" result))))

(ert-deftest org-gkeep-test-note-to-org-untitled ()
  "Test note without title defaults to Untitled."
  (let* ((note '((id . "xyz")
                 (type . "text")
                 (text . "No title note")
                 (color . "DEFAULT")
                 (pinned . :json-false)
                 (archived . :json-false)
                 (trashed . :json-false)
                 (labels . [])
                 (timestamps . ((created . "2026-01-15 10:00:00")
                                (updated . "2026-01-15 10:00:00")))))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Untitled" result))))

(ert-deftest org-gkeep-test-note-to-org-multiple-labels ()
  "Test note with multiple labels."
  (let* ((note '((id . "ml1")
                 (title . "Tagged")
                 (type . "text")
                 (text . "")
                 (color . "Red")
                 (pinned . :json-false)
                 (archived . :json-false)
                 (trashed . :json-false)
                 (labels . ["work" "urgent"])
                 (timestamps . ((created . "") (updated . "")))))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p ":work:urgent:" result))))

;;; Org body to list items

(ert-deftest org-gkeep-test-org-body-to-list ()
  "Test parsing Org checkboxes to list items."
  (let ((body-text "- [ ] Item one\n- [X] Item two"))
    (let ((items (org-gkeep--org-body-to-list body-text)))
      (should (= (length items) 2))
      (should (string= (alist-get 'text (car items)) "Item one"))
      (should-not (alist-get 'checked (car items)))
      (should (string= (alist-get 'text (cadr items)) "Item two"))
      (should (eq (alist-get 'checked (cadr items)) t)))))

(ert-deftest org-gkeep-test-org-body-to-list-indented ()
  "Test parsing Org checkboxes with indented items."
  (let ((body-text "- [ ] Parent\n  - [X] Child 1\n  - [ ] Child 2"))
    (let ((items (org-gkeep--org-body-to-list body-text)))
      (should (= (length items) 3))
      (should-not (eq (alist-get 'indented (car items)) t))
      (should (eq (alist-get 'indented (cadr items)) t)))))

;;; Org-to-note-data extraction

(ert-deftest org-gkeep-test-org-to-note-data ()
  "Test extracting note data from Org heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Meeting Notes :work:\n")
    (insert ":PROPERTIES:\n")
    (insert ":GKEEP_ID: abc123\n")
    (insert ":GKEEP_TYPE: text\n")
    (insert ":GKEEP_COLOR: Blue\n")
    (insert ":END:\n")
    (insert "Some body text\n")
    (goto-char (point-min))
    (let ((data (org-gkeep--org-to-note-data)))
      (should (string= (alist-get 'title data) "Meeting Notes"))
      (should (string= (alist-get 'type data) "text"))
      (should (string= (alist-get 'color data) "Blue")))))

(provide 'org-gkeep-test)

;;; org-gkeep-test.el ends here
