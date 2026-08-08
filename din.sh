#!/bin/sh

# Print the option lines to add, the files of ~/.config/din first and the
# environment after them, so that what a directory sets has the last word.
#
# There is a file for each of the DIN_OPTS of the environment -- config for
# the options that apply to either command, config_docker and config_podman
# for the ones only one of them takes -- so that nobody has to be told which
# of two files an option came from, and a file needs no way to ask which
# command is about to run.
#
# A file is printed with a newline of its own after it, since the last line of
# a file that ends without one would otherwise join the first line of what
# comes next.
din_opt_lines() {
    confdir="${XDG_CONFIG_HOME:-${HOME}/.config}/din"

    for file in "${confdir}/config" "${confdir}/config_${DIN_CMD}"; do
        if [ -f "$file" ]; then
            cat "$file"
            echo
        fi
    done

    if [ "$DIN_CMD" = podman ]; then
        printf '%s\n%s\n' "${DIN_OPTS:-}" "${DIN_PODMAN_OPTS:-}"
    else
        printf '%s\n%s\n' "${DIN_OPTS:-}" "${DIN_DOCKER_OPTS:-}"
    fi
}

din() {
    workdir=/build
    nargs=$#

    # The command is chosen before the configuration is read, since it is what
    # says which file to read.  It is docker unless docker is not there and
    # podman is; where neither is, docker is left to say so itself.
    if [ -z "${DIN_CMD:-}" ]; then
        DIN_CMD=docker
        if ! command -v docker >/dev/null 2>&1 &&
            command -v podman >/dev/null 2>&1; then
            DIN_CMD=podman
        fi
    fi

    # A shell has one list, and the list is the arguments, so the options are
    # appended to what din was given and the arguments are rotated back behind
    # them at the end.
    set -- "$@" \
        -i --rm \
        -v "$PWD:${workdir}" \
        -w "${workdir}" \
        -h "$(basename "$PWD")" \
        -e "BASH_ENV=${workdir}/.bashrc"

    for name in TERM http_proxy https_proxy ftp_proxy no_proxy; do
        eval "value=\${${name}:-}"
        if [ -n "$value" ]; then
            set -- "$@" -e "${name}=${value}"
        fi
    done

    # The cache was named after buildenv, which is what fills it, and is
    # named after din now, which is what everything of the host's is named
    # after.  The old name is still taken when it is the one that is there:
    # renaming a directory of somebody's home is not ours to do, and a cache
    # thrown away is a build done again from nothing.  It is looked for where
    # din put it, which was $HOME/.cache and never $XDG_CACHE_HOME, so that a
    # cache made before this is found whether that is set or not.
    cache="${XDG_CACHE_HOME:-${HOME}/.cache}/din"
    if [ ! -d "$cache" ] && [ -d "${HOME}/.cache/buildenv" ]; then
        echo "din: ${HOME}/.cache/buildenv is deprecated," \
            "rename it to ${cache}" >&2
        cache="${HOME}/.cache/buildenv"
    fi

    if [ -d "$cache" ]; then
        set -- "$@" \
            -v "${cache}:/cache" \
            -e "CCACHE_DIR=/cache/ccache" \
            -e "SCCACHE_DIR=/cache/sccache"
    else
        set -- "$@" -e "CCACHE_DISABLE=1"
    fi

    if [ -t 0 ]; then
        set -- "$@" -t
    fi

    if [ "$DIN_CMD" = podman ] && [ "$(id -u)" -ne 0 ]; then
        set -- "$@" --user 0:0 --userns "keep-id:uid=$(id -u),gid=$(id -g)"
    fi

    # A line is read as a command line and as nothing more: the here-document
    # hands eval the text of one line, and eval expands it the once, in the
    # shell that runs din, so that a variable in it is the one of that shell
    # and an argument with a space in it is quoted there as it would be
    # anywhere else.  This asks no more trust than any other file of a home
    # directory, and neither a file nor the environment is read out of the
    # tree being built: din reads nothing from that tree, on purpose.
    #
    # A line that does not parse is caught by a shell of its own beforehand,
    # since a shell may end at a syntax error in an eval and would take the
    # line it could not read with it; -n keeps that shell from running any of
    # what it reads, so nothing of the line happens twice.
    while IFS= read -r line; do
        if ! sh -n -c "set -- $line" 2>/dev/null; then
            echo "din: cannot parse: $line" >&2
            exit 1
        fi
        eval "set -- \"\$@\" $line"
    done <<EOF
$(din_opt_lines)
EOF

    while [ "$nargs" -gt 0 ]; do
        arg=$1
        shift
        set -- "$@" "$arg"
        nargs=$((nargs - 1))
    done

    "$DIN_CMD" run "$@"
}

din "$@"
