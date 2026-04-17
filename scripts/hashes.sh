# This file contains the hashes for the different versions
# of the Vivado installer.
# The first 4 digits are the year part of the version number
# The 5th digit is the subversion, e.g. 202210 corresponds
# to the version 2022.1.

# This script needs to be sourced into other scripts or
# be run explicitly with an interpreter since it has no shebang

# hashes for the web installer
declare -A web_hashes=(
    ["0c74a74cbef649dceea34774c5bca490"]=202020
    ["a6b118fffbcfdc7376c2640f276e2ca9"]=202110
    ["9bf473b6be0b8531e70fd3d5c0fe4817"]=202220
    ["e47ad71388b27a6e2339ee82c3c8765f"]=202310
    ["b8c785d03b754766538d6cde1277c4f0"]=202320
    ["8b0e99a41b851b50592d5d6ef1b1263d"]=202410
)
# hashes for the full installer
# not tested yet
declare -A sfd_hashes=(
    # not tested yet
    ["523e8596f114ab5e389c14df50ecb1d8"]=202020
    ["abe838aa2e2d3d9b10fea94165e9a303"]=202520
)
