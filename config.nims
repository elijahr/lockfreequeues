# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Integration-wave path-override: pin debra@0.8.0 and
# typestates >= 0.10.0 via worktree --path: directives. Placed after
# include "nimble.paths" so dedup (Nim collapses repeat --path:
# entries) does not suppress these — at the time config.nims runs,
# nim.cfg has NOT declared these paths, so the switch() calls add
# them fresh and they become most-recently-added in Nim's search
# order, winning over any registry-stale entries.
# Remove when nim-debra@0.8.0 + typestates >= 0.10.0 are published.
import std/os
# Guard sibling-source overrides with `dirExists`: on a fresh clone
# without the v5.0.0-wave sibling worktrees the path entries would point
# at non-existent directories, causing spurious lookup churn. When the
# siblings ARE present the absolute paths are added (most-recently-added
# wins per Nim's search order, preserving the priority semantics);
# otherwise we fall back cleanly to the registry-installed nimble deps.
for sibling in ["../nim-debra/src", "../nim-typestates/src"]:
  let abs = thisDir() / sibling
  if dirExists(abs):
    switch("path", abs)
