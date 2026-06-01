# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# CI sibling-source path-override (debug-mode visible). CI doesn't
# run `nimble setup` (skip-rationale in `.github/workflows/build.yml`),
# instead clones nim-debra + nim-typestates as siblings and relies
# on these path overrides.
#
# Use unconditional `--path:` — nim ignores entries pointing at
# non-existent dirs. Local dev users without sibling clones see no
# harm; CI with siblings cloned picks them up.
switch("path", thisDir() & "/../nim-typestates/src")
switch("path", thisDir() & "/../nim-debra")
