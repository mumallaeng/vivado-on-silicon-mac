#!/bin/zsh

# starts the Docker container and xvcd for USB forwarding

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

extra_mount_args=()
extra_env_args=()

function append_bind_mount {
    local mount_source="$1"
    local mount_target="$2"
    local mount_arg
    local i

    if [ -z "$mount_source" ] || [ -z "$mount_target" ] || [ ! -d "$mount_source" ]
    then
        return 0
    fi

    for (( i = 2; i <= ${#extra_mount_args}; i += 2 ))
    do
        mount_arg="${extra_mount_args[i]}"
        if [[ "$mount_arg" == *"target=$mount_target"* ]]
        then
            return 0
        fi
    done

    extra_mount_args+=(--mount "type=bind,source=$mount_source,target=$mount_target")
}

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
    append_bind_mount "$VIVADO_EXTRA_MOUNT_SOURCE" "$VIVADO_EXTRA_MOUNT_TARGET"
fi

resolved_board_repo_paths="${VIVADO_BOARD_REPO_PATHS:-}"
local_board_repo_root="$script_dir/../local-board-repos"
container_board_repo_root="/home/user/local-board-repos"
if find "$local_board_repo_root" -mindepth 2 -maxdepth 4 -name board.xml -print -quit 2>/dev/null | grep -q .
then
    case ":$resolved_board_repo_paths:" in
        *":$container_board_repo_root:"*)
            ;;
        "::")
            resolved_board_repo_paths="$container_board_repo_root"
            ;;
        *)
            resolved_board_repo_paths="${resolved_board_repo_paths}:$container_board_repo_root"
            ;;
    esac
fi

if [ -n "$resolved_board_repo_paths" ]
then
    extra_env_args+=(-e "VIVADO_BOARD_REPO_PATHS=$resolved_board_repo_paths")
    f_echo "Using board repositories: $resolved_board_repo_paths"
fi

if [ -n "$VIVADO_ENABLE_HARDWARE_MANAGER" ]
then
    extra_env_args+=(-e "VIVADO_ENABLE_HARDWARE_MANAGER=$VIVADO_ENABLE_HARDWARE_MANAGER")
fi

requested_vnc_resolution="${VIVADO_VNC_RESOLUTION:-$(read_vnc_resolution_setting)}"
requested_vnc_mode=$(printf '%s' "$requested_vnc_resolution" | tr '[:upper:]' '[:lower:]')
if resolved_vnc_resolution=$(resolve_vnc_resolution "$requested_vnc_resolution")
then
    extra_env_args+=(-e "VIVADO_VNC_RESOLUTION=$resolved_vnc_resolution")
    if [ "$requested_vnc_mode" = "auto" ]
    then
        f_echo "Using VNC resolution $resolved_vnc_resolution (auto-detected from the main display)"
    else
        f_echo "Using VNC resolution $resolved_vnc_resolution"
    fi
else
    extra_env_args+=(-e "VIVADO_VNC_RESOLUTION=$vnc_default_resolution")
    f_echo "Invalid VNC resolution setting '${requested_vnc_resolution:-<empty>}'. Falling back to $vnc_default_resolution."
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
docker run --init --rm --name vivado_container --mount type=bind,source="$script_dir/..",target="/home/user" "${extra_mount_args[@]}" "${extra_env_args[@]}" -p 127.0.0.1:5901:5901 --platform linux/amd64 x64-linux sudo -H --preserve-env=VIVADO_VNC_RESOLUTION,VIVADO_BOARD_REPO_PATHS -u user bash /home/user/scripts/linux_start.sh &
f_echo "Started container"
sleep 7
f_echo "Starting VNC viewer"
vncpass=$( tr -d "\n\r\t " < "$script_dir/vncpasswd" )
osascript -e "tell application \"Screen Sharing\" to GetURL \"vnc://user:$vncpass@localhost:5901\""
if [ "${VIVADO_ENABLE_HARDWARE_MANAGER:-1}" = "0" ]
then
    f_echo "Hardware manager integration disabled. Skipping xvcd."
    while [[ $(docker ps) == *vivado_container* ]]
    do
        sleep 2
    done
else
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
fi
stop_container
