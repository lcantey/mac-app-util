#!/usr/bin/env sbcl --script

;; Copyright © 2023  Hraban Luyat
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, version 3 of the License.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

(require "asdf")
(require "uiop")

(asdf:load-system "alexandria")
(asdf:load-system "cl-interpol")
(asdf:load-system "cl-json")
(asdf:load-system "inferior-shell")
(asdf:load-system "str")
(asdf:load-system "trivia")

(defpackage #:script
  (:use #:cl)
  (:local-nicknames (#:alex #:alexandria)
                    (#:sh #:inferior-shell)))

(in-package #:script)

(named-readtables:in-readtable :interpol-syntax)

(defvar *plutil* "/usr/bin/plutil")

(defparameter *copyable-app-props*
  '("CFBundleDevelopmentRegion"
    "CFBundleDocumentTypes"
    "CFBundleGetInfoString"
    "CFBundleIconFile"
    "CFBundleIdentifier"
    "CFBundleInfoDictionaryVersion"
    "CFBundleName"
    "CFBundleShortVersionString"
    "CFBundleURLTypes"
    "NSAppleEventsUsageDescription"
    "NSAppleScriptEnabled"
    "NSDesktopFolderUsageDescription"
    "NSDocumentsFolderUsageDescription"
    "NSDownloadsFolderUsageDescription"
    "NSPrincipalClass"
    "NSRemovableVolumesUsageDescription"
    "NSServices"
    "UTExportedTypeDeclarations")
  "Based on a hunch, nothing scientific.")

(defun rootp ()
  "Am I the root user?"
  (equal "root" (uiop:getenv "USER")))

(defun sh (&rest args)
  ;; This is my personal convention; set DEBUGSH to anything to effect set -x
  (apply #'sh:run `(,@args :show ,(uiop:getenv "DEBUGSH"))))

(defun sh/ss (&rest args)
  (apply #'sh `(,@args :output (:string :stripped t))))

(defgeneric rm-rf (p))

(defmethod rm-rf ((p string))
  (rm-rf (uiop:parse-native-namestring p :ensure-directory t)))

(defmethod rm-rf ((p pathname))
  (uiop:delete-directory-tree
   (uiop:ensure-directory-pathname p)
   :validate t
   :if-does-not-exist :ignore))

(defmacro with-temp-dir ((dname) &body body)
  `(let ((,dname (uiop:ensure-directory-pathname (sh/ss '(mktemp #\d)))))
     (unwind-protect (progn ,@body)
       (rm-rf ,dname))))

(defun list-of-strings-p (l)
  (and (consp l) (every #'stringp l)))

(deftype list-of-strings ()
  `(satisfies list-of-strings-p))


;;; mktrampoline

(defun copy-paths (from to paths)
  (declare (type list-of-strings paths))
  (let ((keys (cl-json:encode-json-to-string *copyable-app-props*))
        ;; For an object, keep only those keys from list “keys”
        (jqfilter "to_entries |[.[]| select(.key as $item| $keys | index($item) >= 0) ] | from_entries"))
    (with-temp-dir (d)
      (uiop:with-current-directory (d)
        (uiop:copy-file from "orig")
        (uiop:copy-file to "bare-wrapper")
        (sh `(sh:and (,*plutil* -convert json -- orig)
                     (,*plutil* -convert json -- bare-wrapper)
                     (jq :argjson keys ,keys ,jqfilter (< orig) (> filtered))
                     (sh:pipe (cat bare-wrapper filtered)
                              (jq #\s add (> final)))
                     (,*plutil* -convert xml1 -- final)))
        (uiop:copy-file "final" to)))))

(defun resources (app)
  #?"${app}/Contents/Resources/")

(defun infoplist (app)
  #?"${app}/Contents/Info.plist")

(defun sync-icons (from to)
  "Remove all icons from TO apps resources, and copy all icons FROM to it"
  (destructuring-bind (from-cnts to-cnts) (mapcar #'resources (list from to))
    ;; 🤷
    (sh `(sh:and
          (find ,to-cnts -name "*.icns" -delete)
          (rsync :include "*.icns" :exclude "*" :recursive ,from-cnts ,to-cnts)))))

(defgeneric mktrampoline (from to))

(defmethod mktrampoline ((app string) (trampoline string))
  (mktrampoline (to-abs-dir app) (to-abs-dir trampoline)))

(defmethod mktrampoline ((app pathname) (trampoline pathname))
  (uiop:ensure-pathname app :ensure-absolute t)
  (uiop:ensure-pathname trampoline :ensure-absolute t)
  (let ((cmd (format NIL "do shell script \"open '~A'\"" app)))
    (rm-rf trampoline)
    (sh `("/usr/bin/osacompile" #\o ,trampoline #\e ,cmd))
    (sync-icons app trampoline)
    (copy-paths (infoplist app) (infoplist trampoline) *copyable-app-props*)))


;;; sync-dock

(defun realpath (f)
  "Transform a string, optionally relative, into a an absolute path.

Also resolves symlinks, if relevant.
"
  (uiop:ensure-pathname f
                        :want-pathname t
                        :ensure-absolute t
                        :defaults (uiop:getcwd)
                        :want-existing t
                        :resolve-symlinks t))

(defun sync-dock (apps)
  "Every element must be a pathname to a real directory, not a symlink"
  ;; dockutil doesn't like acting under sudo and will fall back to the original
  ;; user. That’s sensible when using dockutil as an end user, but because this
  ;; tool /wraps/ it, it leads to unexpected results e.g. when used in a home
  ;; manager activation script. Just stick to the dumb default: act as the user
  ;; that invokes you, no special sudo tricks.
  (setf (uiop:getenv "SUDO_USER") "")
  ;; Filtering for /nix/store is not technically part of the docs but let’s be
  ;; conservative for now.
  (let* ((dockutil-args (when (rootp)
                          ;; When run as root, it’s probably intended to affect every
                          ;; actual end-user’s dock--not the root.
                          '(:allhomes)))
         (persistents (sh `(sh:pipe (dockutil ,@dockutil-args #\L)
                            (grep "file:///nix/store")
                            ;; Whatever, this works.
                            (grep "persistentApps")
                            ;; I feel like using the bundle ID would be
                            ;; cleaner (org.gnu.Emacs etc) but dockutil only
                            ;; works reliably when I use the “bundle name”,
                            ;; which is just the file’s basename without
                            ;; extension. Ok.
                            (cut #\f 1))
                          :output :lines)))
    (dolist (existing persistents)
      (alex:when-let ((app (find existing apps :test #'equal :key #'pathname-name)))
        ;; I was passed an app with the same name as an existing persistent dock
        ;; item.  Yes this restarts after every item but I don’t know how to
        ;; only restart exactly once.
        (sh `(dockutil
              ,@dockutil-args
              :add ,(realpath app)
              :replacing ,existing))))))


;;; sync-trampolines

(defun to-abs-dir (d)
  "Transform d into an absolute directory pathname."
  (uiop:ensure-pathname d
                        :ensure-absolute t
                        :defaults (uiop:getcwd)
                        :ensure-directory t))

(defun directory-name (d)
  ;; Weird lispism
  (first (last (pathname-directory d))))

(defun sync-trampolines (&rest args)
  (destructuring-bind (from to) (mapcar #'to-abs-dir args)
    (rm-rf to)
    (ensure-directories-exist to)
    (let ((apps (directory (merge-pathnames #p"*.app" from))))
      (dolist (app apps)
        (mktrampoline app (merge-pathnames (directory-name app) to)))
      (sync-dock apps))))


;;; CLI

(defun print-usage ()
  (format T "Usage:

    mac-app-util mktrampoline FROM.app TO.app
    mac-app-util sync-dock Foo.app Bar.app ...

mktrampline creates a “trampoline” application launcher that immediately
launches another application.

sync-dock updates persistent items in your dock if any of the given apps has the
same name. This can be used to programmatically keep pinned items in your dock
up to date with potential new versions of an app outside of the /Applications
directory, without having to check which one is pinned etc.
"))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (if (intersection args '("-h" "--help") :test #'equal)
        (progn
          (print-usage)
          (uiop:quit 0))
        (trivia:match args
          ((list "mktrampoline" from to)
           (mktrampoline from to))
          ((list* "sync-dock" apps)
           (sync-dock apps))
          ((list "sync-trampolines" from to)
           (sync-trampolines from to))
          (_
           (print-usage)
           (uiop:quit 1))))))

(main)
