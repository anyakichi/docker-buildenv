#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

shopt -s nullglob


if [[ -r /etc/buildenv.conf ]]; then
    . /etc/buildenv.conf
fi

ALIASES=${ALIASES:=1}
DOTCMDS=${DOTCMDS:=}
CONFDIR=${CONFDIR:=/etc/buildenv.d}

# Marker to distinguish command lines from continuation lines in the output
# of select_commands.
MARK=$'\001'


list_scmds()
{
    ls "${CONFDIR}" | sed 's/\..*$//' | sort -u
}

get_content_of_scmd()
{
    local file newline=""

    for file in "${CONFDIR}/${1}".*; do
        if [[ -n "${newline}" ]]; then
            echo
        else
            newline="\n"
        fi
        cat "${file}"
    done
}

dotcmd_p()
{
    local pat="\\<$1\\>"

    [[ ${DOTCMDS} =~ ${pat} ]]
}

expand_vars()
{
    local input

    input="$(cat -)"

    # The delimiter must be a string that never appears in the documents.
    cat <<-EOF_OUT | /bin/bash -u
	cat <<__BUILDENV_EXPAND_EOF__
	$(echo "${input}" | sed -r 's/\\(\$)|(\\|`)/\\\1\2/g')
	__BUILDENV_EXPAND_EOF__
	EOF_OUT
}

# Extract command lines from a document.  Each command line is prefixed with
# MARK.  A line that begins with ">", right after a command line or right after
# another such line, is a continuation of it; the text after the "> " is
# extracted as is, so that a command can span multiple lines.
#
# The ">" must stand in the column of the prompt it continues and be followed
# by a space, just as the prompt is, so that a command is written in a document
# as it is shown.  A ">" alone continues the command with an empty line.  A
# line indented more deeply is a line of the shell, not of ours, so a wrapped
# pipeline is left to the trailing backslash as before.
#
# A command line is held until the next line is read, because a continuation
# line takes precedence over a trailing backslash.
select_commands()
{
    local epat=${1:-'\$'} input

    [[ ${2+x} ]] && input="${2}" || input="$(cat -)"

    echo "${input}" | EPAT="${epat}" MARK="${MARK}" awk '
	function cont_p(s) {
	    return tlen > 0 && substr(s, 1, tlen) == tstr &&
	           (length(s) == tlen || substr(s, tlen + 1, 1) == " ")
	}
	function cont_text(s) {    # the text after the mark and its space
	    return substr(s, tlen + 2)
	}
	BEGIN {
	    cpat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+[^ \t]"
	    ppat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+"
	    mark = ENVIRON["MARK"]
	}
	{
	    if (held) {
	        if (cont_p($0)) {
	            print mark cmd    # leave the trailing backslash, if any, to bash
	            held = 0
	            cont = 1
	        } else if (cmd ~ /\\$/) {
	            sub(/[ \t]*\\$/, "", cmd)
	            line = $0
	            sub(/^[ \t]*/, "", line)
	            cmd = cmd " " line
	            next
	        } else {
	            print mark cmd
	            held = 0
	            cont = 0
	        }
	    }

	    if (cont && cont_p($0)) {
	        print cont_text($0)
	        next
	    }

	    cont = 0

	    if ($0 ~ cpat) {
	        tstr = $0
	        sub(/[^ \t].*$/, "", tstr)    # the indentation of the prompt
	        tstr = tstr ">"
	        tlen = length(tstr)
	        cmd = $0
	        sub(ppat, "", cmd)
	        held = 1
	    }
	}
	END {
	    if (held) {
	        print mark cmd
	    }
	}
    '
}

# Execute commands.  Errors are propagated by errexit rather than by appending
# "|| exit 1" to each command, because a command may span multiple lines.
exec_commands()
{
    local input

    [[ ${1+x} ]] && input="${1}" || input="$(cat -)"

    /bin/bash <(echo "${input}" | MARK="${MARK}" awk '
	function shquote(s,   n, arr, i, r) {
	    n = split(s, arr, q)
	    r = arr[1]
	    for (i = 2; i <= n; i++) {
	        r = r q "\\" q q arr[i]
	    }
	    return q r q
	}
	BEGIN {
	    q = sprintf("%c", 39)
	    mark = ENVIRON["MARK"]
	    print "set -o errexit"
	}
	substr($0, 1, 1) == mark {
	    s = substr($0, 2)
	    print "echo " shquote("==> " s) " >&2"
	    print s
	    next
	}
	{ print }    # continuation line
    ')
}

# Print commands as they are written in a document, with prompts.
print_commands()
{
    sed -e "s/^${MARK}/  \$ /" -e t -e "s/^/  > /"
}

ask_exec_commands()
{
    local scmd="${1:-dummy}" input="${2:-}"

    echo "${scmd^} commands:"
    echo
    echo "${input}" | print_commands
    echo

    read -rp "Continue? ($(basename "$0") ${scmd} -h for details) [Y/n] "
    if [[ ${REPLY:-y} =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
        exec_commands "${input}"
    fi
}

usage()
{
    local status=${1:-1} scmd=${2:-}
    local cmd

    cmd="$(basename "$0")"

    if [[ ! ${scmd} ]]; then
        echo "usage: ${cmd} init"
        for scmd in $(list_scmds); do
            echo "       ${cmd} ${scmd} [args]"
        done
    else
        case "${scmd}" in
            extract)
                echo "usage: ${cmd} ${scmd} [-Ddfhpxy]"
                ;;
            *)
                echo "usage: ${cmd} ${scmd} [-Ddhpxy]"
                ;;
        esac
    fi

    exit "${status}"
}

print_alias()
{
    local scmd="$1" type="${2:-}" pat="\\<${1}\\>"

    if [[ ${ALIASES} == 1 ]] || \
       ([[ ${ALIASES} == 2 ]] && ! type "${scmd}" >/dev/null 2>&1) || \
       [[ ${ALIASES} =~ ${pat} ]];
    then
        if [[ ${type} == "source" ]]; then
            echo "alias ${scmd}='. <(${cmd} ${scmd})'"
        else
            echo "alias ${scmd}='${cmd} ${scmd}'"
        fi
    fi
}

main_init()
{
    local cmd scmd

    cmd="$(basename "$0")"

    if [[ $# -ne 0 ]]; then
        usage 1
    fi

    if [[ ${ALIASES} == 0 ]]; then
        return 0
    fi

    for scmd in $(list_scmds); do
        if dotcmd_p "${scmd}"; then
            print_alias "${scmd}" "source"
        else
            print_alias "${scmd}" "default"
        fi
    done
}

main_generic()
{
    local scmd=$1
    shift

    local force='' epat='\$' pronly='' yes=''

    if dotcmd_p "${scmd}"; then
        pronly=yes
    fi

    while getopts "Ddfhpxy" opt; do
        case $opt in
            D)
                get_content_of_scmd "${scmd}"
                exit 0
                ;;
            d)
                get_content_of_scmd "${scmd}" | expand_vars
                exit 0
                ;;
            f)
                [[ ${scmd} != extract ]] && usage 1 "${scmd}"
                force=yes
                ;;
            h)
                usage 0 "${scmd}"
                ;;
            p)
                pronly=yes
                ;;
            x)
                epat='\$|\?'
                ;;
            y)
                yes=yes
                ;;
            \?)
                usage 1 "${scmd}"
                ;;
        esac
    done

    shift $((OPTIND - 1))

    if [[ $# -ne 0 ]]; then
        usage 1 "${scmd}"
    fi

    commands=$(get_content_of_scmd "${scmd}" \
                | expand_vars \
                | select_commands "${epat}")

    if [[ -z "${commands}" ]]; then
        exit 0
    fi

    if [[ ${pronly} ]]; then
        echo "${commands//${MARK}/}"
        exit 0
    fi

    if [[ ${scmd} == extract && -n "$(ls -A)" && ! ${force} ]]; then
        echo "Target directory is not empty."
        read -rp "Continue? [y/N] "
        if [[ ! ${REPLY} =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
            exit 0
        fi
    fi

    if [[ ${yes} ]]; then
        exec_commands "${commands}"
    else
        ask_exec_commands "${scmd}" "${commands}"
    fi
}

main()
{
    if [[ $# -eq 0 ]]; then
        usage 1
    fi

    local scmd="${1}" pat="\\<${1}\\>"

    if [[ ${scmd} != init && ! $(list_scmds) =~ ${pat} ]]; then
        usage 1
    fi

    if type "main_${scmd}" >/dev/null 2>&1; then
        shift
        "main_${scmd}" "$@"
    else
        main_generic "$@"
    fi
}

main "$@"
