;;; org-sync-github-test.el --- GitHub backend tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'org-sync-github)

(ert-deftest org-sync-github-fetch-ignores-pull-requests ()
  "The GitHub issues endpoint also lists PRs; import issues only."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior"))
    (cl-letf (((symbol-function 'org-sync-github-fetch-json)
               (lambda (url)
                 (if (string-match-p "state=closed" url)
                     []
                   [((number . 12) (state . "open") (title . "A task")
                     (body . "Issue body") (labels . [])
                     (created_at . "2026-09-29T12:00:00Z"))
                    ((number . 13) (state . "open") (title . "A PR")
                     (body . "PR body") (labels . [])
                     (pull_request . ((url . "https://api.github.com/repos/JuanG970/org-warrior/pulls/13"))))]))))
      (let ((issues (org-sync-get-prop :bugs (org-sync-github-fetch-buglist nil))))
        (should (= (length issues) 1))
        (should (= (org-sync-get-prop :id (car issues)) 12))))))

(ert-deftest org-sync-github-request-uses-bearer-auth ()
  "GitHub API requests authenticate with a token, not a password."
  (let (headers)
    (cl-letf (((symbol-function 'org-sync-github-token) (lambda () "sample-token"))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (_url)
                 (setq headers url-request-extra-headers)
                 (current-buffer))))
      (org-sync-github-url-retrieve-synchronously
       "https://api.github.com/repos/JuanG970/org-warrior/issues")
      (should (equal (cdr (assoc "Authorization" headers))
                     "Bearer sample-token"))
      (should (equal (cdr (assoc "Accept" headers))
                     "application/vnd.github+json")))))

(ert-deftest org-sync-github-patch-only-changed-fields ()
  "Updating a title must not overwrite a mobile-edited body or labels."
  (let ((cached '(:title "Before" :desc "Old body" :assignee "JuanG970"
                  :status open :tags ("pilot")))
        (local '(:title "After" :desc "Old body" :assignee "JuanG970"
                 :status open :tags ("pilot")))
        (remote '(:title "Before" :desc "Mobile body" :assignee "JuanG970"
                  :status open :tags ("pilot" "mobile"))))
    (should (equal (org-sync-github-update-data cached local remote)
                   '((title . "After"))))))

(ert-deftest org-sync-github-send-updates-only-local-fields ()
  "The network PATCH must use the selective fields, not a full issue JSON."
  (let* ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
         (cached '(:id 12 :title "Before" :desc "Old body" :status open
                        :tags ("pilot") :assignee nil))
         (local '(:id 12 :title "After" :desc "Old body" :status open
                       :tags ("pilot") :assignee nil))
         (remote '((number . 12) (title . "Before") (body . "Mobile body")
                   (state . "open") (labels . [((name . "pilot"))
                                                  ((name . "mobile"))])))
         patch-data)
    (cl-letf (((symbol-function 'org-sync-github-fetch-labels)
               (lambda () '("pilot" "mobile")))
              ((symbol-function 'org-sync-get-cache)
               (lambda (_url) `(:bugs (,cached))))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional data)
                 (pcase method
                   ("GET" remote)
                   ("PATCH" (setq patch-data (json-read-from-string data))
                    '((number . 12)))
                   (_ (ert-fail (format "Unexpected method %s" method)))))))
      (org-sync-github-send-buglist `(:bugs (,local)))
      (should (equal patch-data '((title . "After")))))))

(ert-deftest org-sync-github-preserves-decoded-utf8-issue-titles ()
  "An already-decoded multibyte response keeps its issue title."
  (let ((response (generate-new-buffer " *org-sync-json-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (insert "[{\"title\":\"↔\"}]"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (let* ((issue (aref (car (org-sync-github-fetch-json-page
                                     "https://api.github.com/repos/JuanG970/org-warrior/issues")) 0))
                   (title (cdr (assoc 'title issue))))
              (should (equal title "↔")))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-decodes-unibyte-http-response ()
  "url-retrieve uses an unibyte buffer for GitHub's JSON response."
  (let ((response (generate-new-buffer " *org-sync-unibyte-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (set-buffer-multibyte nil)
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (insert "[{\"title\":\"" (unibyte-string 226 134 148) "\"}]"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (let* ((issue (aref (car (org-sync-github-fetch-json-page
                                     "https://api.github.com/repos/JuanG970/org-warrior/issues")) 0))
                   (title (cdr (assoc 'title issue))))
              (should (equal title "↔")))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-get-preserves-utf8-title ()
  "Single-issue GET and issue-list GET decode titles the same way."
  (let ((response (generate-new-buffer " *org-sync-single-json-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (set-buffer-multibyte nil)
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (setq-local url-http-end-of-headers (point))
            (insert "{\"title\":\"" (unibyte-string 226 134 148) "\"}"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (should (equal
                     (cdr (assoc 'title
                                 (org-sync-github-request
                                  "GET" "https://api.github.com/repos/JuanG970/org-warrior/issues/2")))
                     "↔"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-rejects-http-errors ()
  "An API error must not be mistaken for an empty issue list."
  (let ((response (generate-new-buffer " *org-sync-http-error-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (set-buffer-multibyte nil)
            (insert "HTTP/1.1 401 Unauthorized\nContent-Type: application/json\n\n")
            (insert "{\"message\":\"Bad credentials\"}"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (should (string-match-p
                     "401"
                     (error-message-string
                      (should-error (org-sync-github-fetch-json-page
                                     "https://api.github.com/repos/JuanG970/org-warrior/issues")))))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-writes-json-content-type ()
  "GitHub POST/PATCH bodies are JSON, not form data."
  (let (headers)
    (cl-letf (((symbol-function 'org-sync-github-token) (lambda () "sample-token"))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (_url) (setq headers url-request-extra-headers) (current-buffer))))
      (let ((url-request-data "{\"title\":\"test\"}"))
        (org-sync-github-url-retrieve-synchronously
         "https://api.github.com/repos/JuanG970/org-warrior/issues"))
      (should (equal (cdr (assoc "Content-Type" headers))
                     "application/json")))))

(ert-deftest org-sync-github-request-encodes-unicode-as-ascii-json ()
  "Emacs url.el must send Unicode titles as ASCII JSON escapes."
  (let (wire-body)
    (cl-letf (((symbol-function 'org-sync-github-fetch-json-page)
               (lambda (_url)
                 (setq wire-body url-request-data)
                 '(((number . 2)) . nil))))
      (org-sync-github-request
       "PATCH" "https://api.github.com/repos/JuanG970/org-warrior/issues/2"
       "{\"title\":\"A ↔ B\"}")
      (should-not (multibyte-string-p wire-body))
      (should (cl-every (lambda (byte) (< byte 128))
                        (string-to-list wire-body)))
      (should (equal (cdr (assoc 'title
                                 (json-read-from-string wire-body)))
                     "A ↔ B")))))

(ert-deftest org-sync-github-transport-errors-redact-token ()
  "url.el errors may include request headers; never echo credentials."
  (cl-letf (((symbol-function 'org-sync-github-token)
             (lambda () "test-secret-token"))
            ((symbol-function 'url-retrieve-synchronously)
             (lambda (_url)
               (error "request failed: Authorization: Bearer test-secret-token"))))
    (let ((message (error-message-string
                    (should-error (org-sync-github-url-retrieve-synchronously
                                   "https://api.github.com/repos/JuanG970/org-warrior/issues")))))
      (should-not (string-match-p "test-secret-token" message)))))

(ert-deftest org-sync-github-refuses-writes-without-cache ()
  "Missing baseline must not silently discard a local issue edit."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior"))
    (cl-letf (((symbol-function 'org-sync-get-cache) (lambda (_url) nil))
              ((symbol-function 'org-sync-github-fetch-labels) (lambda () nil)))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:id 2 :title "Locally changed" :status open))))
       :type 'user-error))))

(ert-deftest org-sync-github-rejects-filtered-property-sync ()
  "A partial plist can otherwise clear unrelated GitHub fields."
  (let ((org-sync-props '(:title))
        (org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior"))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) '(:bugs ((:id 2 :title "Old")))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (&rest _) (ert-fail "Filtered sync must not make API calls"))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:id 2 :title "New"))))
       :type 'user-error))))

(ert-deftest org-sync-github-rejects-uncached-local-edit ()
  "An issue absent from the baseline must not be marked synced if edited."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior"))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) '(:bugs ((:id 1 :title "Other")))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional _data)
                 (if (equal method "GET")
                     '((number . 2) (title . "Remote") (body . "same")
                       (state . "open") (labels . []))
                   (ert-fail "Must not write an uncached issue")))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:id 2 :title "Locally edited" :desc "same"
                      :status open :tags nil :assignee nil))))
       :type 'user-error))))

(ert-deftest org-sync-github-allows-uncached-remote-import ()
  "An issue created in GitHub can enter the mirror without a local write."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (methods nil))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) '(:bugs ((:id 1 :title "Other")))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional _data)
                 (push method methods)
                 '((number . 2) (title . "Remote") (body . "same")
                   (state . "open") (labels . [])))))
      (should (equal '(:bugs nil)
                     (org-sync-github-send-buglist
                      '(:bugs ((:id 2 :title "Remote" :desc "same\n"
                                    :status open :tags nil :assignee nil))))))
      (should (equal methods '("GET"))))))

(ert-deftest org-sync-github-preserves-decoded-multibyte-response ()
  "An already-decoded Unicode HTTP buffer must not be re-encoded as Latin-1."
  (let ((response (generate-new-buffer " *org-sync-decoded-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (insert "[{\"title\":\"漢↔😀\"}]"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (let ((issue (aref (car (org-sync-github-fetch-json-page
                                     "https://api.github.com/repos/JuanG970/org-warrior/issues")) 0)))
              (should (equal (cdr (assoc 'title issue)) "漢↔😀")))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-refuses-http-redirects ()
  "Bearer headers must never follow redirects to another host."
  (cl-letf (((symbol-function 'org-sync-github-token)
             (lambda () "sample-token"))
            ((symbol-function 'url-retrieve-synchronously)
             (lambda (_url)
               (should (zerop url-max-redirections))
               (current-buffer))))
    (org-sync-github-url-retrieve-synchronously
     "https://api.github.com/repos/JuanG970/org-warrior/issues")))

(ert-deftest org-sync-github-preflights-conflicts-before-post ()
  "Do not create a new issue before a later cached issue conflicts."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (cached '(:id 2 :title "Before" :status open :tags nil
                       :desc nil :assignee nil))
        (methods nil))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) `(:bugs (,cached))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional _data)
                 (push method methods)
                 (if (equal method "GET")
                     '((number . 2) (title . "Mobile changed")
                       (state . "open") (labels . []))
                   (ert-fail "Conflict must prevent all mutations")))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:title "New task" :status open :desc "new\n" :tags nil)
                (:id 2 :title "Locally changed" :status open :tags nil
                     :desc nil :assignee nil))))
       :type 'user-error)
      (should (equal methods '("GET"))))))

(ert-deftest org-sync-github-refuses-multiple-creates ()
  "Reject multiple non-idempotent POSTs before creating either issue."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior"))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) '(:bugs nil)))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (&rest _) (ert-fail "No POST should be sent"))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:title "One" :status open :tags nil)
                (:title "Two" :status open :tags nil))))
       :type 'user-error))))

(ert-deftest org-sync-github-preserves-decoded-latin1-range ()
  "Even Unicode characters below U+0100 may already be decoded."
  (let ((response (generate-new-buffer " *org-sync-decoded-latin1-test*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (insert "[{\"title\":\"é\"}]"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (let ((issue (aref (car (org-sync-github-fetch-json-page
                                     "https://api.github.com/repos/JuanG970/org-warrior/issues")) 0)))
              (should (equal (cdr (assoc 'title issue)) "é")))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-rejects-empty-transport-response ()
  "A timeout returning nil must not consume the caller's current buffer."
  (let ((caller (generate-new-buffer " *org-sync-caller*")))
    (unwind-protect
        (with-current-buffer caller
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) nil)))
            (should (string-match-p
                     "no response buffer"
                     (error-message-string
                      (should-error
                       (org-sync-github-fetch-json-page
                        "https://api.github.com/repos/JuanG970/org-warrior/issues")))))
            (should (buffer-live-p caller))))
      (when (buffer-live-p caller) (kill-buffer caller)))))

(ert-deftest org-sync-github-cleans-up-invalid-json-buffer ()
  "A malformed response must not leave its issue body in a live buffer."
  (let ((response (generate-new-buffer " *org-sync-bad-json*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\nnot-json"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (should-error
             (org-sync-github-fetch-json-page
              "https://api.github.com/repos/JuanG970/org-warrior/issues"))
            (should-not (buffer-live-p response))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-returns-fresh-patch-result-for-cache ()
  "A later mobile body edit must enter Org/cache with the title PATCH."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (cached '(:id 2 :title "Before" :desc "Old body\n" :status open
                       :tags nil :assignee nil)))
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) `(:bugs (,cached))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional _data)
                 (pcase method
                   ("GET" '((number . 2) (title . "Before")
                            (body . "Mobile body") (state . "open")
                            (labels . [])))
                   ("PATCH" '((number . 2) (title . "After")
                              (body . "Mobile body") (state . "open")
                              (labels . [])))))))
      (let* ((result (org-sync-github-send-buglist
                      '(:bugs ((:id 2 :title "After" :desc "Old body\n"
                                    :status open :tags nil :assignee nil)))))
             (refreshed (org-sync-get-bug-id result 2)))
        (should (equal (org-sync-get-prop :title refreshed) "After"))
        (should (equal (org-sync-get-prop :desc refreshed) "Mobile body\n"))))))

(ert-deftest org-sync-github-refuses-unknown-labels-before-writing ()
  "An issue write never creates labels as untracked side effects."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (org-sync-props nil)
        calls)
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) '(:bugs nil)))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (&rest args) (push args calls))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:title "Pilot" :status open :desc "Body\n"
                         :tags ("new-label")))))
       :type 'user-error)
      (should-not calls))))

(ert-deftest org-sync-github-untouched-markup-title-never-patches ()
  "Org markup, priority syntax, and tag suffixes are literal GitHub titles."
  (dolist (github-title '("A *bold* issue" "Fix :bug:"
                          "[#A] priority-ish" "OPEN at noon"))
    (let ((org-sync-cache-alist nil)
          (org-sync-props nil)
          (issue `((number . 42) (state . "open")
                   (title . ,github-title) (body . "Details")
                   (labels . [])
                   (created_at . "2026-09-29T12:00:00Z")
                   (updated_at . "2026-09-29T12:00:00Z")))
          writes)
      (with-temp-buffer
        (org-mode)
        (cl-letf (((symbol-function 'org-sync-github-fetch-json)
                   (lambda (url)
                     (if (string-match-p "state=closed" url) []
                       (if (string-match-p "/issues" url) (vector issue) []))))
                  ((symbol-function 'org-sync-github-request)
                   (lambda (method _url &optional data)
                     (if (equal method "GET") issue
                       (push (cons method data) writes)
                       issue))))
          (org-sync-import "https://api.github.com/repos/JuanG970/org-warrior")
          (should (string-match-p (regexp-quote github-title) (buffer-string)))
          (org-sync)
          (org-sync)
          (should-not writes)
          (should (equal (org-sync-get-prop :title
                                            (org-sync-get-bug-id
                                             (org-sync-get-cache "https://api.github.com/repos/JuanG970/org-warrior")
                                             42))
                         github-title)))))))

(ert-deftest org-sync-github-milestone-deadline-never-changes-title ()
  "A milestone due date rendered as an Org deadline must not enter the title."
  (let ((org-sync-cache-alist nil)
        (org-sync-props nil)
        (issue '((number . 42) (state . "open")
                 (title . "Due issue") (body . "Details") (labels . [])
                 (milestone . ((title . "v1") (due_on . "2026-10-30T12:00:00Z")))
                 (created_at . "2026-09-29T12:00:00Z")
                 (updated_at . "2026-09-29T12:00:00Z")))
        writes)
    (with-temp-buffer
      (org-mode)
      (cl-letf (((symbol-function 'org-sync-github-fetch-json)
                 (lambda (url)
                   (if (string-match-p "state=closed" url) []
                     (if (string-match-p "/issues" url) (vector issue) []))))
                ((symbol-function 'org-sync-github-request)
                 (lambda (method _url &optional data)
                   (if (equal method "GET") issue
                     (push (cons method data) writes)
                     issue))))
        (org-sync-import "https://api.github.com/repos/JuanG970/org-warrior")
        (should (string-match-p "\nDEADLINE: <" (buffer-string)))
        (org-sync)
        (org-sync)
        (should-not writes)
        (should (time-equal-p
                 (org-sync-get-prop :date-deadline
                                    (org-sync-get-bug-id
                                     (org-sync-get-cache "https://api.github.com/repos/JuanG970/org-warrior")
                                     42))
                 (date-to-time "2026-10-30T12:00:00Z")))
        (should (equal (org-sync-get-prop :title
                                          (org-sync-get-bug-id
                                           (org-sync-get-cache "https://api.github.com/repos/JuanG970/org-warrior")
                                           42))
                       "Due issue"))))))

(ert-deftest org-sync-github-rejects-multiple-writes-per-sync ()
  "A later failed PATCH cannot leave a prior issue changed without a cache."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (cached-a '(:id 2 :title "A" :status open :tags nil :desc nil :assignee nil))
        (cached-b '(:id 3 :title "B" :status open :tags nil :desc nil :assignee nil))
        methods)
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) `(:bugs (,cached-a ,cached-b))))
              ((symbol-function 'org-sync-github-fetch-labels) (lambda () nil))
              ((symbol-function 'org-sync-github-request)
               (lambda (method url &optional _data)
                 (push method methods)
                 (if (equal method "GET")
                     `((number . ,(if (string-match-p "/2$" url) 2 3))
                       (title . ,(if (string-match-p "/2$" url) "A" "B"))
                       (state . "open") (labels . []))
                   (ert-fail "Multiple edits must not PATCH")))))
      (should-error
       (org-sync-github-send-buglist
        '(:bugs ((:id 2 :title "A updated" :status open :tags nil)
                (:id 3 :title "B updated" :status open :tags nil))))
       :type 'user-error)
      (should (equal (sort methods #'string<) '("GET" "GET"))))))

(ert-deftest org-sync-github-preserves-decoded-mojibake-looking-title ()
  "Multibyte Unicode text is already decoded, even when it resembles UTF-8 bytes."
  (let ((response (generate-new-buffer " *org-sync-ambiguous-title*")))
    (unwind-protect
        (progn
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
            (insert "{\"title\":\"Ã©\"}"))
          (cl-letf (((symbol-function 'org-sync-github-url-retrieve-synchronously)
                     (lambda (_url) response)))
            (should (equal (cdr (assoc 'title
                                       (car (org-sync-github-fetch-json-page
                                             "https://api.github.com/repos/JuanG970/org-warrior/issues/42"))))
                           "Ã©"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest org-sync-github-allows-anonymous-public-reads ()
  "Public GET works without a token, but GitHub writes still require one."
  (let ((calls 0) headers)
    (cl-letf (((symbol-function 'org-sync-github-token)
               (lambda () (user-error "No token configured")))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (_url)
                 (cl-incf calls)
                 (setq headers url-request-extra-headers)
                 (current-buffer))))
      (let ((url-request-method "GET"))
        (org-sync-github-url-retrieve-synchronously
         "https://api.github.com/repos/JuanG970/org-warrior/issues"))
      (should (= calls 1))
      (should-not (assoc "Authorization" headers))
      (let ((url-request-method "PATCH"))
        (should-error
         (org-sync-github-url-retrieve-synchronously
          "https://api.github.com/repos/JuanG970/org-warrior/issues/2")
         :type 'user-error))
      (should (= calls 1)))))

(ert-deftest org-sync-github-refuses-multiple-repos-in-one-buffer ()
  "Separate GitHub mirrors prevent cross-repo partial writes."
  (with-temp-buffer
    (insert "#+TODO: OPEN | CLOSED\n"
            "* Issues of org-warrior\n:PROPERTIES:\n:url: https://api.github.com/repos/JuanG970/org-warrior\n:END:\n"
            "* Issues of org-sync\n:PROPERTIES:\n:url: https://api.github.com/repos/JuanG970/org-sync\n:END:\n")
    (org-mode)
    (cl-letf (((symbol-function 'org-sync-github-fetch-json)
               (lambda (&rest _) (ert-fail "Multi-repo sync must not fetch")))
              ((symbol-function 'org-sync-github-request)
               (lambda (&rest _) (ert-fail "Multi-repo sync must not write"))))
      (should-error (org-sync) :type 'user-error))))

(ert-deftest org-sync-github-existing-label-update-needs-one-patch ()
  "A pre-existing GitHub label can be applied without creating another label."
  (let ((org-sync-base-url "https://api.github.com/repos/JuanG970/org-warrior")
        (cached '(:id 2 :title "Pilot" :status open :desc "Body\n"
                       :assignee nil :tags nil))
        methods)
    (cl-letf (((symbol-function 'org-sync-get-cache)
               (lambda (_url) `(:bugs (,cached))))
              ((symbol-function 'org-sync-github-fetch-labels)
               (lambda () '("pilot")))
              ((symbol-function 'org-sync-github-request)
               (lambda (method _url &optional data)
                 (push method methods)
                 (pcase method
                   ("GET" '((number . 2) (title . "Pilot") (body . "Body")
                            (state . "open") (labels . [])))
                   ("PATCH"
                    (should (equal (cdr (assoc 'labels (json-read-from-string data)))
                                   ["pilot"]))
                    '((number . 2) (title . "Pilot") (body . "Body")
                      (state . "open") (labels . [((name . "pilot"))])))
                   (_ (ert-fail "Must not create a label"))))))
      (let ((result (org-sync-github-send-buglist
                     '(:bugs ((:id 2 :title "Pilot" :status open
                                   :desc "Body\n" :assignee nil :tags ("pilot")))))))
        (should (equal (reverse methods) '("GET" "PATCH")))
        (should (equal (org-sync-get-prop :tags (org-sync-get-bug-id result 2))
                       '("pilot")))))))

(ert-deftest org-sync-github-refuses-nested-repo-heading ()
  "A nested repository heading must not become a new issue in its parent."
  (with-temp-buffer
    (insert "#+TODO: OPEN | CLOSED\n"
            "* Issues of org-warrior\n:PROPERTIES:\n:url: https://api.github.com/repos/JuanG970/org-warrior\n:END:\n"
            "** OPEN Issues of org-sync\n:PROPERTIES:\n:url: https://api.github.com/repos/JuanG970/org-sync\n:END:\n")
    (org-mode)
    (cl-letf (((symbol-function 'org-sync-github-fetch-json)
               (lambda (&rest _) (ert-fail "Nested repo must not fetch")))
              ((symbol-function 'org-sync-github-request)
               (lambda (&rest _) (ert-fail "Nested repo must not write"))))
      (should-error (org-sync) :type 'user-error))))

(provide 'org-sync-github-test)
;;; org-sync-github-test.el ends here
