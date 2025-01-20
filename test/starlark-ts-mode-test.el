(require 'ert)
(require 'starlark-ts-mode)

(defun ensure-starlark-grammar ()
  "Ensure that the Starlark grammar is installed for Tree-sitter."
  (unless (treesit-ready-p 'starlark)
    (setq treesit-language-source-alist
          '((starlark "https://github.com/tree-sitter-grammars/tree-sitter-starlark")))
    (treesit-install-language-grammar 'starlark)))

(defmacro with-starlark-grammar (&rest body)
  "Ensure Starlark grammar is installed and execute BODY."
  `(progn
     (ensure-starlark-grammar)
     ,@body))

(ert-deftest starlark-ts-mode-test ()
  "Test that `starlark-ts-mode` sets up the mode correctly."
  (with-starlark-grammar
   (with-temp-buffer
     (starlark-ts-mode)
     (should (eq major-mode 'starlark-ts-mode))
     (should (equal comment-start "# "))
     (should (equal comment-start-skip "#+\\s-*"))
     (should (local-variable-p 'treesit-font-lock-feature-list))
     ;; TODO: Real Starlark indent rules using Tree-sitter.
     ;;(should (local-variable-p 'treesit-simple-indent-rules))
     )))

(ert-deftest starlark-ts-mode-font-lock-test ()
  "Test that `starlark-ts-mode` font locks correctly."
  (with-starlark-grammar
   (with-temp-buffer
     (starlark-ts-mode)
     (insert "def my_function():\n  # This is a comment\n  return True\n")
     (font-lock-ensure)
     (goto-char (point-min))
     (should (equal (get-text-property (point) 'face) 'font-lock-keyword-face)) ;; "def"
     (forward-word 2)
     (should (equal (get-text-property (point) 'face) 'font-lock-function-name-face)) ;; "my_function"
     (forward-line)
     (forward-word)
     (should (equal (get-text-property (point) 'face) 'font-lock-comment-face)) ;; "# This is a comment"
     (forward-line)
     (forward-word 2)
     (backward-word)
     (should (equal (get-text-property (point) 'face) 'font-lock-constant-face))))) ;; "True"

(ert-deftest starlark-ts-mode-indentation-test ()
  "Test `starlark-ts-mode` indentation rules."
  (with-starlark-grammar
   (with-temp-buffer
     (starlark-ts-mode)
     (insert "def foo():\npass\n")
     (indent-region (point-min) (point-max))
     (goto-char (point-min))
     (forward-line 1)
     (should (equal (current-indentation) starlark-ts-indent-offset)))))

(ert-deftest starlark-ts-mode-syntax-test ()
  "Check that the syntax table is correctly set for comments."
  (with-starlark-grammar
   (with-temp-buffer
     (starlark-ts-mode)
     (insert "# a comment")
     (goto-char (point-min))
     (forward-word)
     ;; NOTE: 36.6.3 Parser State
     ;;   4. ‘t’ if inside a non-nestable comment
     (should (nth 4 (syntax-ppss))))))
