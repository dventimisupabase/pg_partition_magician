#!/usr/bin/env bash
# Build the review tree for an adversarial review pass (docs/adversarial-review.md).
#
# The review tree is the pinned commit as ONE history-less commit in a fresh repository with no remote,
# so a finder cannot read the seeds off a diff or fetch the pristine tree to compare. The mutation
# catalogue is removed from it (finders may not read bench/mutations/; the coordinator plants seeds from
# the pristine checkout's copy), and a stub says so, so that a finder who looks knows it is deliberate.
#
# Usage: build_review_tree.sh <pinned-sha> <out-dir>
#   <out-dir> must not exist. Prints the tree's single commit on success.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <pinned-sha> <out-dir>" >&2
  exit 2
fi
sha="$1"; out="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -e "$out" ]; then
  echo "build_review_tree: $out already exists; refusing to overwrite a tree a pass may be using" >&2
  exit 3
fi
full="$(git -C "$root" rev-parse --verify "${sha}^{commit}")"

mkdir -p "$out"
git -C "$root" archive --format=tar "$full" | tar -x -C "$out"

# Structural blindness: the catalogue of known defects is what the seeds come from.
rm -rf "$out/bench/mutations"
mkdir -p "$out/bench/mutations"
cat > "$out/bench/mutations/REMOVED.md" <<'STUB'
# Removed from the review tree

`bench/mutations/` is not part of a review tree (see `docs/adversarial-review.md`, "Seeding"): the
catalogue is where the pass's seeds come from, so a finder may not read it. `./test.sh discriminate`
therefore does not run here. Review the guards in `bench/` on their own terms; whether each has a
discriminating mutation is checked by the verifier against the pristine commit.
STUB

# One commit, no history, no remote. The author is fixed so the tree is reproducible byte for byte.
git -C "$out" init -q
git -C "$out" -c user.name=review -c user.email=review@localhost add -A
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$out" -c user.name=review -c user.email=review@localhost commit -q -m 'review tree'
git -C "$out" rev-parse HEAD
