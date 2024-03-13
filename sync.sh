#!/bin/bash
set -e

# Copy stdout and stderr to a log file
exec > >(tee /tmp/sync_tool.log) 2>&1


# ----------------------------------- INFOS ------------------------------------

# PULL from the remote at startup.
# PUSH to the remote on every file change.
#
# TODO VOIR rclone --backup-dir


# ---------------------------------- CONFIG ------------------------------------

# The local and remote directories to synchronize
RCLONE_LOCAL="/home/ju/.sync"
RCLONE_REMOTE="remote:sync"  # list them with `rclone listremotes`
RCLONE_MOUNT="/home/ju/Sync" # Mount the remote to this directory (does not affect the sync)

# The rclone commands to run
RCLONE_PULL="rclone sync -v $RCLONE_REMOTE $RCLONE_LOCAL"
RCLONE_PUSH="rclone sync -v $RCLONE_LOCAL $RCLONE_REMOTE"

# The file events that inotifywait should watch for
WATCH_EVENTS="modify,delete,create,move"

SYNC_DELAY=5
FORCED_SYNC_INTERVAL=3600

ENABLE_NOTIFY=true

SYNC_SCRIPT=$(realpath "$0")


# --------------------------------- FUNCTIONS ----------------------------------

rclone_pull() {
  if [ -f /tmp/sync_tool_push_pull.lock ]; then echo "pull locked"; return; fi
  trap 'rm -f /tmp/sync_tool_push_pull.lock' EXIT
  echo "Pulling from remote"
  $RCLONE_PULL
  rm -f /tmp/sync_tool_push_pull.lock
}

rclone_push() {
  if [ -f /tmp/sync_tool_push_pull.lock ]; then echo "push locked"; return; fi
  trap 'rm -f /tmp/sync_tool_push_pull.lock' EXIT
  echo "Pushing to remote"
  $RCLONE_PUSH
  rm -f /tmp/sync_tool_push_pull.lock
}

# Add a file or directory to the local directory, if rclone_sync is running,
# it will be synchronized immediately. Else, it will be synchronized on the next
# run of rclone_sync.
sync() {
  file=$1
  if [ -z "$file" ]; then echo "usage: sync <fileOrDir>"; return; fi

  mkdir -pv "$RCLONE_LOCAL$(dirname "$file")"
  cp -rv "$file" "$RCLONE_LOCAL$(dirname "$file")"
}

# Create symlinks for files on the machine to point to the local directory
create_symlinks() {
  while IFS= read -r -d '' file; do
    file_path=${file#$RCLONE_LOCAL}
    mkdir -pv "$(dirname "$file_path")"
    if [ -f "$file_path" ] || [ -d "$file_path" ] && [ ! -L "$file_path" ]; then
      # file or dir
      mv -v "$file_path" "$file_path.bak"
      ln -sv "$file" "$file_path"
    elif [ -L "$file_path" ]; then
      if [ "$(readlink -f "$file_path")" != "$file" ]; then
        # symlink pointing to a different file
        rm -v "$file_path"
        ln -sv "$file" "$file_path"
      fi
    else
      # no file
      ln -sv "$file" "$file_path"
    fi
  done < <(find $RCLONE_LOCAL -type f -print0)
}

notify() {
  MESSAGE=$1
  if [ $ENABLE_NOTIFY = "true" ]; then
    notify-send "SyncTool" "$MESSAGE"
  fi
}

rclone_sync() {
#  set -x

  cleanup() {
    rm -f /tmp/sync_tool_rclone_sync.lock;
    fusermount -u $RCLONE_MOUNT  # Unmount the remote
  }

  # Lock the function to prevent multiple instances from running
  lockfile -r 0 /tmp/sync_tool_rclone_sync.lock || exit 1
  trap cleanup EXIT

  rclone_pull
  create_symlinks

  # Mount the remote in the background (optional)
  mkdir -p $RCLONE_MOUNT
  rclone mount $RCLONE_REMOTE $RCLONE_MOUNT &

  # Watch for file events and do continuous immediate syncing and regular interval syncing:
  while inotifywait --recursive --timeout $FORCED_SYNC_INTERVAL -e $WATCH_EVENTS $RCLONE_LOCAL; do
    if [ $? -eq 0 ]; then  # file change detected
      sleep $SYNC_DELAY
      rclone_push
      notify "Synchronized"
    elif [ $? -eq 1 ]; then  # inotifywait error
      notify "inotifywait error exit code 1"
      sleep 10
    elif [ $? -eq 2 ]; then  # every FORCED_SYNC_INTERVAL
      rclone_push
      notify "Synchronized"
    fi
  done
}

systemd_setup() {
#  set -x
  SERVICE_FILE="$HOME/.config/systemd/user/sync_tool.rclone_sync.service"
  if [ -f "$SERVICE_FILE" ]; then
    echo "Unit file already exists: $SERVICE_FILE - Not overwriting."
  else
    mkdir -p "$(dirname "$SERVICE_FILE")"
    # Note: the After= dbus.service doesn't work.
    # Instead a sleep on script startup is used
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Sync files with rclone
After=network-online.target dbus.service

[Service]
ExecStart=$SYNC_SCRIPT
Restart=always

[Install]
WantedBy=default.target
EOF
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now sync_tool.rclone_sync
  systemctl --user status sync_tool.rclone_sync
  echo "You can watch the service logs with this command:"
  echo "    journalctl --user-unit sync_tool.rclone_sync"
  echo "You can watch the script logs with this command:"
  echo "    tail -f /tmp/sync_tool.log"
}


# ----------------------------------- MAIN -------------------------------------

if [ $# = 0 ]; then
  # No arguments given, start the sync
  sleep 5  # Wait for the network and dbus to be ready
  rclone_sync
else
  # Run the given command with the following arguments
  CMD=$1; shift;
  $CMD "$@"
fi
