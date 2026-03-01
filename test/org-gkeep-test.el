;;; org-gkeep-test.el --- Tests for org-gkeep -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for org-gkeep pure/deterministic functions.

;;; Code:

(require 'ert)
(require 'org-gkeep)

;;; Note type detection

(ert-deftest org-gkeep-test-note-type-text ()
  "Test text note type detection."
  (let ((note '((body . ((text . "Hello world"))))))
    (should (string= (org-gkeep--note-type note) "text"))))

(ert-deftest org-gkeep-test-note-type-list ()
  "Test list note type detection."
  (let ((note '((body . ((list . ((listItems . []))))))))
    (should (string= (org-gkeep--note-type note) "list"))))

(ert-deftest org-gkeep-test-note-type-empty ()
  "Test empty body defaults to text."
  (let ((note '((body . nil))))
    (should (string= (org-gkeep--note-type note) "text"))))

;;; Text body conversion

(ert-deftest org-gkeep-test-text-to-org-body ()
  "Test text content extraction."
  (let ((body '((text . "Hello world\nSecond line"))))
    (should (string= (org-gkeep--text-to-org-body body)
                     "Hello world\nSecond line"))))

(ert-deftest org-gkeep-test-text-to-org-body-empty ()
  "Test empty text content."
  (let ((body '((text . ""))))
    (should-not (org-gkeep--text-to-org-body body))))

;;; List/checklist conversion

(ert-deftest org-gkeep-test-list-to-org-body ()
  "Test checklist conversion to Org checkboxes."
  (let ((body '((list . ((listItems . [((text . ((text . "Buy milk")))
                                         (checked . :json-false))
                                        ((text . ((text . "Buy eggs")))
                                         (checked . t))]))))))
    (let ((result (org-gkeep--list-to-org-body body)))
      (should (string-match-p "- \\[ \\] Buy milk" result))
      (should (string-match-p "- \\[X\\] Buy eggs" result)))))

(ert-deftest org-gkeep-test-list-to-org-body-children ()
  "Test checklist with child items."
  (let ((body '((list . ((listItems . [((text . ((text . "Groceries")))
                                         (checked . :json-false)
                                         (childListItems . [((text . ((text . "Apples")))
                                                              (checked . :json-false))
                                                             ((text . ((text . "Bananas")))
                                                              (checked . t))]))]))))))
    (let ((result (org-gkeep--list-to-org-body body)))
      (should (string-match-p "^- \\[ \\] Groceries" result))
      (should (string-match-p "  - \\[ \\] Apples" result))
      (should (string-match-p "  - \\[X\\] Bananas" result)))))

;;; Note-to-Org conversion

(ert-deftest org-gkeep-test-note-to-org ()
  "Test text note to Org heading conversion."
  (let* ((note '((name . "notes/abc123")
                 (title . "Meeting Notes")
                 (body . ((text . "Discussion about project X")))
                 (createTime . "2026-01-15T10:30:00.000Z")
                 (updateTime . "2026-01-15T14:22:00.000Z")
                 (trashed . :json-false)))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Meeting Notes" result))
    (should (string-match-p ":GKEEP_ID: notes/abc123" result))
    (should (string-match-p ":GKEEP_TYPE: text" result))
    (should (string-match-p ":GKEEP_CREATED: 2026-01-15T10:30:00.000Z" result))
    (should (string-match-p ":GKEEP_UPDATED: 2026-01-15T14:22:00.000Z" result))
    (should (string-match-p "Discussion about project X" result))))

(ert-deftest org-gkeep-test-note-to-org-list ()
  "Test list note to Org heading conversion."
  (let* ((note '((name . "notes/def456")
                 (title . "Shopping List")
                 (body . ((list . ((listItems . [((text . ((text . "Milk")))
                                                   (checked . :json-false))
                                                  ((text . ((text . "Bread")))
                                                   (checked . t))])))))
                 (createTime . "2026-01-15T10:00:00.000Z")
                 (updateTime . "2026-01-15T12:00:00.000Z")))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Shopping List" result))
    (should (string-match-p ":GKEEP_TYPE: list" result))
    (should (string-match-p "- \\[ \\] Milk" result))
    (should (string-match-p "- \\[X\\] Bread" result))))

;;; Org body to list items

(ert-deftest org-gkeep-test-org-body-to-list ()
  "Test parsing Org checkboxes to API format."
  (let ((body-text "- [ ] Item one\n- [X] Item two"))
    (let ((items (org-gkeep--org-body-to-list body-text)))
      (should (= (length items) 2))
      (should (string= (alist-get 'text (alist-get 'text (car items))) "Item one"))
      (should-not (alist-get 'checked (car items)))
      (should (string= (alist-get 'text (alist-get 'text (cadr items))) "Item two"))
      (should (eq (alist-get 'checked (cadr items)) t)))))

(ert-deftest org-gkeep-test-org-body-to-list-children ()
  "Test parsing Org checkboxes with child items."
  (let ((body-text "- [ ] Parent\n  - [X] Child 1\n  - [ ] Child 2"))
    (let ((items (org-gkeep--org-body-to-list body-text)))
      (should (= (length items) 1))
      (let ((parent (car items)))
        (should (string= (alist-get 'text (alist-get 'text parent)) "Parent"))
        (should (= (length (alist-get 'childListItems parent)) 2))))))

;;; Org-to-note-data extraction

(ert-deftest org-gkeep-test-org-to-note-data ()
  "Test extracting note data from Org heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Meeting Notes\n")
    (insert ":PROPERTIES:\n")
    (insert ":GKEEP_ID: notes/abc123\n")
    (insert ":GKEEP_TYPE: text\n")
    (insert ":END:\n")
    (insert "Some body text\n")
    (goto-char (point-min))
    (let ((data (org-gkeep--org-to-note-data)))
      (should (string= (alist-get 'title data) "Meeting Notes"))
      (should (alist-get 'body data)))))

(ert-deftest org-gkeep-test-note-to-org-untitled ()
  "Test note without title defaults to Untitled."
  (let* ((note '((name . "notes/xyz")
                 (body . ((text . "No title note")))
                 (createTime . "2026-01-15T10:00:00.000Z")
                 (updateTime . "2026-01-15T10:00:00.000Z")))
         (result (org-gkeep--note-to-org note)))
    (should (string-match-p "^\\*\\* Untitled" result))))

(provide 'org-gkeep-test)

;;; org-gkeep-test.el ends here
