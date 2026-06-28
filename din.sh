#!/bin/bash

din() {
    local workdir=/build
    local i opts
    opts=(
        -i --rm
        -v "$PWD:${workdir}"
        -w "${workdir}"
        -h "$(basename "$PWD")"
        -e BASH_ENV="${workdir}/.bashrc"
    )

    for i in TERM http_proxy https_proxy ftp_proxy no_proxy; do
        if [[ "${!i}" ]]; then
            opts+=(-e "${i}=${!i}")
        fi
    done

    if [[ -d "${HOME}/.cache/buildenv" ]]; then
        opts+=(-v "${HOME}/.cache/buildenv:/cache")
        opts+=(-e "CCACHE_DIR=/cache/ccache")
        opts+=(-e "SCCACHE_DIR=/cache/sccache")
    else
        opts+=(-e "CCACHE_DISABLE=1")
    fi

    if [[ -t 0 ]]; then
        opts+=(-t)
    fi

    if [[ -z $DIN_CMD ]]; then
        if command -v docker >/dev/null 2>&1; then
            DIN_CMD=docker
        elif command -v podman >/dev/null 2>&1; then
            DIN_CMD=podman
        fi
    fi

    if [[ $DIN_CMD == podman ]]; then
        podman run \
            --user 0:0 --userns "keep-id:uid=$(id -u),gid=$(id -g)" \
            "${opts[@]}" "$@"
    else
        docker run "${opts[@]}" "$@"
    fi
}

din "$@"
