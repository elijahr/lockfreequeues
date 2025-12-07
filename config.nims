# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Local development: add path to nim-debra source
switch("path", "../nim-debra/src")
