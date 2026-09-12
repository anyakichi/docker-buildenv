#!/bin/sh

set -o errexit
set -o nounset

BUILD_USER="${BUILD_USER:=builder}"
BUILD_HOME="/home/${BUILD_USER}"
export WORKDIR="${WORKDIR:-$PWD}"

suexec() {
    if command -v gosu >/dev/null 2>&1; then
        exec gosu "$BUILD_USER" "$@"
    elif command -v setpriv >/dev/null 2>&1; then
        exec setpriv --reuid="$BUILD_USER" --regid="$(id -g "$BUILD_USER")" \
            --init-groups "$@"
    else
        exec sudo -EHu "$BUILD_USER" "$@"
    fi
}

uid=$(stat -c "%u" .)
gid=$(stat -c "%g" .)

# Give the builder the uid and the gid of the mounted directory, so that what
# it writes there is the owner's.  The group is the builder's primary group,
# whatever the image named it.  A number the image has already given to
# someone else is shared, as usermod -o would: only the number has to match.
#
# The entries are rewritten in place rather than by usermod, whose walk of
# the home directory does not stop at a mount: a .ssh mounted under the home
# would be renumbered on the host, and a read-only one would fail the walk.
# The walk here stays on the file system of the home, so what was mounted
# into it is left as it came.  Nor is shadow needed then, which busybox lacks.
if [ "$uid" -ne 0 ]; then
    olduid=$(id -u "$BUILD_USER")
    oldgid=$(id -g "$BUILD_USER")
    if [ "$oldgid" -ne "$gid" ]; then
        group=$(id -gn "$BUILD_USER")
        sed -i "s/^\($group:[^:]*\):$oldgid:/\1:$gid:/" /etc/group
        sed -i "s/^\($BUILD_USER:[^:]*:[^:]*\):$oldgid:/\1:$gid:/" /etc/passwd
        find "$BUILD_HOME" -xdev -group "$oldgid" -exec chown -h ":$gid" {} +
    fi
    if [ "$olduid" -ne "$uid" ]; then
        sed -i "s/^\($BUILD_USER:[^:]*\):$olduid:/\1:$uid:/" /etc/passwd
        find "$BUILD_HOME" -xdev -user "$olduid" -exec chown -h "$uid" {} +
    fi
fi

if [ $# -ne 0 ]; then
    export USER="${BUILD_USER}"
    export HOME="$BUILD_HOME"

    # Whether the first argument names a command of buildenv is asked while
    # still root, so BASH_ENV, which din points into the mounted tree, is
    # emptied for the asking: nothing of that tree is to run before the
    # privileges are dropped.
    if BASH_ENV='' buildenv "$1" -h >/dev/null 2>&1; then
        suexec buildenv "$@"
    else
        suexec "$@"
    fi
fi
