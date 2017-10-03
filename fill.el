;; Copyright 2017 The Go Authors. All rights reserved.
;; Use of this source code is governed by a BSD-style
;; license that can be found in the LICENSE file.

;; This makes fill-paragraph (M-q) add line breaks at sentence
;; boundaries in addition to normal wrapping. This is the style for Go
;; proposals.
;;
;; Loading this script automatically enables this for markdown-mode
;; buffers in the go-design/proposal directory. It can also be
;; manually enabled with M-x enable-fill-split-sentences.
;;
;; This is sensitive to the setting of `sentence-end-double-space`,
;; which defaults to t. If `sentence-end-double-space` is t, but a
;; paragraph only a single space between sentences, this will not
;; insert line breaks where expected.

(defun fill-split-sentences (&optional justify)
  "Fill paragraph at point, breaking lines at sentence boundaries."
  (interactive)
  (save-excursion
    ;; Do a trial fill and get the fill prefix for this paragraph.
    (let ((prefix (or (fill-paragraph) ""))
          (end (progn (fill-forward-paragraph 1) (point)))
          (beg (progn (fill-forward-paragraph -1) (point))))
      (save-restriction
        (narrow-to-region (line-beginning-position) end)
        ;; Unfill the paragraph.
        (let ((fill-column (point-max)))
          (fill-region beg end))
        ;; Fill each sentence.
        (goto-char (point-min))
        (while (not (eobp))
          (if (bobp)
              ;; Skip over initial prefix.
              (goto-char beg)
            ;; Clean up space between sentences.
            (skip-chars-forward " \t")
            (delete-horizontal-space 'backward-only)
            (insert "\n" prefix))
          (let ((sbeg (point))
                (fill-prefix prefix))
            (forward-sentence)
            (fill-region-as-paragraph sbeg (point)))))
      prefix)))

(defun enable-fill-split-sentences ()
  "Make fill break lines at sentence boundaries in this buffer."
  (interactive)
  (setq-local fill-paragraph-function #'fill-split-sentences))

(defun proposal-enable-fill-split ()
  (when (string-match "go-proposal/design/" (buffer-file-name))
    (enable-fill-split-sentences)))

;; Enable sentence splitting in new proposal buffers.
(add-hook 'markdown-mode-hook #'proposal-enable-fill-split)

;; Enable sentence splitting in this buffer, in case the user loaded
;; fill.el when already in a buffer.
(when (eq major-mode 'markdown-mode)
  (proposal-enable-fill-split))
