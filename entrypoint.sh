#!/bin/sh

set -o nounset

BUILD_USER="${BUILD_USER:=builder}"
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
# whatever the image named it: the group is the user's own, as useradd makes
# it, so there is nobody else in it to think of.  A number that is already
# taken, by another user or another group of the image, is shared with it,
# which is what -o allows: it is the number that has to match, and the name
# is left as it is.
#
# The files of the home directory are renumbered by usermod, which walks the
# directory once for the uid and the gid together, hence both are given to
# the one call.  For the gid, that walk finds the files by the gid the user
# had, so the user's entry must still say the old gid when usermod runs, and
# a group with the new gid must exist for it to take.  groupmod -g would give
# the group the new gid, but it rewrites the user's entry as well, which is
# what the walk needs left alone; so the old group is renamed instead, a new
# one is made under the old name with the new gid, and the old one is deleted
# once usermod has moved the user out of it.
if [ "$uid" -ne 0 ]; then
    opts='' group=''
    if [ "$(id -u "$BUILD_USER")" -ne "$uid" ]; then
        opts="-o -u $uid"
    fi
    if [ "$(id -g "$BUILD_USER")" -ne "$gid" ]; then
        group=$(id -gn "$BUILD_USER")
        groupmod -n "${group}-old" "$group"
        groupadd -o -g "$gid" "$group"
        opts="$opts -g $gid"
    fi
    if [ -n "$opts" ]; then
        # shellcheck disable=SC2086 # opts is a list of words of our own
        usermod $opts "$BUILD_USER"
    fi
    if [ -n "$group" ]; then
        groupdel "${group}-old"
    fi
fi

if [ $# -ne 0 ]; then
    export USER="${BUILD_USER}"
    export HOME="/home/${BUILD_USER}"

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
