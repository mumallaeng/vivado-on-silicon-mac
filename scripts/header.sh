# general functions and definitions used by the other scripts

# This script needs to be sourced into other scripts or
# be run explicitly with an interpreter since it has no shebang

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/hashes.sh"

# echo with color
function f_echo {
	echo -e "\e[1m\e[33m$1\e[0m"
}

# aborts the script if it isn't run on macOS
function validate_macos {
    if [[ $(uname) == *Darwin* ]]
    then
        :
    else
        f_echo "Make sure to run this script on macOS."
        exit 1
    fi
}

# aborts the script if it isn't run inside the Docker container
function validate_linux {
    if [[ $(uname) == *Linux* ]]
    then
        :
    else
        f_echo "Make sure to run this script on Linux."
        exit 1
    fi
}

function validate_internet {
    if ! curl -s --connect-timeout 5 https://www.google.com &>/dev/null
    then
        f_echo "Internet connection required."
        exit 1
    fi
}

function wait_for_user_input {
    f_echo "Press Enter to continue..."
    read
}

function is_valid_vnc_resolution {
    [[ "$1" =~ ^[0-9]+x[0-9]+$ ]]
}

function read_vnc_resolution_setting {
    local resolution_file="${1:-$script_dir/vnc_resolution}"

    if [ -r "$resolution_file" ]
    then
        tr -d "\n\r\t " < "$resolution_file"
    fi
}

function detect_host_vnc_resolution {
    local display_info resolution

    validate_macos

    display_info=$(system_profiler SPDisplaysDataType 2>/dev/null) || return 1
    resolution=$(printf '%s\n' "$display_info" | awk '
        BEGIN {
            ui = ""
            res = ""
            first = ""
            found = 0
        }
        /^        [^ ].*:$/ {
            if ($0 !~ /^        Displays:$/) {
                ui = ""
                res = ""
            }
            next
        }
        /^          UI Looks like:/ {
            ui = $0
            sub(/^.*UI Looks like: /, "", ui)
            sub(/ @.*/, "", ui)
            gsub(/ /, "", ui)
            if (first == "") {
                first = ui
            }
            next
        }
        /^          Resolution:/ {
            res = $0
            sub(/^.*Resolution: /, "", res)
            sub(/ Retina.*/, "", res)
            sub(/ \(.*\)/, "", res)
            gsub(/ /, "", res)
            if (first == "") {
                first = res
            }
            next
        }
        /^          Main Display: Yes$/ {
            if (ui != "") {
                found = 1
                print ui
                exit
            }
            if (res != "") {
                found = 1
                print res
                exit
            }
        }
        END {
            if (!found && first != "") {
                print first
            }
        }
    ')

    if is_valid_vnc_resolution "$resolution"
    then
        printf '%s\n' "$resolution"
        return 0
    fi

    return 1
}

function resolve_vnc_resolution {
    local requested_resolution="$1"
    local requested_mode

    if [ -z "$requested_resolution" ]
    then
        requested_resolution="$vnc_default_resolution"
    fi

    requested_mode=$(printf '%s' "$requested_resolution" | tr '[:upper:]' '[:lower:]')
    if [ "$requested_mode" = "auto" ]
    then
        detect_host_vnc_resolution
        return $?
    fi

    if is_valid_vnc_resolution "$requested_resolution"
    then
        printf '%s\n' "$requested_resolution"
        return 0
    fi

    return 1
}

function start_docker {
    # check if Docker is installed
    if ! which docker &> /dev/null
    then
        f_echo "You need to install Docker Desktop first."
        exit 1
    fi

    # Launch Docker daemon
    f_echo "Launching Docker daemon..."
    sleep 2
    # Wait for Docker to start
    while ! docker ps &> /dev/null
    do
        open -a Docker
        sleep 5
    done
    sleep 2
}

function stop_docker {
    curl -s -X POST -H 'Content-Type: application/json' -d '{ "openContainerView": true }' -kiv --unix-socket "$HOME/Library/Containers/com.docker.docker/Data/backend.sock" http://localhost/engine/stop &> /dev/null
    osascript -e 'quit app "Docker Desktop"'
    sleep 2
}

vivado_version=""

function set_vivado_version_from_hash {
    if [[ -v web_hashes[$1] ]]
    then
        vivado_version=${web_hashes[$1]}
    elif [[ -v sfd_hashes[$1] ]]
    then
        vivado_version=${sfd_hashes[$1]}
    else
        f_echo "Invalid installer hash"
        exit 1
    fi
    return 0
}

function set_vivado_version_from_filename {
    case "$(basename "$1")" in
        *2020.2*)
            vivado_version=202020
            ;;
        *2021.1*)
            vivado_version=202110
            ;;
        *2022.2*)
            vivado_version=202220
            ;;
        *2023.1*)
            vivado_version=202310
            ;;
        *2023.2*)
            vivado_version=202320
            ;;
        *2024.1*)
            vivado_version=202410
            ;;
        *2025.2*)
            vivado_version=202520
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}

function find_vivado_dir {
    local candidate

    for candidate in $(find /home/user/Xilinx \
        -mindepth 2 -maxdepth 2 \
        \( -path "/home/user/Xilinx/Vivado/*" -o -path "/home/user/Xilinx/*/Vivado" \) \
        -type d 2>/dev/null | sort)
    do
        if [ -f "$candidate/settings64.sh" ] && [ -x "$candidate/bin/vivado" ]
        then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# The actual resolution is stored in the file vnc_resolution
vnc_default_resolution="1920x1080"

current_user=$(whoami)
