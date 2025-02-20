#!/usr/bin/env bash

set -euo pipefail

tmp=$(mktemp -d)
cd "$tmp"
trap 'rm -rf "$tmp"' exit

bodyForCommit() {
  local index=$1
  local commit=$2
  if (( index == 0 )); then
    subject=$(git -C nixfmt show -s --format=%s "$commit")
    url="$nixfmtUrl"/commit/"$commit"
    echo -e "base: $subject\n\nFormat using the base commit from nixfmt PR $nixfmtPrNumber: $url"
  else
    commit=$(git -C nixfmt show -s --pretty=%s "$commit")
    subject=$(git -C nixfmt show -s --format=%s "$commit")
    url="$nixfmtUrl"/pull/"$nixfmtPrNumber"/commits/"$commit"
    echo -e "$index: $subject\n\nFormat using commit number $index from nixfmt PR $nixfmtPrNumber: $url"
  fi
}

step() {
  echo -e "\e[34m$1\e[0m"
}

isLinear() {
  local repo=$1
  local revs=$2
  for mergeCommit in $(git 2>/dev/null -C "$repo" log --pretty=format:%H --min-parents=2 "$revs"); do
    return 1
  done
}


nixfmtUrl=$1
nixfmtPrNumber=$2
nixpkgsMirrorUrl=$3

nixpkgsUpstreamUrl=https://github.com/NixOS/nixpkgs
nixpkgsMirrorBranch=nixfmt-$nixfmtPrNumber

step "Fetching nixfmt pull request and creating a branch for the head commit"
git init nixfmt
git -C nixfmt fetch "$nixfmtUrl" "refs/pull/$nixfmtPrNumber/merge"
nixfmtBaseCommit=$(git -C nixfmt rev-parse FETCH_HEAD^1)
nixfmtHeadCommit=$(git -C nixfmt rev-parse FETCH_HEAD^2)
git -C nixfmt switch -c main "$nixfmtHeadCommit"

step "Linearising nixfmt history after the base commit"
# https://stackoverflow.com/a/17994534
FILTER_BRANCH_SQUELCH_WARNING=1 git -C nixfmt filter-branch --parent-filter 'cut -f 2,3 -d " "' --msg-filter 'echo $GIT_COMMIT' "$nixfmtBaseCommit"..main

nixfmtCommitCount=$(git -C nixfmt rev-list --count "$nixfmtBaseCommit"..main)
if (( nixfmtCommitCount == 0 )); then
  step "No commits, deleting the nixpkgs branch $nixpkgsPushBranch if it exists"
  # git push requires a repository to work at all, _any_ repository
  git init -q trash
  git -C trash push "$nixpkgsPushRepository" :refs/heads/"$nixpkgsPushBranch"
  rm -rf trash
  exit 0
else
  echo "There are $nixfmtCommitCount linearised commits"
fi

commitsToMirror=("$nixfmtBaseCommit")
readarray -t -O 1 commitsToMirror < <(git -C nixfmt rev-list --reverse "$nixfmtBaseCommit"..main)

step "Fetching upstream Nixpkgs commit history"
git init --bare nixpkgs.git

git -C nixpkgs.git remote add upstream "$nixpkgsUpstreamUrl"
git -C nixpkgs.git config remote.upstream.promisor true
git -C nixpkgs.git config remote.upstream.partialclonefilter tree:0

git -C nixpkgs.git fetch --no-tags upstream HEAD:master

step "Finding the last Nixpkgs commit before the first commit on nixfmt's branch"
nixfmtFirstCommit=${commitsToMirror[1]}
# Commit date, not author date, not sure what's better
nixfmtFirstCommitDateEpoch=$(git -C nixfmt log -1 --format=%ct "$nixfmtFirstCommit")
nixfmtFirstCommitDateHuman=$(git -C nixfmt log -1 --format=%ci "$nixfmtFirstCommit")
echo "The first nixfmt commit is $nixfmtFirstCommit on $nixfmtFirstCommitDateHuman"

nixpkgsBaseCommit=$(git -C nixpkgs.git rev-list -1 master --before="$nixfmtFirstCommitDateEpoch")
nixpkgsBaseCommitDateHuman=$(git -C nixpkgs.git log -1 --format=%ci "$nixpkgsBaseCommit")

echo "The last Nixpkgs commit before then is $nixpkgsBaseCommit on $nixpkgsBaseCommitDateHuman, which will be used as the Nixpkgs base commit"

step "Fetching mirror Nixpkgs commit history in branch $nixpkgsMirrorBranch if it exists"
git -C nixpkgs.git remote add mirror "$nixpkgsMirrorUrl"
git -C nixpkgs.git config remote.mirror.promisor true
git -C nixpkgs.git config remote.mirror.partialclonefilter tree:0

# After this:
# - $startingCommit should be the nixpkgs commit that the branch should be reset to
# - $extraCommits should be the number of commits already processed
if ! git -C nixpkgs.git fetch --no-tags mirror "$nixpkgsMirrorBranch":mirrorBranch; then
  echo "There is not"
  startingCommit=$nixpkgsBaseCommit
  extraCommits=0
else
  echo "There is, it points to $(git -C nixpkgs.git rev-parse mirrorBranch)"
  step "Checking to which extent work from the existing branch can be reused"
  if [[ -z "$(git -C nixpkgs.git branch --contains="$nixpkgsBaseCommit" mirrorBranch)" ]]; then
    echo "It is not"
    startingCommit=$nixpkgsBaseCommit
    extraCommits=0
  else
    echo "It is!"
    echo "Checking if the branch has a linear history"
    if ! isLinear nixpkgs.git "$nixpkgsBaseCommit"..mirrorBranch; then
      echo "It is not linear, resetting the branch"
      startingCommit=$nixpkgsBaseCommit
      extraCommits=0
    else
      echo "It is linear!"
      nixpkgsCount=$(git -C nixpkgs.git rev-list --count "$nixpkgsBaseCommit"..mirrorBranch)
      echo "There's $nixpkgsCount commits in the branch on top of the base commit"
      extraCommits=0
      # Check if there's at least 1 commits in nixpkgs and at least 0 commits in nixfmt
      # Check if commit 1 in nixpkgs corresponds to commit 0 in nixfmt
      # If true, increase extraCommits by one, otherwise break
      # Check if there's at least 2 commits in nixpkgs and at least 1 commits in nixfmt
      # If so, check if commit 2 in nixpkgs corresponds to commit 1 in nixfmt
      # ...
      while
        if (( nixpkgsCount >= extraCommits + 1 && nixfmtCommitCount >= extraCommits)); then
          echo "Checking whether commit with index $(( extraCommits + 1 )) in nixpkgs corresponds to commit with index $extraCommits in nixfmt"
          nixpkgsCommit=$(git -C nixpkgs.git rev-parse "mirrorBranch~$((nixpkgsCount - (extraCommits + 1)))")
          body=$(git -C nixpkgs.git log -1 "$nixpkgsCommit" --pretty=%B)
          nixfmtCommit=${commitsToMirror[$extraCommits]}
          expectedBody=$(bodyForCommit "$extraCommits" "$nixfmtCommit")
          if [[ "$body" == "$expectedBody" ]]; then
            echo "It does!"
          else
            echo "It does not, body of nixpkgs commit $nixpkgsCommit is"
            echo "$body"
            echo "But expected body is"
            echo "$expectedBody"
            false
          fi
        else
          false
        fi
      do
        extraCommits=$(( extraCommits + 1 ))
      done

      nixpkgsCommit=$(git -C nixpkgs.git rev-parse "mirrorBranch~$(( nixpkgsCount - extraCommits ))")
      startingCommit="$nixpkgsCommit"
    fi
  fi
fi

echo "Starting commit is $startingCommit, extraCommits is $extraCommits"

step "Fetching contents of Nixpkgs base commit $nixpkgsBaseCommit"
git init nixpkgs
git -C nixpkgs fetch --no-tags --depth 1 "$nixpkgsUpstreamUrl" "$nixpkgsBaseCommit":base

step "Fetching contents of the starting commit and updating the mirror branch"
if (( extraCommits == 0 )); then
  git -C nixpkgs switch -c mirrorBranch "$startingCommit"
else
  git -C nixpkgs fetch --no-tags --depth 1 "$nixpkgsMirrorUrl" "$startingCommit":mirrorBranch
  git -C nixpkgs switch mirrorBranch
fi

git -C nixpkgs push --force "$nixpkgsMirrorUrl" mirrorBranch:"$nixpkgsMirrorBranch"

if (( extraCommits == 0 )); then
  index=0
else
  index=$(( extraCommits - 1 ))
fi

if (( index == nixfmtCommitCount )); then
  echo "Nothing to do"
  exit 0
fi

git -C nixpkgs config user.name "GitHub Actions"
git -C nixpkgs config user.email "actions@users.noreply.github.com"

updateToIndex() {
  nixfmtCommit=${commitsToMirror[$index]}

  step "Checking out nixfmt at $nixfmtCommit"
  git -C nixfmt checkout -q "$nixfmtCommit"

  step "Building nixfmt"
  nix build ./nixfmt
}

applyNixfmt() {
  step "Checking out Nixpkgs at the base commit"
  git -C nixpkgs checkout "$nixpkgsBaseCommit" -- .

  step "Running nixfmt on nixpkgs"
  if ! xargs -r -0 -P"$(nproc)" -n1 -a <(find nixpkgs -type f -name '*.nix' -print0) result/bin/nixfmt; then
    echo -e "\e[31mFailed to run nixfmt on some files\e[0m"
  fi
}

commitResult() {
  step "Committing the formatted result"
  git -C nixpkgs add -A
  git -C nixpkgs commit --allow-empty -m "$(bodyForCommit "$index" "$nixfmtCommit")"

  step "Pushing result"
  git -C nixpkgs push "$nixpkgsMirrorUrl" mirrorBranch:"$nixpkgsMirrorBranch"
}


updateToIndex

appliedNixfmtPath=$(realpath result)

if (( extraCommits == 0 )); then
  applyNixfmt
  commitResult
fi

while (( index != nixfmtCommitCount )); do
  index=$(( index + 1 ))

  updateToIndex

  step "Formatting nixpkgs"
  if [[ "$appliedNixfmtPath" != "$(realpath result)" ]]; then
    applyNixfmt
    commitResult
    appliedNixfmtPath=$(realpath result)
  else
    echo "The nixfmt store path didn't change, saving ourselves a formatting"
    commitResult
  fi
done
