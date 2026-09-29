;;; org-sync-cache-test.el --- Persistent cache safety -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-sync)

(ert-deftest org-sync-cache-survives-org-text-properties ()
  "Issue titles from org-element have parent properties with cyclic trees."
  (let* ((org-sync-cache-file (make-temp-file "org-sync-cache-test-"))
         (title (copy-sequence "Pilot issue"))
         (org-sync-cache-alist nil))
    (unwind-protect
        (progn
          (put-text-property 0 (length title) :parent (list title) title)
          (org-sync-set-cache "url" `(:title ,title :bugs ((:id 2 :title ,title))))
          (set-file-modes org-sync-cache-file #o644)
          (org-sync-write-cache)
          (should (zerop (logand (file-modes org-sync-cache-file) #o077)))
          (setq org-sync-cache-alist nil)
          (org-sync-load-cache)
          (should (equal (org-sync-get-prop :title (org-sync-get-cache "url"))
                         "Pilot issue"))
          (should-not (text-properties-at 0
                                          (org-sync-get-prop :title
                                                             (org-sync-get-cache "url")))))
      (delete-file org-sync-cache-file))))

(provide 'org-sync-cache-test)
;;; org-sync-cache-test.el ends here
