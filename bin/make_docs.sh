#!/usr/bin/env bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

echo "Generating documentation..."
cd "$DIR"/..

rm htmldocs/index.html || true
rm -r htmldocs/lockfreequeues* || true

nim doc --project \
  --index:on \
  --out:htmldocs \
  --threads:on \
  --git.url:https://github.com/elijahr/lockfreequeues \
  --git.commit:master \
  src/lockfreequeues.nim

nim buildIndex \
  --out:htmldocs/index.html \
  --threads:on \
  --git.url:https://github.com/elijahr/lockfreequeues \
  --git.commit:master \
  htmldocs

# Remove title, since it throws off the simple text substitutions below
find htmldocs -regex '^.*\.html$' -exec sed -i '' "s/ title=\"[^\"\]*\"/ /g" {} \;
# Reformat comment indentation
find htmldocs -regex '^.*\.html$' -exec sed -i '' "s/ \{1,\}\(<span class=\"Comment\">\)/\1/g" {} \;
# Hack to substitute links in comments
# shellcheck disable=SC2016
find htmldocs -regex '^.*\.html$' -exec sed -i '' 's/`\([^ ]\{1,\}\) &lt;\(.*\)&gt;`_/<a href="\2">\1<\/a>/g' {} \;
# Make backtic items in comments bold
# shellcheck disable=SC2016
find htmldocs -regex '^.*\.html$' -exec sed -i '' 's/`\([^`]*\)`/<b>\1<\/b>/g' {} \;

echo
echo "* Docs written to $(pwd)/htmldocs"
