#!/bin/bash
# Deploy dist/ (the agentos-dist download mirror) to Girder. Girder refuses build contexts that
# contain symlinks, and this repo has some (the CLI wrappers in package/), so push a commit whose
# tree is only dist/ (the Dockerfile's dist/... paths stay valid), on top of what Girder has.
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=${GIRDER_REMOTE:-ssh://git@100.112.17.24:2222/agentos-dist.git}
src=$(git rev-parse --short HEAD)
tree=$(printf '040000 tree %s\tdist\n' "$(git rev-parse HEAD:dist)" | git mktree)
parent=$(git ls-remote "$REMOTE" refs/heads/main | cut -f1)
[ -z "$parent" ] || git fetch -q "$REMOTE" main
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "agentos-dist from agentos $src")
git push "$REMOTE" "$commit:refs/heads/main"
