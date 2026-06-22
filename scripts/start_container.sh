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

function open_vnc_viewer {
    local vncpass

    vncpass=$(tr -d "\n\r\t " < "$script_dir/vncpasswd")
    f_echo "Starting VNC viewer"
    osascript -e "tell application \"Screen Sharing\" to GetURL \"vnc://user:$vncpass@localhost:5901\""
}

host_local_config="$HOME/.config/vivado-on-silicon-mac/local_config.sh"
if [ -r "$host_local_config" ]
then
    source "$host_local_config"
fi

xvc_backend=$(printf '%s' "${VIVADO_XVC_BACKEND:-xvcd}" | tr '[:upper:]' '[:lower:]')
xvc_port="${VIVADO_XVC_PORT:-2542}"
openfpgaloader_cable="${VIVADO_OPENFPGALOADER_CABLE:-digilent}"
openfpgaloader_bridge_script="$script_dir/run_openfpgaloader_xvc_bridge.py"
openfpgaloader_bridge_pid_file="$script_dir/../openfpgaloader-xvc.pid"
openfpgaloader_bridge_log_file="$script_dir/../openfpgaloader-xvc.log"

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

function openfpgaloader_bridge_running {
    local bridge_pid=""

    if [ ! -r "$openfpgaloader_bridge_pid_file" ]
    then
        return 1
    fi

    bridge_pid=$(tr -d "\n\r\t " < "$openfpgaloader_bridge_pid_file")
    if [ -z "$bridge_pid" ]
    then
        return 1
    fi

    kill -0 "$bridge_pid" > /dev/null 2>&1
}

function stop_xvc_bridge {
    local bridge_pid=""

    if [ -r "$openfpgaloader_bridge_pid_file" ]
    then
        bridge_pid=$(tr -d "\n\r\t " < "$openfpgaloader_bridge_pid_file")
        if [ -n "$bridge_pid" ]
        then
            kill "$bridge_pid" > /dev/null 2>&1
        fi
        rm -f "$openfpgaloader_bridge_pid_file"
    fi

    pkill -f "$openfpgaloader_bridge_script" > /dev/null 2>&1
    pkill -f "openFPGALoader --xvc" > /dev/null 2>&1
    killall xvcd > /dev/null 2>&1
}

function start_openfpgaloader_bridge {
    local bridge_cmd

    if ! command -v openFPGALoader > /dev/null 2>&1
    then
        f_echo "openFPGALoader is required for the selected XVC backend."
        exit 1
    fi

    bridge_cmd=(
        "$openfpgaloader_bridge_script"
        --port "$xvc_port"
        --cable "$openfpgaloader_cable"
        --pid-file "$openfpgaloader_bridge_pid_file"
        --log-file "$openfpgaloader_bridge_log_file"
    )

    if [ -n "$VIVADO_OPENFPGALOADER_VID" ]
    then
        bridge_cmd+=(--vid "$VIVADO_OPENFPGALOADER_VID")
    fi
    if [ -n "$VIVADO_OPENFPGALOADER_PID" ]
    then
        bridge_cmd+=(--pid "$VIVADO_OPENFPGALOADER_PID")
    fi
    if [ -n "$VIVADO_OPENFPGALOADER_CABLE_INDEX" ]
    then
        bridge_cmd+=(--cable-index "$VIVADO_OPENFPGALOADER_CABLE_INDEX")
    fi
    if [ -n "$VIVADO_OPENFPGALOADER_FTDI_SERIAL" ]
    then
        bridge_cmd+=(--ftdi-serial "$VIVADO_OPENFPGALOADER_FTDI_SERIAL")
    fi
    if [ -n "$VIVADO_OPENFPGALOADER_FTDI_CHANNEL" ]
    then
        bridge_cmd+=(--ftdi-channel "$VIVADO_OPENFPGALOADER_FTDI_CHANNEL")
    fi

    "${bridge_cmd[@]}" > /dev/null 2>&1 &
    sleep 2
    if openfpgaloader_bridge_running
    then
        f_echo "Started openFPGALoader XVC bridge on port $xvc_port"
    else
        f_echo "Failed to start openFPGALoader XVC bridge. See $openfpgaloader_bridge_log_file"
        exit 1
    fi
}

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
    stop_xvc_bridge
    f_echo "Stopped XVC bridge"
    exit 0
}
trap 'stop_container' INT

# Make sure everything is setup to run the container
start_docker
if [[ $(docker ps) == *vivado_container* ]]
then
    f_echo "There is already an instance of the container running. Reusing it."
    if [ "${VIVADO_ENABLE_HARDWARE_MANAGER:-1}" != "0" ]
    then
        if [ "$xvc_backend" = "openfpgaloader" ]
        then
            if openfpgaloader_bridge_running
            then
                :
            else
                start_openfpgaloader_bridge
            fi
        else
            if pgrep -x "xvcd" > /dev/null
            then
                :
            else
                eval "$script_dir/xvcd/bin/xvcd > /dev/null 2>&1 &"
                sleep 2
            fi
        fi
    fi
    open_vnc_viewer
    exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq vivado_container
then
    docker rm -f vivado_container > /dev/null 2>&1
fi

stop_xvc_bridge

if ! docker image inspect x64-linux > /dev/null 2>&1
then
    f_echo "The Docker image 'x64-linux' was not found. Run $script_dir/gen_image.sh first."
    exit 1
fi

# run container
docker run --init --rm --name vivado_container --mount type=bind,source="$script_dir/..",target="/home/user" "${extra_mount_args[@]}" "${extra_env_args[@]}" -p 127.0.0.1:5901:5901 --platform linux/amd64 x64-linux sudo -H --preserve-env=VIVADO_VNC_RESOLUTION,VIVADO_BOARD_REPO_PATHS,VIVADO_ENABLE_HARDWARE_MANAGER -u user bash /home/user/scripts/linux_start.sh &
f_echo "Started container"
sleep 7
if ! docker ps --format '{{.Names}}' | grep -Fxq vivado_container
then
    f_echo "vivado_container failed to start. Check that the image exists and Docker is healthy."
    exit 1
fi
open_vnc_viewer
if [ "${VIVADO_ENABLE_HARDWARE_MANAGER:-1}" = "0" ]
then
    f_echo "Hardware manager integration disabled. Skipping xvcd."
    while [[ $(docker ps) == *vivado_container* ]]
    do
        sleep 2
    done
else
    if [ "$xvc_backend" = "openfpgaloader" ]
    then
        f_echo "Running openFPGALoader XVC bridge for USB forwarding..."
    else
        f_echo "Running xvcd for USB forwarding..."
    fi
    # while vivado_container is running
    while [[ $(docker ps) == *vivado_container* ]]
    do
        if [ "$xvc_backend" = "openfpgaloader" ]
        then
            if openfpgaloader_bridge_running
            then
                :
            else
                start_openfpgaloader_bridge
            fi
        else
            # if there is a running instance of xvcd
            if pgrep -x "xvcd" > /dev/null
            then
                :
            else
                eval "$script_dir/xvcd/bin/xvcd > /dev/null 2>&1 &"
                sleep 2
            fi
        fi
    done
fi
stop_container
