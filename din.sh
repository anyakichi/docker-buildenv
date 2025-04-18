#!/bin/bash

din()
{
    local workdir=/build
    local i opts
    opts=()

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

    docker run -it --rm \
        -v "$(pwd):${workdir}" \
        -w "${workdir}" \
        -h "$(basename "$(pwd)")" \
        -e BASH_ENV="${workdir}/.bashrc" \
        "${opts[@]}" \
        "$@"
}

din "$@"
