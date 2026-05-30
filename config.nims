# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Sibling-source path-override removed in v5.0.0 — both deps now
# published per tag commits 86f55fa (typestates v0.12.0) +
# d6701c0 (debra v0.9.0). The override was a pre-publish
# integration scaffold; per its original removal-trigger comment
# ("Remove when nim-debra@0.8.0 + typestates >= 0.10.0 are
# published"), both conditions are now met and exceeded. nimble
# resolves both deps from the registry against the pins in
# lockfreequeues.nimble (typestates >= 0.12.0, debra >= 0.9.0).
