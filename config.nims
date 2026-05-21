# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Phase 3.3 integration-wave path-override: pin debra@0.8.0 and
# typestates@0.9.2 via worktree --path: directives. Placed after
# include "nimble.paths" so dedup (Nim collapses repeat --path:
# entries) does not suppress these — at the time config.nims runs,
# nim.cfg has NOT declared these paths, so the switch() calls add
# them fresh and they become most-recently-added in Nim's search
# order, winning over any registry-stale entries.
# Remove when nim-debra@0.8.0 + typestates@0.9.2 are published.
import std/os
switch("path", thisDir() / "../nim-debra/src")
switch("path", thisDir() / "../nim-typestates/src")
