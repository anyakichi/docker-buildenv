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

list_scmds() {
    ls "${CONFDIR}" | sed 's/\..*$//' | sort -u
}

get_content_of_scmd() {
    local file newline=""

    for file in "${CONFDIR}/${1}".*; do
        if [[ -n ${newline} ]]; then
            echo
        else
            newline="\n"
        fi
        cat "${file}"
    done
}

dotcmd_p() {
    local pat="\\<$1\\>"

    [[ ${DOTCMDS} =~ ${pat} ]]
}

# Expand the variables in a document and resolve its directives.  The document
# is compiled into a shell script that prints it, so that a directive becomes
# the control flow of the script:
#
#     text            ->  cat <<__BUILDENV_EXPAND_EOF__
#                         text
#                         __BUILDENV_EXPAND_EOF__
#     {% if EXPR %}   ->  if [[ EXPR ]]; then
#     {% elif EXPR %} ->  elif [[ EXPR ]]; then
#     {% else %}      ->  else
#     {% endif %}     ->  fi
#     {% include X %} ->  "${__BUILDENV__}" "X" -d
#
# A directive leaves nothing behind, hence it can be put anywhere, even in the
# middle of the continuation lines of a command.
#
# A "-" on either side of a directive, written right against the "{%" or the
# "%}", removes the blank lines that stand on that side, so that a document can
# be written with the blocks spaced out and still be printed tight.  It is
# resolved here as well, hence the blank lines are held until it is known
# whether the next line is a directive that takes them.
#
# An inclusion is a command of the script, so that the name of the document is
# expanded by the shell as everything else is, and buildenv itself expands the
# included document in turn.  Only an inclusion counts up the depth, which
# guards against a document that includes itself.
expand_vars() {
    if [[ ${__BUILDENV_DEPTH__:-0} -gt 16 ]]; then
        echo "buildenv: inclusion is too deep" >&2
        exit 1
    fi

    awk '
	# Escape a line so that the here-document expands the variables and the
	# command substitutions in it, and nothing else.
	#
	# What stands inside a command substitution is copied out as it is
	# written, because the shell parses it again as a command of its own:
	# a backslash there belongs to that command -- to sed, to printf -- and
	# one doubled here would reach it doubled.  The end of it is found by
	# counting the parentheses while stepping over the quotes, since a
	# parenthesis inside a quote is text and closes nothing.
	#
	# The count is kept between the lines, in cdepth and cquote, so that a
	# substitution written over several lines is copied out whole.  While it
	# stands open every line is one of it, hence a line that would otherwise
	# be a directive or be held as a blank one is text like the rest.
	function esc(s,   i, c, n, r) {
	    r = ""
	    n = length(s)
	    for (i = 1; i <= n; i++) {
	        c = substr(s, i, 1)
	        if (cdepth > 0) {
	            r = r c
	            if (cquote != "") {
	                if (c == cquote) {
	                    cquote = ""
	                } else if (c == "\\" && cquote != sq) {
	                    i++
	                    r = r substr(s, i, 1)
	                }
	            } else if (c == sq || c == "\"") {
	                cquote = c
	            } else if (c == "\\") {
	                i++
	                r = r substr(s, i, 1)
	            } else if (c == "(") {
	                cdepth++
	            } else if (c == ")") {
	                cdepth--
	            }
	        } else if (c == "$" && substr(s, i + 1, 1) == "(") {
	            r = r "$("
	            cdepth = 1
	            i++
	        } else if (c == "\\") {
	            if (substr(s, i + 1, 1) == "$") {
	                r = r "\\$"    # leave the dollar for the commands
	                i++
	            } else {
	                r = r "\\\\"
	            }
	        } else if (c == "`") {
	            r = r "\\`"
	        } else {
	            r = r c
	        }
	    }
	    return r
	}
	function text_on() {
	    if (!text) {
	        print "cat <<" delim
	        text = 1
	    }
	}
	function text_off() {
	    if (text) {
	        print delim
	        text = 0
	    }
	}
	function blank_p(s) {
	    return s ~ /^[ \t]*$/
	}
	# Print the blank lines held so far, now that they are not taken.
	function blanks_flush(   i) {
	    for (i = 1; i <= nblank; i++) {
	        text_on()
	        print esc(blanks[i])
	    }
	    nblank = 0
	}
	BEGIN {
	    # The delimiter must be a string that never appears in a document.
	    delim = "__BUILDENV_EXPAND_EOF__"
	    sq = sprintf("%c", 39)    # the awk program itself is single quoted
	}
	cdepth == 0 && /^[ \t]*\{%.*%\}[ \t]*$/ {
	    d = $0
	    lstrip = sub(/^[ \t]*\{%-[ \t]*/, "", d)
	    if (!lstrip) {
	        sub(/^[ \t]*\{%[ \t]*/, "", d)
	    }
	    rstrip = sub(/[ \t]*-%\}[ \t]*$/, "", d)
	    if (!rstrip) {
	        sub(/[ \t]*%\}[ \t]*$/, "", d)
	    }

	    if (lstrip) {
	        nblank = 0
	    } else {
	        blanks_flush()
	    }
	    skip = rstrip

	    text_off()

	    if (sub(/^if[ \t]+/, "", d)) {
	        print "if [[ " d " ]]; then"
	    } else if (sub(/^elif[ \t]+/, "", d)) {
	        print "elif [[ " d " ]]; then"
	    } else if (d == "else") {
	        print "else"
	    } else if (d == "endif") {
	        print "fi"
	    } else if (sub(/^include[ \t]+/, "", d)) {
	        print "__include__=\"" d "\""
	        print "__BUILDENV_DEPTH__=$(( ${__BUILDENV_DEPTH__:-0} + 1 ))" \
	              " \"${__BUILDENV__}\" \"${__include__}\" -d ||" \
	              " { echo \"buildenv: cannot include ${__include__}\" >&2;" \
	              " exit 1; }"
	    } else {
	        print "buildenv: unknown directive: " $0 | "cat >&2"
	        err = 1
	        exit 1
	    }
	    next
	}
	{
	    if (cdepth == 0 && blank_p($0)) {
	        if (!skip) {
	            blanks[++nblank] = $0
	        }
	        next
	    }

	    skip = 0
	    blanks_flush()
	    text_on()
	    print esc($0)
	}
	END {
	    if (!err) {
	        blanks_flush()
	        text_off()
	    }
	}
    ' | __BUILDENV__="$0" /bin/bash -u
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
# Every line is held until the next one is read, because a continuation line
# takes precedence over a trailing backslash.  A "> " line is held just as a
# command line is, so that it too joins the deeper-indented line that follows
# its trailing backslash instead of losing it.
select_commands() {
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
	function hold(s, c) {
	    cmd = s
	    first = c
	    held = 1
	}
	function emit() {    # leave the trailing backslash, if any, to bash
	    print (first ? mark cmd : cmd)
	    held = 0
	}
	BEGIN {
	    cpat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+[^ \t]"
	    ppat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+"
	    mark = ENVIRON["MARK"]
	}
	{
	    if (held) {
	        if (cont_p($0)) {
	            emit()
	            hold(cont_text($0), 0)
	            next
	        } else if (cmd ~ /\\$/) {
	            sub(/[ \t]*\\$/, "", cmd)
	            line = $0
	            sub(/^[ \t]*/, "", line)
	            cmd = cmd " " line
	            next
	        }
	        emit()
	    }

	    if ($0 ~ cpat) {
	        tstr = $0
	        sub(/[^ \t].*$/, "", tstr)    # the indentation of the prompt
	        tstr = tstr ">"
	        tlen = length(tstr)
	        line = $0
	        sub(ppat, "", line)
	        hold(line, 1)
	    }
	}
	END {
	    if (held) {
	        emit()
	    }
	}
    '
}

# The prompt of the interactive mode.  It is put in the generated script, since
# the commands share the state of one shell and cannot be run one by one.
#
# The answer is read from the terminal, not from the standard input, so that a
# command that reads the standard input does not eat it.  Where there is no
# terminal, the standard input is used after all, and the end of it is an error,
# not a quit, since the commands left unanswered are the ones left unexecuted:
# a run that answers nothing must not look like a run that succeeded.
ask_func() {
    cat <<'__BUILDENV_ASK__'
__buildenv_tty=/dev/stdin

if { : < /dev/tty; } 2>/dev/null; then
    __buildenv_tty=/dev/tty
fi

__buildenv_ask()
{
    local reply

    if [[ ${__buildenv_all:-} ]]; then
        printf '==> %s\n' "${1%%$'\n'*}" >&2
        return 0
    fi

    printf '%s\n' "$1" | sed -e '1s/^/  $ /' -e '1!s/^/  > /' >&2

    while :; do
        if ! read -r -p 'Execute? [Y/n/a/q/?] ' reply < "${__buildenv_tty}" \
           && [[ ! ${reply:-} ]]; then
            echo >&2
            echo "buildenv: no answer to read; the input has ended" >&2
            exit 1
        fi

        case ${reply:-y} in
            [Yy])
                return 0
                ;;
            [Nn])
                return 1
                ;;
            [Aa])
                __buildenv_all=yes
                return 0
                ;;
            [Qq])
                exit 0
                ;;
            *)
                echo "y: execute, n: skip, a: execute the rest, q: quit" >&2
                ;;
        esac
    done
}
__BUILDENV_ASK__
}

# Execute commands.  Errors are propagated by errexit rather than by appending
# "|| exit 1" to each command, because a command may span multiple lines.
#
# If the second argument is given, ask before each command.  A command is then
# wrapped in an if, whose condition is out of the reach of errexit, so that an
# unwanted command is skipped while a failing one still stops the execution.
exec_commands() {
    local input ask="${2:-}"

    [[ ${1+x} ]] && input="${1}" || input="$(cat -)"

    /bin/bash <(echo "${input}" |
        MARK="${MARK}" ASK="${ask}" ASK_FUNC="$(ask_func)" awk '
	# The separator is written as a bracket expression rather than as the
	# quote itself, because a one-character separator sends original-awk
	# down a path that breaks the string on a newline as well, and a
	# command held for the prompt is several lines joined by one.
	function shquote(s,   n, arr, i, r) {
	    n = split(s, arr, "[" q "]")
	    r = arr[1]
	    for (i = 2; i <= n; i++) {
	        r = r q "\\" q q arr[i]
	    }
	    return q r q
	}
	# A command is held until the next one, to show it whole in the prompt.
	function flush(   i, s) {
	    if (nheld == 0) {
	        return
	    }

	    if (ask) {
	        s = held[1]
	        for (i = 2; i <= nheld; i++) {
	            s = s "\n" held[i]
	        }
	        print "if __buildenv_ask " shquote(s) "; then"
	    } else {
	        print "echo " shquote("==> " held[1]) " >&2"
	    }

	    for (i = 1; i <= nheld; i++) {
	        print held[i]
	    }

	    if (ask) {
	        print "fi"
	    }

	    nheld = 0
	}
	BEGIN {
	    q = sprintf("%c", 39)
	    mark = ENVIRON["MARK"]
	    ask = ENVIRON["ASK"]
	    print "set -o errexit"
	    if (ask) {
	        print ENVIRON["ASK_FUNC"]
	    }
	}
	substr($0, 1, 1) == mark {
	    flush()
	    held[++nheld] = substr($0, 2)
	    next
	}
	{ held[++nheld] = $0 }    # continuation line
	END { flush() }
    ')
}

# Print commands as they are written in a document, with prompts.
print_commands() {
    sed -e "s/^${MARK}/  \$ /" -e t -e "s/^/  > /"
}

# Print a document as a manual.  The prompts and the continuation marks are
# removed, so that a command can be copied out of the text as it is; everything
# else is left as it is written.  A line is a continuation line here as well
# only when its ">" stands in the column of the prompt above, so that a quote
# in the text is left alone.
print_manual() {
    EPAT='\$|\?' awk '
	function cont_p(s) {
	    return open && tlen > 0 && substr(s, 1, tlen) == tstr &&
	           (length(s) == tlen || substr(s, tlen + 1, 1) == " ")
	}
	BEGIN {
	    cpat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+[^ \t]"
	    ppat = "^[ \t]*(" ENVIRON["EPAT"] ")[ \t]+"
	}
	{
	    if (cont_p($0)) {
	        prev = $0    # its trailing backslash keeps the command open too
	        print ind substr($0, tlen + 2)
	        next
	    }

	    line = $0

	    if ($0 ~ cpat) {
	        ind = $0
	        sub(/[^ \t].*$/, "", ind)    # the indentation of the prompt
	        tstr = ind ">"
	        tlen = length(tstr)
	        open = 1
	        sub(ppat, "", line)    # drop the indentation and the prompt
	        line = ind line
	    } else if (!(open && prev ~ /\\$/)) {
	        open = 0    # a trailing backslash keeps the command open
	    }

	    prev = $0
	    print line
	}
    '
}

ask_exec_commands() {
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

usage() {
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
            echo "usage: ${cmd} ${scmd} [-Ddfhimpxy]"
            ;;
        *)
            echo "usage: ${cmd} ${scmd} [-Ddhimpxy]"
            ;;
        esac
    fi

    exit "${status}"
}

print_alias() {
    local scmd="$1" type="${2:-}" pat="\\<${1}\\>"

    if [[ ${ALIASES} == 1 ]] ||
        ([[ ${ALIASES} == 2 ]] && ! type "${scmd}" >/dev/null 2>&1) ||
        [[ ${ALIASES} =~ ${pat} ]]; then
        if [[ ${type} == "source" ]]; then
            echo "alias ${scmd}='. <(${cmd} ${scmd})'"
        else
            echo "alias ${scmd}='${cmd} ${scmd}'"
        fi
    fi
}

main_init() {
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

main_generic() {
    local scmd=$1
    shift

    local force='' epat='\$' interactive='' pronly='' yes=''

    if dotcmd_p "${scmd}"; then
        pronly=yes
    fi

    while getopts "Ddfhimpxy" opt; do
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
        i)
            interactive=yes
            ;;
        m)
            get_content_of_scmd "${scmd}" | expand_vars | print_manual
            exit 0
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

    commands=$(get_content_of_scmd "${scmd}" |
        expand_vars |
        select_commands "${epat}")

    if [[ -z ${commands} ]]; then
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

    if [[ ${interactive} ]]; then
        exec_commands "${commands}" ask
    elif [[ ${yes} ]]; then
        exec_commands "${commands}"
    else
        ask_exec_commands "${scmd}" "${commands}"
    fi
}

main() {
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
