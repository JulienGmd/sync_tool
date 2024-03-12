#!/bin/bash
set -e  # exit on error

dir=$(realpath "$(dirname "$0")")
to_sync_files=()

source .config

function echo_success() { echo -e "\e[32m$1\e[0m"; }
function echo_warning() { echo -e "\e[33m$1\e[0m"; }
function echo_error() { echo -e "\e[31m$1\e[0m"; }
function isFileOrDir() { { [ -f "$1" ] || [ -d "$1" ]; } && [ ! -L "$1" ]; }

# params: $1=repo_url, $2=to_dir
function bareClone() {
  git clone "$1" "$dir/tmp/bare_clone"
  mkdir -p "$2"
  mv "$dir/tmp/bare_clone/.git" "$2/.git"
  rm -rf "$dir/tmp/bare_clone"
}

# params: $1=to_dir
function copyLocalToDir() {
  for file in "${to_sync_files[@]}"; do
    if isFileOrDir "$file"; then
      cp -rfv "$file" "$1"
    fi
  done
}



# -----------------------------------------------------------------------------

echo_success "Syncing files..."

rm -rf "$dir/tmp"

# Parse to_sync file
while IFS= read -r line; do
  line="${line/\~/$HOME}"  # replace ~ with $HOME
  to_sync_files+=("$line")
done < "$dir/to_sync.txt"

# Ask config
if [ ! "$SYNC_REPO_URL" ]; then
  echo_warning "Config repo url: "
  read -r SYNC_REPO_URL
  echo "export SYNC_REPO_URL=$SYNC_REPO_URL" >> "$dir/.config"
fi
if [ ! "$SYNC_REMOTE_PATH" ]; then
  echo_warning "Config sync dir: "
  read -r SYNC_REMOTE_PATH
  echo "export SYNC_REMOTE_PATH=$SYNC_REMOTE_PATH" >> "$dir/.config"
fi

# Initial setup, clone repo and ask if user wants to keep remote or local
if [ -z "$SYNC_INITIAL_SETUP" ] || [ ! -d "$SYNC_REMOTE_PATH" ]; then
  bareClone "$SYNC_REPO_URL" "$dir/tmp/repo"
  copyLocalToDir "$dir/tmp/repo"
  cd "$dir/tmp/repo"
  git add .
  if ! git diff --quiet origin/main; then
    echo_warning "Local and remote differs"
    git --no-pager diff --stat origin/main
    echo_warning "Do you want to keep remote or local? ([r]emote/[l]ocal)"
    read -r answer
    if [ "$answer" = "r" ]; then
      git reset --hard origin/main
    elif [ "$answer" = "l" ]; then
      git add .
      git commit -m "sync"
      git push --force
    else
      echo "Invalid input"
      exit 1
    fi
  fi
  cd "$dir"
  mv -v "$dir/tmp/repo" "$SYNC_REMOTE_PATH"
  echo "export SYNC_INITIAL_SETUP=false" >> "$dir/.config"
fi



#  git remote add sync $SYNC_REPO_URL
