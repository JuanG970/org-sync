[![License GPL 3][badge-license]](http://www.gnu.org/licenses/gpl-3.0.txt)
[![MELPA](http://melpa.org/packages/org-sync-badge.svg)](http://melpa.org/#/org-sync)
[![MELPA Stable](http://stable.melpa.org/packages/org-sync-badge.svg)](http://stable.melpa.org/#/org-sync)
[![Build Status](https://img.shields.io/travis/arbox/org-sync.svg)](https://travis-ci.org/arbox/org-sync)

# Org-sync: Synchronize Org-mode Files with Bug Tracking systems

*CAUTION* This package is under a heavy reconstration, please be patient.
Feel free to contribute!

Org-sync is a tool to synchronize online bugtrackers with org documents.
It is made for relatively small/medium projects: I find Org documents are not
really suited for handling large bug lists.

`Org-sync` was developed during the Google Summer of Code 2012, the original project
page can be found on Worg:
http://orgmode.org/worg/org-contrib/gsoc2012/student-projects/org-sync/.

## Installation

The ordinal way to install `Org-sync` is to issue the command:

```
M-x package-install RET org-sync RET
```

You could use the bleeding edge version from the repository:

```
git clone https://github.com/arbox/org-sync.git
```

Put the `org-sync` directory in your load-path and load the `org-sync` backend you
need. You can add this to your `.emacs`:

``` emacs-lisp
(add-to-list 'load-path "path/to/org-sync")
(mapc 'load
      '("org-sync" "org-sync-bb" "org-sync-github" "org-sync-redmine"))
```

## Tutorial

After you have installed `org-sync` you need to import a working project.

First open a new org-mode buffer and run `M-x org-sync-import`.  It prompts you
for an URL.  You can try my Github test repo: `github.com/arbox/org-sync-test`.
Org-sync should import the issues from the repo.

*Note*: This is just a test repo, do not use it to report actual bugs.

Try adding `** OPEN my test issue` under the imported project heading,
then run `M-x org-sync`. For GitHub writes, use an `auth-source` token
for `api.github.com` or run `gh auth login`; never put a password or token
in your Emacs config. Public issue lists can be read without a token;
private repositories and all writes require authentication. The backend
sends a bearer token only to the GitHub API host.

The cache holds the baseline for three-way sync. Load it before syncing
a previously imported file, then persist it after each successful
import or sync (the package does not save it automatically):

```emacs-lisp
(require 'org-sync-github)
(org-sync-load-cache)
;; With a dedicated GitHub mirror buffer open:
(org-sync)
(save-buffer)
(org-sync-write-cache)
```

Start with one repository and a disposable issue. GitHub Issues are the
source of truth; keep private notes outside the mirror. The backend
syncs titles, bodies, OPEN/CLOSED state, assignee and labels, but not
comments or PR reviews. It excludes PRs returned by GitHub's `/issues`
endpoint. Updates PATCH changed fields only and stop if a field has
diverged since the cached version; do not use unattended sync while
the same issue is being edited elsewhere. Filtered `org-sync-props`
sync is not supported by this GitHub backend. The underlying `org-sync`
merge works at issue granularity: simultaneous edits to different fields
of the same issue can still require manual conflict resolution. Refresh
before editing when another device has changed an issue. Keep exactly
one GitHub repository heading per mirror file. This pilot allows only one
issue write per sync (create or update); pull-only syncs can refresh
multiple issues. Create labels in GitHub before using them in an Org
issue; sync will not auto-create labels. GitHub does not provide an
idempotent create operation: if a POST fails or times out, inspect GitHub
before retrying to avoid duplicates. Keep the mirror private when issue
bodies are sensitive. The persistent cache contains copies of them and
is written atomically with owner-only permissions. Milestone due dates
appear as Org planning deadlines, but this backend does not push deadline
or milestone changes back to GitHub.

Run the fork's focused tests with:

```sh
emacs -Q --batch -L . -L test \
  -l test/org-sync-cache-test.el -l test/org-sync-github-test.el \
  -f ert-run-tests-batch-and-exit
```

## How to write a new backend

Writing a new backend is easy.  If something is not clear, try to read
the header in `org-sync.el` or one of the existing backend.

``` emacs-lisp
;; backend symbol/name: demo
;; the symbol is used to find and call your backend functions (for now)

;; what kind of urls does you backend handle?
;; add it to org-sync-backend-alist in org-sync.el:

(defvar org-sync-backend-alist
  '(("github.com/\\(?:repos/\\)?[^/]+/[^/]+"  . org-sync-github-backend)
    ("bitbucket.org/[^/]+/[^/]+"              . org-sync-bb-backend)
    ("demo.com"                               . org-sync-demo-backend)))

;; if you have already loaded org-sync.el, you'll have to add it
;; manually in that case just eval this in *scratch*
(add-to-list 'org-sync-backend-alist (cons "demo.com" 'org-sync-demo-backend))

;; now, in its own file org-sync-demo.el:

(require 'org-sync)

;; this is the variable used in org-sync-backend-alist
(defvar org-sync-demo-backend
  '((base-url      . org-sync-demo-base-url)
    (fetch-buglist . org-sync-demo-fetch-buglist)
    (send-buglist  . org-sync-demo-send-buglist))
  "Demo backend.")


;; this overrides org-sync--base-url.
;; the argument is the url the user gave.
;; it must return a cannonical version of the url that will be
;; available to your backend function in the org-sync-base-url variable.

;; In the github backend, it returns API base url
;; ie. https://api.github/reposa/<user>/<repo>

(defun org-sync-demo-base-url (url)
  "Return proper URL."
  "http://api.demo.com/foo")

;; this overrides org-sync--fetch-buglist
;; you can use the variable org-sync-base-url
(defun org-sync-demo-fetch-buglist (last-update)
  "Fetch buglist from demo.com (anything that happened after LAST-UPDATE)"
  ;; a buglist is just a plist
  `(:title "Stuff at demo.com"
           :url ,org-sync-base-url

           ;; add a :since property set to last-update if you return
           ;; only the bugs updated since it.  omit it or set it to
           ;; nil if you ignore last-update and fetch all the bugs of
           ;; the repo.

           ;; bugs contains a list of bugs
           ;; a bug is a plist too
           :bugs ((:id 1 :title "Foo" :status open :desc "bar."))))

;; this overrides org-sync--send-buglist
(defun org-sync-demo-send-buglist (buglist)
  "Send BUGLIST to demo.com and return updated buglist"
  ;; here you should loop over :bugs in buglist
  (dolist (b (org-sync-get-prop :bugs buglist))
    (cond
      ;; new bug (no id)
      ((null (org-sync-get-prop :id b)
        '(do-stuff)))

      ;; delete bug
      ((org-sync-get-prop :delete b)
        '(do-stuff))

      ;; else, modified bug
      (t
        '(do-stuff))))

  ;; return any bug that has changed (modification date, new bugs,
  ;; etc).  they will overwrite/be added in the buglist in org-sync.el

  ;; we return the same thing for the demo.
  ;; :bugs is the only property used from this function in org-sync.el
  `(:bugs ((:id 1 :title "Foo" :status open :desc "bar."))))
```

That's it.  A bug has to have at least an id, title and status properties.
Other recognized but optionnal properties are `:date-deadline`,
`:date-creation`, `:date-modification`, `:desc`. Any other properties are
automatically added in the `PROPERTIES` block of the bug via `prin1-to-string`
and are `read` back by org-sync.  All the dates are regular emacs time object.
For more details you can look at the github backend in `org-sync-github.el`.

## More information

You can find more in the `org-sync.el` commentary headers.

[badge-license]: https://img.shields.io/badge/license-GPL_3-green.svg
