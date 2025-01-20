;;; starlark-ts-mode.el --- Major mode for Starlark using Tree-sitter -*- lexical-binding: t; -*-

;; Author: Martin Baillie <martin@baillie.id>
;; URL: https://github.com/martinbaillie/starlark-ts-mode
;; Version: 0.1
;; Keywords: languages, starlark, bazel
;; Package-Requires: ((emacs "29.0"))

;; This file is not part of GNU Emacs, but is released under the same license.

;;; Commentary:

;; A major mode for editing Starlark files using Tree-sitter.

;; To use this mode, you will need Emacs 29 or newer, compiled with Tree-sitter support. You also
;; need the Starlark grammar installed. If you use the in-built `treesit-install-language-grammar`,
;; you can install it imperatively like this:
;;
;;   (add-to-list 'treesit-language-source-alist
;;                '(starlark "https://github.com/tree-sitter-grammars/tree-sitter-starlark.git"
;;                           nil
;;                           nil
;;                           nil))
;;
;;   M-x treesit-install-language-grammar RET starlark RET
;;
;; After that, just open a `.star` file and it should automatically use `starlark-ts-mode`.

;;; Code:
(require 'treesit)
(require 'python)

(unless (treesit-available-p)
  (error "`starlark-ts-mode` requires Emacs to be built with Tree-sitter support"))

(eval-when-compile
  (require 'rx))

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-search-forward "treesit.c")

(defgroup starlark-ts nil
  "Major mode for editing Starlark files."
  :prefix "starlark-ts-"
  :group 'languages)

(defvar starlark-ts-mode-font-lock-feature-list
  '((comment keyword)                                  ; Level 1 - Essential syntax.
     (string number builtin type constant)             ; Level 2 - Basic types and constants.
     (variable function definition delimiter starlark) ; Level 3 - Variables and functions.
     (operator error docstring interpolation bazel))   ; Level 4 - The rest.

  "Available treesit font-lock features for Starlark, grouped by highlight level.

Level 1 covers the minimum needed for readable code:
- comments
- keywords (if, def, for, etc.)

Level 2 adds basic types and values:
- strings and string escapes
- numbers
- built-in functions and types
- constants and built-in constants

Level 3 adds code structure elements:
- variable names
- function names and calls
- function definitions
- delimiters and punctuation
- Starlark-specific features (struct fields, etc.)

Level 4 adds everything else:
- operators
- error highlighting
- docstring and interpolation
- Bazel-specific features")

(defvar starlark-ts-mode-font-lock-rules
  (treesit-font-lock-rules
    :language 'starlark
    :feature 'builtin
    '(;; Built-in functions from Starlark spec.
       ((identifier) @font-lock-builtin-face
         (:match "^\\(abs\\|all\\|any\\|bool\\|dict\\|dir\\|enumerate\\|fail\\|filter\\|float\\|getattr\\|hasattr\\|hash\\|int\\|len\\|list\\|max\\|min\\|print\\|range\\|repr\\|set\\|sorted\\|str\\|tuple\\|type\\|zip\\|load\\)$" @font-lock-builtin-face)))

    :language 'starlark
    :feature 'type
    '(;; Types starting with capital letter (convention).
       ((identifier) @font-lock-type-face
         (:match "^[A-Z].*[a-z]" @font-lock-type-face))

       ;; Built-in types from Starlark spec.
       ((identifier) @font-lock-type-face
         (:match
           "^\\(bool\\|int\\|float\\|list\\|tuple\\|str\\|dict\\|set\\)$" @font-lock-type-face))

       ((type) (identifier) @font-lock-type-face)
       ((type) (subscript) (identifier) @font-lock-type-face))

    :language 'starlark
    :feature 'constant
    '(;; Constants in UPPER_CASE (convention).
       ((identifier) @font-lock-constant-face
         (:match "^[A-Z][A-Z_0-9]*$" @font-lock-constant-face))
       ;; Boolean and None constants.
       ((true) @font-lock-constant-face)
       ((false) @font-lock-constant-face)
       ((none) @font-lock-constant-face))

    :language 'starlark
    :feature 'definition
    '((function_definition
        name: (identifier) @font-lock-function-name-face))

    :language 'starlark
    :feature 'number
    '((integer) @font-lock-number-face
       (float) @font-lock-number-face)

    :language 'starlark
    :feature 'string
    '((string) @font-lock-string-face
       (escape_sequence) @font-lock-escape-face
       (escape_interpolation) @font-lock-escape-face)

    :language 'starlark
    :feature 'comment
    '((comment) @font-lock-comment-face)

    :language 'starlark
    :feature 'keyword
    '(["and" "in" "not" "or" "del"  ; Operators.
        "def" "lambda"              ; Function.
        "pass"                      ; General.
        "return"
        "if" "elif" "else"          ; Conditionals.
        "for" "break" "continue"    ; Loops.
        "as"                        ; Imports.
        ] @font-lock-keyword-face)

    :language 'starlark
    :feature 'operator
    '([
        "+" "-" "*" "/" "%" "**" "//" "&" "|" "^" "~" "<<" ">>" "<"
        ">" "<=" ">=" "==" "!=" "-=" "+=" "*=" "/=" "//=" "%=" "@="
        "&=" "|=" "^=" ">>=" "<<=" "**=" "->" ":=" "<>"
        ] @font-lock-operator-face)

    :language 'starlark
    :feature 'delimiter
    '(["," "." ":" ";"] @font-lock-delimiter-face
       ["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)

    :language 'starlark
    :feature 'error
    '((ERROR) @font-lock-warning-face)

    :language 'starlark
    :feature 'interpolation
    '(((interpolation) @font-lock-preprocessor-face)
       ((format_specifier) @font-lock-regexp-grouping-construct))

    ;; Starlark-specific features.
    :language 'starlark
    :feature 'starlark
    '(;; Method calls.
       ((call
          function: (attribute
                      attribute: (identifier) @font-lock-function-call-face)))

       ;; Constructor calls.
       ((call
          function: (identifier) @font-lock-type-face)
         (:match "^[A-Z]" @font-lock-type-face))

       ((call
          function: (attribute
                      attribute: (identifier) @font-lock-type-face))
         (:match "^[A-Z]" @font-lock-type-face)))

    :language 'starlark
    :feature 'bazel
    '(;; Bazel-specific built-ins.
       ((identifier) @font-lock-builtin-face
         (:match "^\\(select\\|glob\\|exports_files\\|package\\|workspace\\|repository_name\\)$"
           @font-lock-builtin-face))
       ;; Common Bazel attributes.
       ((keyword_argument
          name: (identifier) @font-lock-property-face)
         (:match "^\\(name\\|srcs\\|deps\\|visibility\\|licenses\\|tags\\)$"
           @font-lock-property-face)))

    :language 'starlark
    :feature 'variable
    '((identifier) @font-lock-variable-name-face)) ; Match remaining identifiers as variables.

  "Tree-sitter font-lock rules for Starlark mode.")

(defun starlark-ts--font-lock ()
  "Setup treesit font locking variables for Starlark mode."
  (setq-local treesit-font-lock-feature-list starlark-ts-mode-font-lock-feature-list)
  (setq-local treesit-font-lock-settings starlark-ts-mode-font-lock-rules))

(defvar starlark-ts--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "< b" table)
    (modify-syntax-entry ?\n "> b" table)
    table)
  "Syntax table for `starlark-ts-mode'.")

(defvar starlark-ts-beginning-of-block-regexp
  (rx line-start (* space)
    (or "def" "if" "elif" "else" "for")
    (+ nonl) ":" (* space)
    (or line-end ?# ?\" ?\'))
  "Regexp matching the start of a Starlark block.")

(defun starlark-ts--defun-name (node)
  "Return the defun name of NODE.
Return nil if there is no name or if NODE is not a defun node."
  (pcase (treesit-node-type node)
    ("function_definition"
     (treesit-node-text (treesit-node-child-by-field-name node "name") t))))

(defun starlark-ts-forward-sexp (&optional arg)
  "Move forward across one balanced expression in Starlark.
With ARG, do it that many times. Negative arg -N means move
backward N balanced expressions."
  (interactive "^p")
  (or arg (setq arg 1))
  (if (< arg 0)
    (starlark-ts-backward-sexp (- arg))
    (dotimes (_ arg)
      (let* ((node (treesit-node-at (point)))
              (block-node (treesit-parent-until
                            node
                            (lambda (n)
                              (member (treesit-node-type n)
                                '("if_statement" "for_statement"
                                   "function_definition"))))))
        (if (and block-node
              (>= (treesit-node-start block-node) (point)))
          (goto-char (treesit-node-end block-node))
          (treesit-search-forward-goto
            node
            (lambda (n)
              (member (treesit-node-type n)
                '("if_statement" "for_statement" "function_definition")))
            t))))))

(defun starlark-ts-backward-sexp (&optional arg)
  "Move backward across one balanced expression in Starlark.
With ARG, do it that many times. Negative arg -N means move
forward N balanced expressions."
  (interactive "^p")
  (or arg (setq arg 1))
  (if (< arg 0)
    (starlark-ts-forward-sexp (- arg))
    (dotimes (_ arg)
      (let* ((node (treesit-node-at (point)))
              (block-node (treesit-parent-until
                            node
                            (lambda (n)
                              (member (treesit-node-type n)
                                '("if_statement" "for_statement"
                                   "function_definition"))))))
        (if block-node
          (goto-char (treesit-node-start block-node))
          (when-let ((prev-node (treesit-search-forward
                                  node
                                  (lambda (n)
                                    (member (treesit-node-type n)
                                      '("if_statement" "for_statement"
                                         "function_definition")))
                                  t
                                  'backward)))
            (goto-char (treesit-node-start prev-node))))))))

(defcustom starlark-ts-indent-offset 4
  "Number of spaces for each indentation step in `starlark-ts-mode'."
  :type 'integer
  :safe 'integerp
  :group 'starlark-ts)

(defvar starlark-ts-indent-rules
  `((starlark . (;; Zero indentation for module level.
                  ((node-is "module") parent-bol 0)
                  ;; Function definitions and their blocks
                  ((node-is "function_definition") parent-bol 0)
                  ;; Match block nodes that are part of a function
                  ((and (node-is "block")
                     (parent-is "function_definition"))
                    parent-bol starlark-ts-indent-offset)
                  ;; Handle content inside the block
                  ((parent-is "block")
                    parent-bol starlark-ts-indent-offset)

                  ;; Control flow blocks.
                  ((node-is "if_statement") parent-bol 0)
                  ((node-is "for_statement") parent-bol 0)
                  ((parent-is "if_statement") parent-bol starlark-ts-indent-offset)
                  ((parent-is "for_statement") parent-bol starlark-ts-indent-offset)

                  ;; Else/elif clauses align with if.
                  ((node-is "else_clause") parent-bol 0)
                  ((node-is "elif_clause") parent-bol 0)
                  ((parent-is "else_clause") parent-bol starlark-ts-indent-offset)
                  ((parent-is "elif_clause") parent-bol starlark-ts-indent-offset)

                  ;; Handle multi-line expressions.
                  ((parent-is "binary_operator") parent-bol starlark-ts-indent-offset)
                  ((parent-is "assignment") parent-bol starlark-ts-indent-offset)

                  ;; List/Dict/Set comprehensions.
                  ((node-is "list_comp") parent-bol starlark-ts-indent-offset)
                  ((node-is "dict_comp") parent-bol starlark-ts-indent-offset)
                  ((node-is "set_comp") parent-bol starlark-ts-indent-offset)

                  ;; Handle collection literals and their contents.
                  ((node-is "list") parent-bol starlark-ts-indent-offset)
                  ((node-is "tuple") parent-bol starlark-ts-indent-offset)
                  ((node-is "dictionary") parent-bol starlark-ts-indent-offset)
                  ((node-is "set") parent-bol starlark-ts-indent-offset)

                  ;; Closing brackets/braces go back to parent indentation.
                  ((node-is "]") parent-bol 0)
                  ((node-is "}") parent-bol 0)
                  ((node-is ")") parent-bol 0)

                  ;; Function calls with arguments.
                  ((parent-is "call") parent-bol starlark-ts-indent-offset)
                  ((parent-is "argument_list") parent-bol starlark-ts-indent-offset)

                  ;; Line continuations.
                  ((parent-is "parenthesized_expression") parent-bol starlark-ts-indent-offset)

                  ;; Lambda expressions.
                  ((node-is "lambda") parent-bol starlark-ts-indent-offset)
                  ((parent-is "lambda") parent-bol starlark-ts-indent-offset)

                  ;; Bazel-specific rules.
                  ((node-is "keyword_argument") parent-bol starlark-ts-indent-offset)

                  ;; Default catch-all.
                  (no-node parent-bol 0))))
  "Tree-sitter indent rules for Starlark.")

;;;###autoload
(define-derived-mode starlark-ts-mode prog-mode "Starlark"
  "Major mode for Starlark using Tree-sitter.

\\{starlark-ts-mode-map}"
  :syntax-table starlark-ts--syntax-table

  (when (treesit-ready-p 'starlark)
    (treesit-parser-create 'starlark)

    ;; Font locking.
    (starlark-ts--font-lock)

    ;; Imenu.
    (setq-local treesit-simple-imenu-settings `((nil "\\`function_definition\\'" nil nil)))

    ;; Navigation.
    (setq-local treesit-defun-type-regexp (rx (or "function_definition")))
    (setq-local treesit-defun-name-function #'starlark-ts--defun-name)
    (setq-local forward-sexp-function #'starlark-ts-forward-sexp)

    ;; Hide-show.
    (add-to-list 'hs-special-modes-alist
      `(starlark-ts-mode
         ,starlark-ts-beginning-of-block-regexp
         ""    ; Empty string so it doesn't default to "\\s)".
         "#"
         starlark-ts-forward-sexp
         nil))

    ;; Comments.
    (setq-local comment-start "# ")
    (setq-local comment-start-skip "#+\\s-*")

    ;; Indentation.
    (setq-local electric-indent-chars (append "{}():;," electric-indent-chars))

    ;; These are a WIP. For now I'm borrowing the Python indent function (not based on Tree-sitter)
    ;; whilst I write tests and have the time to crank out Tree-sitter rules.
    ;;
    ;; (setq-local treesit-simple-indent-rules starlark-ts-indent-rules)
    (setq-local indent-line-function #'python-indent-line-function)

    (treesit-major-mode-setup)))

;;;###autoload

(when (treesit-ready-p 'starlark)
  (add-to-list 'auto-mode-alist '("\\.star\\'" . starlark-ts-mode)))

(provide 'starlark-ts-mode)
;;; starlark-ts-mode.el ends here
