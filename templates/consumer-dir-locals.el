;;; Directory Local Variables            -*- no-byte-compile: t -*-
;;
;; Installed at the consumer's root by `.claude/cerebro/scripts/sync-symlinks.sh', as a symlink
;; back to this file, so a submodule bump carries any change to it. The sync never overwrites a
;; `.dir-locals.el' the project already has - Emacs allows exactly one per directory, and which
;; settings a project wants is the project's to say.
;;
;; What it buys: `M-x cerebro' - the fleet view - the moment any file of the project is open, for
;; every contributor, without one of them editing their init to get it.
;;
;; Two things worth knowing:
;;
;;   - Emacs asks each user once whether the `eval' form below may run, because a directory-local
;;     `eval' is arbitrary code. Answer `!' to record it in `safe-local-variable-values'.
;;   - Nothing is loaded here. `autoload' registers the command; cerebro.el is read on the first
;;     `M-x cerebro' and not before.
;;
;; The mount is located rather than assumed relative to this file: a `.dir-locals.el' is read for
;; every buffer under the root, so `default-directory' is that buffer's directory and may be many
;; levels down. `locate-dominating-file' climbs from there to whichever ancestor actually holds
;; the submodule, which is what makes the path independent of where the project is checked out.
;; A project that mounts cerebro somewhere other than `.claude/cerebro' edits the two strings
;; below - and, having its own copy, is no longer syncing this one.

((nil . ((eval . (let ((cerebro-mount (locate-dominating-file default-directory
                                                              ".claude/cerebro/emacs")))
                   (when cerebro-mount
                     (add-to-list 'load-path
                                  (expand-file-name ".claude/cerebro/emacs" cerebro-mount))
                     (autoload 'cerebro "cerebro"
                       "List the Cerebro agent fleet." t)))))))
