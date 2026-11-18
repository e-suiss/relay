#!/usr/bin/env bash
# X-53
set -euo pipefail

: "${REPO:?}" "${BRANCH:?}" "${MESSAGE:?}" "${GITHUB_SHA:?}"

git -c user.name=sdk-regenerate -c user.email=sdk-regenerate@users.noreply.github.com \
  commit -q -m "$MESSAGE"

if gh api "repos/$REPO/git/ref/heads/$BRANCH" > /dev/null 2>&1; then
  exists=true
  git fetch -q origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  while read -r sha; do
    [ -n "$sha" ] || continue
    if [ "$(git log -1 --format=%s "$sha")" = "$MESSAGE" ]; then
      continue
    fi
    if ! git -c user.name=sdk-regenerate -c user.email=sdk-regenerate@users.noreply.github.com \
      cherry-pick --allow-empty --keep-redundant-commits "$sha" > /dev/null 2>&1; then
      git cherry-pick --abort || true
      echo "::warning::$BRANCH has a commit ($sha) that does not apply to the fresh regeneration; the branch is left unchanged" >&2
      echo "left"
      exit 0
    fi
  done < <(git rev-list --reverse --no-merges "origin/$BRANCH" --not "$GITHUB_SHA")
else
  exists=false
fi

api_commit() {
  local commit=$1 parent=$2 base_tree entries entry status path mode blob tree
  base_tree=$(gh api "repos/$REPO/git/commits/$parent" --jq .tree.sha)
  entries='[]'
  while IFS=$'\t' read -r status path; do
    if [ "$status" = "D" ]; then
      entry=$(jq -n --arg path "$path" '{path: $path, mode: "100644", type: "blob", sha: null}')
    else
      mode=$(git ls-tree "$commit" -- "$path" | cut -d' ' -f1)
      blob=$(git show "$commit:$path" | base64 -w0 | jq -Rs '{content: ., encoding: "base64"}' |
        gh api "repos/$REPO/git/blobs" --input - --jq .sha)
      entry=$(jq -n --arg path "$path" --arg mode "$mode" --arg sha "$blob" \
        '{path: $path, mode: $mode, type: "blob", sha: $sha}')
    fi
    entries=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$entries")
  done < <(git diff-tree --no-commit-id --name-status --no-renames -r "$commit^" "$commit")
  tree=$(jq -n --arg base "$base_tree" --argjson tree "$entries" '{base_tree: $base, tree: $tree}' |
    gh api "repos/$REPO/git/trees" --input - --jq .sha)
  jq -n --arg message "$(git log -1 --format=%B "$commit")" --arg tree "$tree" --arg parent "$parent" \
    --arg name "$(git log -1 --format=%an "$commit")" --arg email "$(git log -1 --format=%ae "$commit")" \
    --arg date "$(git log -1 --format=%aI "$commit")" \
    '{message: $message, tree: $tree, parents: [$parent], author: {name: $name, email: $email, date: $date}}' |
    gh api "repos/$REPO/git/commits" --input - --jq .sha
}

head="$GITHUB_SHA"
for commit in $(git rev-list --reverse "$GITHUB_SHA..HEAD"); do
  head=$(api_commit "$commit" "$head")
done

if [ "$exists" = true ]; then
  gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" -f sha="$head" -F force=true > /dev/null
else
  gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$head" > /dev/null
fi
echo "updated"
