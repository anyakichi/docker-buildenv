#!/bin/bash

set -o nounset
set -o pipefail

BUILD_USER="${BUILD_USER:=builder}"
BUILD_GROUP="${BUILD_GROUP:=builder}"
export WORKDIR="${WORKDIR:-$PWD}"

suexec() {
    if command -v gosu >/dev/null 2>&1; then
        exec gosu "$BUILD_USER" "$@"
    elif command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid="$BUILD_USER" --regid="$BUILD_GROUP" --init-groups "$@"
    else
        exec sudo -EHu "$BUILD_USER" "$@"
    fi
}

uid=$(stat -c "%u" .)
gid=$(stat -c "%g" .)

if [ "$uid" -ne 0 ]; then
    if [ "$(id -g "$BUILD_GROUP")" -ne "${gid}" ]; then
        getent group "${gid}" >/dev/null 2>&1 || groupmod -g "${gid}" "${BUILD_GROUP}"
        chgrp -R "${gid}" "/home/${BUILD_USER}"
    fi
    if [ "$(id -u "$BUILD_USER")" -ne "${uid}" ]; then
        usermod -u "${uid}" "${BUILD_USER}"
    fi
fi

if [ $# -ne 0 ]; then
    export USER=${BUILD_USER}
    export HOME=/home/${BUILD_USER}

    if buildenv "$1" -h >/dev/null 2>&1; then
        suexec buildenv "$@"
    else
        suexec "$@"
    fi
fi
