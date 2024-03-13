#!/bin/bash
set -e

# Copy stdout and stderr to a log file
exec > >(tee /tmp/sync_tool.log) 2>&1

# Lock the script to prevent multiple instances from running
lockfile -r 0 /tmp/sync_tool.lock || exit 1
trap 'on_exit' EXIT


# ----------------------------------- INFOS ------------------------------------

# PULL from the remote at startup.
# PUSH to the remote on every file change.
#
# TODO VOIR rclone --backup-dir


# ---------------------------------- CONFIG ------------------------------------

# The local and remote directories to synchronize
RCLONE_LOCAL="/home/ju/.sync"
RCLONE_REMOTE="remote:sync"  # list them with `rclone listremotes`
RCLONE_MOUNT="/home/ju/Sync"

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

on_exit() {
  rm -f /tmp/sync_tool.lock;
  rm -f /tmp/sync_tool_push_pull.lock;
  fusermount -u $RCLONE_MOUNT  # Unmount the remote
  echo "Exiting"
}

rclone_pull() {
  if [ -f /tmp/sync_tool_push_pull.lock ]; then echo "pull locked"; return; fi
  echo "Pulling from remote"
  $RCLONE_PULL
  rm -f /tmp/sync_tool_push_pull.lock
}

rclone_push() {
  if [ -f /tmp/sync_tool_push_pull.lock ]; then echo "push locked"; return; fi
  echo "Pushing to remote"
  $RCLONE_PUSH
  rm -f /tmp/sync_tool_push_pull.lock
}

notify() {
  MESSAGE=$1
  if [ $ENABLE_NOTIFY = "true" ]; then
    notify-send "SyncTool" "$MESSAGE"
  fi
}

rclone_sync() {
#  set -x
  rclone_pull
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
  SERVICE_FILE="$HOME/.config/systemd/user/rclone_sync.$RCLONE_REMOTE.service"
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
  systemctl --user enable --now rclone_sync.$RCLONE_REMOTE
  systemctl --user status rclone_sync.$RCLONE_REMOTE
  echo "You can watch the service logs with this command:"
  echo "    journalctl --user-unit rclone_sync.$RCLONE_REMOTE"
  echo "You can watch the script logs with this command:"
  echo "    tail -f /tmp/sync_tool.log"
}


# ----------------------------------- MAIN -------------------------------------

if [ $# = 0 ]; then
  sleep 10  # Wait for the network and dbus to be ready
  # No arguments given, mount the remote for easy access (optional) and start the sync
  mkdir -p $RCLONE_MOUNT
  rclone mount $RCLONE_REMOTE $RCLONE_MOUNT &
  rclone_sync
else
  # Run the given command with the following arguments
  CMD=$1; shift;
  $CMD "$@"
fi
