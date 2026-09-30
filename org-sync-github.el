;;; org-sync-github.el --- Github backend for org-sync.
;;
;; Copyright (C) 2012  Aurelien Aptel
;;
;; Author: Aurelien Aptel <aurelien dot aptel at gmail dot com>
;; Keywords: org, github, synchronization
;; Homepage: https://github.com/arbox/org-sync
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; This file is not part of GNU Emacs.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; This package implements a backend for org-sync to synchnonize
;; issues from a github tracker with an org-mode buffer.  Read
;; Org-sync documentation for more information about it.
;;
;; This backend supports basic issue synchronization and existing labels.
;; Create new labels explicitly in GitHub before using them in a sync.
;;
;;; Code:

(require 'cl-lib)
(require 'url)
(require 'org-sync)
(require 'json)
(require 'auth-source)
(require 'subr-x)

(defvar org-sync-github-backend
  '((base-url      . org-sync-github-base-url)
    (fetch-buglist . org-sync-github-fetch-buglist)
    (send-buglist  . org-sync-github-send-buglist))
  "Github backend.")

(defvar url-http-end-of-headers)

(defun org-sync-github-token ()
  "Get a GitHub API token from auth-source or the authenticated gh CLI.
Never store tokens in an Org buffer or in Emacs configuration."
  (let* ((entry (car (auth-source-search :host "api.github.com"
                                         :require '(:secret) :max 1)))
         (secret (plist-get entry :secret))
         (token (if (functionp secret) (funcall secret) secret)))
    (unless (and (stringp token) (not (string-empty-p token)))
      (when (executable-find "gh")
        (with-temp-buffer
          (when (eq 0 (process-file "gh" nil t nil "auth" "token"))
            (setq token (string-trim (buffer-string)))))))
    (unless (and (stringp token) (not (string-empty-p token)))
      (user-error "Set up auth-source for api.github.com or run gh auth login"))
    token))

(defun org-sync-github-fetch-labels ()
  "Return list of labels at org-sync-base-url."
  (let* ((url (concat org-sync-base-url "/labels"))
         (json (org-sync-github-fetch-json url)))
    (mapcar (lambda (x)
              (cdr (assoc 'name x)))
            json)))

(defun org-sync-github-random-color ()
  "Return a random hex color code 6 characters string without #."
  (random t)
  (format "%02X%02X%02X" (random 256) (random 256) (random 256)))

(defun org-sync-github-color-p (color)
  "Return non-nil if COLOR is a valid color code."
  (and (stringp color) (string-match "^[0-9a-fA-F]\\{6\\}$" color)))

(defun org-sync-github-create-label (label &optional color)
  "Create new COLOR LABEL at org-sync-base-url and return it.

LABEL must be a string.  COLOR must be a 6 characters string
containing a hex color code without the #.  Take a random color
when not given."
  (let* ((url (concat org-sync-base-url "/labels"))
         (json (json-encode `((name . ,label)
                              (color . ,(if (org-sync-github-color-p color)
                                            color
                                          (org-sync-github-random-color)))))))
    (org-sync-github-request "POST" url json)))

(defun org-sync-github-validate-tags (bug existing-tags)
  "Reject labels in BUG that are not already in EXISTING-TAGS.
Labels should be created deliberately in GitHub, not as extra sync writes."
  (dolist (tag (org-sync-get-prop :tags bug))
    (unless (member tag existing-tags)
      (user-error "Create GitHub label %s before syncing" tag))))

(defun org-sync-github-time-to-string (time)
  "Return TIME as a full ISO 8601 date string, but without timezone adjustments (which github doesn't support"
  (format-time-string "%Y-%m-%dT%TZ" time t))

;; override
(defun org-sync-github-fetch-buglist (last-update)
  "Return the buglist at org-sync-base-url."
  (let* ((since (when last-update
                  (format "&since=%s" (org-sync-github-time-to-string last-update))))
         (url (concat org-sync-base-url "/issues?per_page=100" since))
         (json (vconcat (org-sync-github-fetch-json url)
                        (org-sync-github-fetch-json (concat url "&state=closed"))))
         (title (concat "Issues of " (org-sync-github-repo-name url))))

    `(:title ,title
             :url ,org-sync-base-url
             :bugs ,(mapcar #'org-sync-github-json-to-bug
                            (cl-remove-if (lambda (issue)
                                            (assoc 'pull_request issue))
                                          (append json nil)))
             :since ,last-update)))

;; override
(defun org-sync-github-base-url (url)
  "Return base url."
  (when (string-match "github.com/\\(?:repos/\\)?\\([^/]+\\)/\\([^/]+\\)" url)
    (let ((user (match-string 1 url))
          (repo (match-string 2 url)))
    (concat "https://api.github.com/repos/" user "/" repo ""))))

;; override
(defun org-sync-github-send-buglist (buglist)
  "Send a BUGLIST on the bugtracker and return new bugs."
  (when org-sync-props
    (user-error "GitHub sync does not support org-sync-props filtering"))
  (let* ((new-url (concat org-sync-base-url "/issues"))
         (cache (or (org-sync-get-cache org-sync-base-url)
                    (user-error "No GitHub sync cache; import the repository first")))
         (existing-tags (org-sync-github-fetch-labels))
         updates creates newbugs)
    ;; Resolve all baselines and conflicts before any POST, PATCH, or label
    ;; creation.  In particular, an unrelated conflict must not orphan a
    ;; newly created issue ID when org-sync aborts its cache update.
    (dolist (b (org-sync-get-prop :bugs buglist))
      (let* ((id (org-sync-get-prop :id b))
             (modif-url (and id (format "%s/%d" new-url id)))
             (cached (and id (org-sync-get-bug-id cache id))))
        (cond
         ((null id)
          (push (cons b (org-sync-github-bug-to-json b)) creates))
         ((null cached)
          ;; A newly imported remote issue is read-only until cached.  If
          ;; it differs from the live issue, the local edit needs a baseline.
          (let ((remote (org-sync-github-json-to-bug
                         (org-sync-github-request "GET" modif-url))))
            (unless (cl-every
                     (lambda (prop)
                       (equal (org-sync-get-prop prop b)
                              (org-sync-get-prop prop remote)))
                     '(:title :desc :status :assignee :tags))
              (user-error "GitHub issue #%s has no cached baseline; import or refresh before editing"
                          id))))
         (t
          (let* ((remote (org-sync-github-json-to-bug
                          (org-sync-github-request "GET" modif-url)))
                 (changes (org-sync-github-update-data cached b remote)))
            (when changes
              (push (list modif-url changes b) updates)))))))
    ;; The GitHub API has no idempotent issue-creation key.  Multiple POSTs
    ;; could leave created IDs unrecorded if a later request fails.
    (when (cdr creates)
      (user-error "Create only one new GitHub issue per sync"))
    ;; Without transactions, a second write failure would leave GitHub ahead
    ;; of the still-unsaved Org buffer and cache.  Keep the manual pilot to
    ;; one changed issue at a time.
    (when (> (+ (length updates) (length creates)) 1)
      (user-error "Change only one GitHub issue per sync"))
    (dolist (update (nreverse updates))
      (pcase-let ((`(,url ,changes ,bug) update))
        (when (assoc 'labels changes)
          (org-sync-github-validate-tags bug existing-tags))
        ;; Use the server's full response as the merged issue.  A mobile edit
        ;; to another field can land between the list fetch and this PATCH;
        ;; retaining the stale local copy would poison the next cache baseline.
        (let* ((patched (org-sync-github-request "PATCH" url (json-encode changes)))
               (id (cdr (assoc 'number patched))))
          (unless (equal id (org-sync-get-prop :id bug))
            (user-error "GitHub PATCH response has an unexpected issue ID; inspect GitHub before retrying"))
          (push (org-sync-github-json-to-bug patched) newbugs))))
    (dolist (creation creates)
      (org-sync-github-validate-tags (car creation) existing-tags)
      (let* ((created (org-sync-github-request "POST" new-url (cdr creation)))
             (id (cdr (assoc 'number created))))
        (unless (numberp id)
          (user-error "GitHub issue creation response lacks an ID; inspect GitHub before retrying"))
        (push (org-sync-github-json-to-bug created) newbugs)))
    `(:bugs ,newbugs)))

(defun org-sync-github-fetch-json (url)
  "Return a parsed JSON object of all the pages of URL."
  (let* ((ret (org-sync-github-fetch-json-page url))
         (data (car ret))
         (url (cdr ret))
         (json data))

    (while url
      (setq ret (org-sync-github-fetch-json-page url))
      (setq data (car ret))
      (setq url (cdr ret))
      (setq json (vconcat json data)))

    json))

(defun org-sync-github-url-retrieve-synchronously (url)
  "Retrieve URL from the GitHub API using a bearer token."
  (unless (string-match-p "\\`https://api\\.github\\.com/" url)
    (error "Refusing to send GitHub token to non-API URL"))
  (let* ((read-only (member (or url-request-method "GET") '("GET" "HEAD")))
         (token (if read-only
                    (condition-case nil
                        (org-sync-github-token)
                      (error nil))
                  (org-sync-github-token)))
         (url-max-redirections 0)
         (url-request-extra-headers
          (append (when token
                    `(("Authorization" . ,(concat "Bearer " token))))
                  '(("Accept" . "application/vnd.github+json")
                    ("X-GitHub-Api-Version" . "2022-11-28"))
                  (when url-request-data '(("Content-Type" . "application/json")))
                  url-request-extra-headers)))
    ;; url.el can include the full Authorization header in its errors.
    (condition-case nil
        (url-retrieve-synchronously url)
      (error (error "GitHub API transport failed for %s (details redacted)" url)))))

(defun org-sync-github-fetch-json-page (url)
  "Return a cons (JSON object from URL . next page url)."
  (let ((download-buffer (org-sync-github-url-retrieve-synchronously url))
        page-next
        header-end
        ret)

    (unless (buffer-live-p download-buffer)
      (error "GitHub API returned no response buffer for %s" url))
    (unwind-protect
        (with-current-buffer download-buffer
          (goto-char (point-min))
          (unless (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
            (error "GitHub API returned an invalid HTTP response"))
          (let ((status (string-to-number (match-string 1))))
            (unless (<= 200 status 299)
              (error "GitHub API HTTP %d at %s" status url)))
      ;; get HTTP header end position
      (goto-char (point-min))
      (re-search-forward "^$" nil 'move)
      (forward-char)
      (setq header-end (point))

      ;; get next page url
      (goto-char (point-min))
      (when (re-search-forward
             "<\\(https://api.github.com.+?page=[0-9]+.*?\\)>; rel=\"next\""
             header-end t)
        (setq page-next (match-string 1)))

      (goto-char header-end)
      (let ((body (buffer-substring-no-properties header-end (point-max))))
        ;; url.el returns unibyte UTF-8 response bytes.  A multibyte
        ;; buffer has already been decoded; guessing from byte-looking
        ;; characters would corrupt legitimate titles such as "Ã©".
        (setq ret (cons (json-read-from-string
                         (if (multibyte-string-p body)
                             body
                           (decode-coding-string body 'utf-8)))
                        page-next))
        ret))
      (when (buffer-live-p download-buffer)
        (kill-buffer download-buffer)))))

(defun org-sync-github-ascii-json (data)
  "Encode JSON DATA as ASCII with Unicode escape sequences for url.el."
  (encode-coding-string
   (mapconcat (lambda (char)
                (cond ((< char 128) (char-to-string char))
                      ((<= char #xffff) (format "\\u%04x" char))
                      (t (let ((code (- char #x10000)))
                           (format "\\u%04x\\u%04x"
                                   (+ #xd800 (ash code -10))
                                   (+ #xdc00 (logand code #x3ff)))))))
              (string-to-list data) "")
   'us-ascii))

(defun org-sync-github-request (method url &optional data)
  "Send HTTP METHOD with DATA to URL and parse the UTF-8 JSON response."
  (let ((url-request-method method)
        (url-request-data (and data (org-sync-github-ascii-json data))))
    (car (org-sync-github-fetch-json-page url))))

(defun org-sync-github-repo-name (url)
  "Return the name of the repo at URL."
  (if (string-match "github.com/repos/[^/]+/\\([^/]+\\)" url)
      (match-string 1 url)
    "<project name>"))

;; XXX: we need an actual markdown parser here...
(defun org-sync-github-filter-desc (desc)
  "Return a filtered description of a GitHub description."
  (if desc (progn
             (setq desc (replace-regexp-in-string "\r\n" "\n" desc))
             (setq desc (replace-regexp-in-string "\\([^ \t\n]\\)[ \t\n]*\\'"
                                                  "\\1\n" desc)))))

(defun org-sync-github-json-to-bug (data)
  "Return DATA (in json) converted to a bug."
  (cl-flet* ((va (key alist) (cdr (assoc key alist)))
             (v (key) (va key data)))
    (let* ((id (v 'number))
           (stat (if (string= (v 'state) "open") 'open 'closed))
           (title (v 'title))
           (desc  (org-sync-github-filter-desc (v 'body)))
           (author (va 'login (v 'user)))
           (assignee (va 'login (v 'assignee)))
           (milestone-alist (v 'milestone))
           (milestone (va 'title milestone-alist))
           (ctime (org-sync-parse-date (v 'created_at)))
           (dtime (org-sync-parse-date (va 'due_on milestone-alist)))
           (mtime (org-sync-parse-date (v 'updated_at)))
           (tags (mapcar (lambda (e)
                           (va 'name e)) (v 'labels))))

      `(:id ,id
            :author ,author
            :assignee ,assignee
            :status ,stat
            :title ,title
            :desc ,desc
            :milestone ,milestone
            :tags ,tags
            :date-deadline ,dtime
            :date-creation ,ctime
            :date-modification ,mtime))))

(defun org-sync-github-update-data (cached local remote)
  "Return GitHub PATCH fields changed from CACHED to LOCAL.
Do not overwrite a REMOTE change to the same field without review."
  (let (changes)
    (dolist (mapping '((:title . title) (:desc . body)
                       (:assignee . assignee) (:status . state)
                       (:tags . labels)))
      (let* ((prop (car mapping))
             (before (org-sync-get-prop prop cached))
             (after (org-sync-get-prop prop local))
             (current (org-sync-get-prop prop remote)))
        (unless (equal before after)
          (unless (or (equal before current) (equal after current))
            (user-error "GitHub issue changed remotely in %s; refresh and resolve"
                        (cdr mapping)))
          (unless (equal after current)
            (push (cons (cdr mapping)
                        (pcase prop
                          (:status
                           (unless (memq after '(open closed))
                             (user-error "Unsupported GitHub issue state: %s" after))
                           (symbol-name after))
                          (:tags (vconcat after))
                          (_ after)))
                  changes)))))
    (nreverse changes)))

(defun org-sync-github-bug-to-json (bug)
  "Return BUG as JSON."
  (let ((state (org-sync-get-prop :status bug)))
    (unless (member state '(open closed))
      (error "Github: unsupported state \"%s\"" (symbol-name state)))

  (json-encode
   `((title . ,(org-sync-get-prop :title bug))
     (body . ,(org-sync-get-prop :desc bug))
     (assignee . ,(org-sync-get-prop :assignee bug))
     (state . ,(symbol-name (org-sync-get-prop :status bug)))
     (labels . [ ,@(org-sync-get-prop :tags bug) ])))))

(provide 'org-sync-github)
;;; org-sync-github.el ends here
