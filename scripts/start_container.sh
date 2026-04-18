#!/bin/zsh

# starts the Docker container and xvcd for USB forwarding

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

extra_mount_args=()
extra_env_args=()

host_local_config="$HOME/.config/vivado-on-silicon-mac/local_config.sh"
if [ -r "$host_local_config" ]
then
    source "$host_local_config"
fi

# Optional extra bind mount for local project folders.
# Example:
# export VIVADO_EXTRA_MOUNT_SOURCE="$HOME/path/to/project"
# export VIVADO_EXTRA_MOUNT_TARGET="/home/user/project"
if [ -n "$VIVADO_EXTRA_MOUNT_SOURCE" ] && [ -n "$VIVADO_EXTRA_MOUNT_TARGET" ] && [ -d "$VIVADO_EXTRA_MOUNT_SOURCE" ]
then
    extra_mount_args+=(--mount "type=bind,source=$VIVADO_EXTRA_MOUNT_SOURCE,target=$VIVADO_EXTRA_MOUNT_TARGET")
fi

if [ -n "$VIVADO_BOARD_REPO_PATHS" ]
then
    extra_env_args+=(-e "VIVADO_BOARD_REPO_PATHS=$VIVADO_BOARD_REPO_PATHS")
fi

# this is called when the container stops or ctrl+c is hit
function stop_container {
    docker kill vivado_container > /dev/null 2>&1
    f_echo "Stopped Docker container"
    killall xvcd > /dev/null 2>&1
    f_echo "Stopped xvcd"
    exit 0
}
trap 'stop_container' INT

# Make sure everything is setup to run the container
start_docker
if [[ $(docker ps) == *vivado_container* ]]
then
    f_echo "There is already an instance of the container running."
    exit 1
fi
killall xvcd > /dev/null 2>&1

# run container
docker run --init --rm --name vivado_container --mount type=bind,source="$script_dir/..",target="/home/user" "${extra_mount_args[@]}" "${extra_env_args[@]}" -p 127.0.0.1:5901:5901 --platform linux/amd64 x64-linux sudo -H -u user bash /home/user/scripts/linux_start.sh &
f_echo "Started container"
sleep 7
f_echo "Starting VNC viewer"
vncpass=$( tr -d "\n\r\t " < "$script_dir/vncpasswd" )
osascript -e "tell application \"Screen Sharing\" to GetURL \"vnc://user:$vncpass@localhost:5901\""
f_echo "Running xvcd for USB forwarding..."
# while vivado_container is running
while [[ $(docker ps) == *vivado_container* ]]
do
    # if there is a running instance of xvcd
    if pgrep -x "xvcd" > /dev/null
    then
        :
    else
        eval "$script_dir/xvcd/bin/xvcd > /dev/null 2>&1 &"
        sleep 2
    fi
done
stop_container
