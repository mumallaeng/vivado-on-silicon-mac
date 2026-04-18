if {[info exists ::env(VIVADO_BOARD_REPO_PATHS)] && $::env(VIVADO_BOARD_REPO_PATHS) ne ""} {
    set repo_paths [split $::env(VIVADO_BOARD_REPO_PATHS) ":"]
    if {[catch {set_param board.repoPaths $repo_paths} err]} {
        puts "WARNING: Failed to set board.repoPaths: $err"
    } else {
        puts "INFO: board.repoPaths -> $repo_paths"
    }
}
