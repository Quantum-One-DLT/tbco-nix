# This is a a CI check script that runs after nix/regenerate.sh in the project
# repository. If anything changes, then it uploads the patch to Buildkite. If
# run on a PR branch, and there is a SSH key present, it will attempt to push
# the changes back to the PR.

{ lib, runtimeShell, writeScript, coreutils, nixStable, git, gawk }:

with lib;

writeScript "check-stack-project.sh" ''
  #!${runtimeShell}

  set -euo pipefail

  export PATH="${makeBinPath [ runtimeShell coreutils nixStable git gawk ]}:$PATH"

  if [ -z "''${BUILDKITE:-}" ]; then
    # Go to top of project repo, unless running under CI.
    # If running under CI, assume the pipeline has set the correct directory.
    cd $(git rev-parse --show-toplevel)
  fi

  # The generated files will appear somewhere under ./nix
  git add -A nix

  # Check if there are changes staged for commit.
  if git diff-index --ignore-all-space --cached --quiet HEAD --; then
    echo "Generated Nix code is up-to-date."
    exit 0
  else
    echo "Committing changes..."
    commit_message="Regenerate nix"

    # If on a PR branch, search for a previous regen commit to fix up.
    commit_fixup=""
    if [ -n "''${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}" ]; then
      git fetch -v origin $BUILDKITE_PULL_REQUEST_BASE_BRANCH
      commit_fixup=$(git log --pretty=oneline --no-decorate origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH..HEAD | awk "/$commit_message/ { print \$1; }")
    fi

    # Create the commit
    export GIT_COMMITTER_NAME="TBCO"
    export GIT_COMMITTER_EMAIL="devops+stack-project@blockchain-company.io"
    export GIT_AUTHOR_NAME="$GIT_COMMITTER_NAME"
    export GIT_AUTHOR_EMAIL="$GIT_COMMITTER_EMAIL"
    if [ -n "$commit_fixup" ]; then
      git commit --no-gpg-sign --fixup "$commit_fixup"
    else
      git commit --no-gpg-sign --message "$commit_message"
    fi

    # If running in Buildkite...
    if [ -n "''${BUILDKITE_JOB_ID:-}" ]; then

      # Upload the patch as a Buildkite artifact
      patch="$BUILDKITE_PIPELINE_SLUG-nix-$BUILDKITE_BUILD_NUMBER.patch"
      git format-patch --stdout -1 HEAD > "$patch"
      buildkite-agent artifact upload "$patch" --job "$BUILDKITE_JOB_ID"

      echo
      echo "Error: The generated nix files are not up to date."
      echo
      echo "Now trying to push the updates back to the repo..."

      # Push the changes back to the pull request
      if [ -n "''${BUILDKITE_PULL_REQUEST_REPO:-}" ]; then
        sshkey="/run/keys/buildkite-$BUILDKITE_PIPELINE_SLUG-ssh-private"
        if [ -e $sshkey ]; then
          echo "Authenticating using SSH with $sshkey"
          export GIT_SSH_COMMAND="ssh -i $sshkey -F /dev/null"
          remote=$(echo $BUILDKITE_PULL_REQUEST_REPO | sed -e 's=^[a-z]*://github.com/=git@github.com:=')
          git push $remote HEAD:$BUILDKITE_BRANCH
          exit 0
        else
          echo "There is no SSH key at $sshkey"
          echo "The updates can't be pushed."
          echo
          echo "To add SSH keys, see: "
          echo "https://github.com/The-Blockchain-Company/ci-ops/blob/0a35ebc25df1ca9e764ddd4739be3eb965ecbe2d/modules/buildkite-agent-containers.nix#L225-L230"
          echo
          echo "Error: The generated nix files are not up to date."
          printf 'Apply the patch \033]1339;url=artifact://'$patch';content='$patch'\a from the build artifacts.\n'
        fi
      fi

    fi

    exit 1
  fi
''
