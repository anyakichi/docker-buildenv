#!/bin/bash
#
# Tests for buildenv.sh.
#
# Each test writes a document into a CONFDIR of its own, runs buildenv over
# it, and compares the output and the exit status with what is expected.  The
# standard error is merged into the standard output, so that the diagnostics
# are tested as well.
#
# Nothing outside the temporary directory is touched: every run has its own
# CONFDIR and its own working directory, since the commands of a document are
# executed in the working directory.
#
# The tests read /etc/buildenv.conf if the host has one, because buildenv
# sources it before anything else can be said about it.
#
# The interactive mode asks the terminal when there is one, and the answers of
# these tests come over the standard input, so buildenv is run without a
# controlling terminal, which is what setsid does.  Where there is no setsid,
# buildenv is run as it is, which is right wherever the tests are not run from
# a terminal, as in CI.

set -o nounset

BUILDENV="$(cd "$(dirname "$0")/.." && pwd)/buildenv.sh"
CMD="$(basename "${BUILDENV}")"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/buildenv-tests.XXXXXX")"
trap 'rm -rf "${tmpdir}"' EXIT

ntests=0
nfailures=0
confdir=''
workdir=''
input=''
input_file=''
out=''
status=0

if command -v setsid >/dev/null 2>&1; then
    detached() { setsid -w "$@"; }
else
    detached() { "$@"; }
fi

# Write a document, read from the standard input, into a fresh CONFDIR.  The
# argument is the stem of the file, hence the name of the command, and
# defaults to "build".
doc() {
    confdir="$(mktemp -d "${tmpdir}/conf.XXXXXX")"
    workdir="$(mktemp -d "${tmpdir}/work.XXXXXX")"
    cat >"${confdir}/${1:-build}.txt"
}

# Write another document into the CONFDIR of the last doc, so that inclusion
# and commands made of several files can be tested.
doc_add() {
    cat >"${confdir}/${1}.txt"
}

# Set the answers of the interactive mode, one per argument, for the next run.
# Without an argument the input is empty, which is the end of it at once.
answer() {
    local a

    input=''
    for a; do
        input="${input}${a}"$'\n'
    done
}

# Set the answers as answer does, but hand them over as a file rather than a
# pipe, since a file is read differently: it has a position, and one opened
# again starts over.
answer_file() {
    answer "$@"
    input_file="${tmpdir}/answers"
    printf '%s' "${input}" >"${input_file}"
}

# Run buildenv over the last document.
run() {
    if [[ ${input_file} ]]; then
        out="$(cd "${workdir}" &&
            CONFDIR="${confdir}" detached "${BUILDENV}" "$@" \
                <"${input_file}" 2>&1)"
    else
        out="$(cd "${workdir}" && printf '%s' "${input}" |
            CONFDIR="${confdir}" detached "${BUILDENV}" "$@" 2>&1)"
    fi
    status=$?
    input=''
    input_file=''
}

fail() {
    nfailures=$((nfailures + 1))
    printf 'FAIL %d - %s\n' "${ntests}" "$1"
}

# Compare the last run with the status given and the output read from the
# standard input.  The trailing newlines are dropped from both sides, since
# the substitution that captures the output drops them anyway.
check() {
    local name="$1" want_status="$2" want

    want="$(cat)"
    ntests=$((ntests + 1))

    if [[ ${out} == "${want}" && ${status} -eq ${want_status} ]]; then
        printf 'ok %d - %s\n' "${ntests}" "${name}"
        return 0
    fi

    fail "${name}"
    if [[ ${status} -ne ${want_status} ]]; then
        printf '  status %s, want %s\n' "${status}" "${want_status}"
    fi
    if [[ ${out} != "${want}" ]]; then
        printf '  --- want ---\n%s\n  --- got ---\n%s\n  ---\n' \
            "${want}" "${out}"
    fi
}

# Compare the last run with the status given and a substring of the output,
# for the diagnostics whose wording is not ours to fix.
check_has() {
    local name="$1" want_status="$2" want="$3"

    ntests=$((ntests + 1))

    if [[ ${out} == *"${want}"* && ${status} -eq ${want_status} ]]; then
        printf 'ok %d - %s\n' "${ntests}" "${name}"
        return 0
    fi

    fail "${name}"
    printf '  status %s, want %s\n' "${status}" "${want_status}"
    printf '  --- want substring ---\n%s\n  --- got ---\n%s\n  ---\n' \
        "${want}" "${out}"
}

#
# Selecting the commands
#

doc <<'EOF'
  $ echo one
  $ echo two
EOF
run build -p
check 'plain commands' 0 <<'EOF'
echo one
echo two
EOF

doc <<'EOF'
Some text about what follows.

  $ echo one

More text, and a $ that is not a prompt.
EOF
run build -p
check 'only the prompts are commands' 0 <<'EOF'
echo one
EOF

doc <<'EOF'
  $ echo one \
        two
EOF
run build -p
check 'a trailing backslash joins the next line' 0 <<'EOF'
echo one two
EOF

doc <<'EOF'
  $ cat <<END
  > text
  > END
EOF
run build -p
check 'a "> " line continues the command' 0 <<'EOF'
cat <<END
text
END
EOF

doc <<'EOF'
  $ printf '%s\n' one
  >
  > three
EOF
run build -p
check 'a ">" alone continues with an empty line' 0 <<'EOF'
printf '%s\n' one

three
EOF

doc <<'EOF'
  $ echo start
  > printf '%s\n' a \
        b
  > echo tail
EOF
run build -p
check 'a backslash inside a block joins the next line' 0 <<'EOF'
echo start
printf '%s\n' a b
echo tail
EOF

doc <<'EOF'
  $ echo one
> this ">" is not in the column of the prompt
EOF
run build -p
check 'a ">" out of the column is text' 0 <<'EOF'
echo one
EOF

doc <<'EOF'
  $ echo one
  > two

  > three
EOF
run build -p
check 'a blank line ends the block' 0 <<'EOF'
echo one
two
EOF

doc <<'EOF'
  $ echo outer
      $ echo inner
      > cont
EOF
run build -p
check 'a prompt indented more deeply is a command of its own' 0 <<'EOF'
echo outer
echo inner
cont
EOF

doc <<'EOF'
  $ echo always
  ? echo optional
EOF
run build -p
check 'a "?" prompt is left out by default' 0 <<'EOF'
echo always
EOF

run build -x -p
check 'a "?" prompt is taken with -x' 0 <<'EOF'
echo always
echo optional
EOF

doc <<'EOF'
  ? echo optional
  > cont
EOF
run build -x -p
check 'a "?" prompt is continued as well' 0 <<'EOF'
echo optional
cont
EOF

#
# Printing the manual
#

doc <<'EOF'
Text above.

  $ echo one
  > two

Text below.
EOF
run build -m
check 'the manual keeps the text and drops the marks' 0 <<'EOF'
Text above.

  echo one
  two

Text below.
EOF

doc <<'EOF'
  $ echo start
  > printf '%s\n' a \
        b
  > echo tail
EOF
run build -m
check 'the manual keeps a block open over a backslash' 0 <<'EOF'
  echo start
  printf '%s\n' a \
        b
  echo tail
EOF

doc <<'EOF'
  ? echo optional
EOF
run build -m
check 'the manual drops the "?" prompt too' 0 <<'EOF'
  echo optional
EOF

doc <<'EOF'
The > in this line is text, not a continuation.
EOF
run build -m
check 'the manual leaves a ">" in the text alone' 0 <<'EOF'
The > in this line is text, not a continuation.
EOF

#
# Expanding the variables
#

export BUILDENV_TEST_VAR=value

doc <<'EOF'
The value is ${BUILDENV_TEST_VAR}.
EOF
run build -d
check 'a variable is expanded' 0 <<'EOF'
The value is value.
EOF

doc <<'EOF'
Today is $(echo now).
EOF
run build -d
check 'a command substitution is expanded' 0 <<'EOF'
Today is now.
EOF

doc <<'EOF'
  $ echo \${BUILDENV_TEST_VAR}
EOF
run build -d
check 'a backslash keeps the dollar for the command' 0 <<'EOF'
  $ echo ${BUILDENV_TEST_VAR}
EOF

doc <<'EOF'
A backslash \ and a backtick ` are left as they are.
EOF
run build -d
check 'a backslash and a backtick are left alone' 0 <<'EOF'
A backslash \ and a backtick ` are left as they are.
EOF

doc <<'EOF'
$(printf '%s\n' 'a b' | sed 's/\(a\) \(b\)/\2 \1/')
EOF
run build -d
check 'a backslash in a command substitution is left to the command' 0 <<'EOF'
b a
EOF

doc <<'EOF'
$(
    printf '%s\n' 'a b' |

    sed 's/\(a\) \(b\)/\2 \1/'
)
EOF
run build -d
check 'a command substitution can be written over several lines' 0 <<'EOF'
b a
EOF

doc <<'EOF'
$(cat <<'X'
{% if 1 == 1 %}
X
)
EOF
run build -d
check 'a directive inside a substitution is text, not a directive' 0 <<'EOF'
{% if 1 == 1 %}
EOF

doc <<'EOF'
$(echo '(') and a backslash \
still ends the line.
EOF
run build -d
check 'a parenthesis in a quote does not close a substitution' 0 <<'EOF'
( and a backslash \
still ends the line.
EOF

doc <<'EOF'
The raw document keeps ${BUILDENV_TEST_VAR} as it is written.
EOF
run build -D
check 'the raw document is not expanded' 0 <<'EOF'
The raw document keeps ${BUILDENV_TEST_VAR} as it is written.
EOF

doc <<'EOF'
{% if ${BUILDENV_TEST_VAR} == value %}
taken
{% else %}
not taken
{% endif %}
EOF
run build -d
check 'an if directive takes its branch' 0 <<'EOF'
taken
EOF

doc <<'EOF'
{% if ${BUILDENV_TEST_VAR} == other %}
first
{% elif ${BUILDENV_TEST_VAR} == value %}
second
{% else %}
third
{% endif %}
EOF
run build -d
check 'an elif directive takes its branch' 0 <<'EOF'
second
EOF

doc <<'EOF'
Head.

{%- if 1 == 1 -%}

Body.

{%- endif -%}

Tail.
EOF
run build -d
check 'a "-" removes the blank lines beside a directive' 0 <<'EOF'
Head.
Body.
Tail.
EOF

doc <<'EOF'
Head.

{% if 1 == 1 %}

Body.

{% endif %}

Tail.
EOF
run build -d
check 'without a "-" the blank lines are kept' 0 <<'EOF'
Head.


Body.


Tail.
EOF

doc <<'EOF'
Before.
{% include extra %}
After.
EOF
doc_add extra <<'EOF'
Included.
EOF
run build -d
check 'an include directive expands another document' 0 <<'EOF'
Before.
Included.
After.
EOF

doc <<'EOF'
  $ echo before
{% include extra %}
  $ echo after
EOF
doc_add extra <<'EOF'
  $ echo included
EOF
run build -p
check 'the commands of an included document are taken' 0 <<'EOF'
echo before
echo included
echo after
EOF

doc <<'EOF'
{% include nosuch %}
EOF
run build -d
check_has 'an include of a missing document fails' 1 \
    'buildenv: cannot include nosuch'

doc <<'EOF'
{% include build %}
EOF
run build -d
check_has 'a document that includes itself is stopped' 1 \
    'buildenv: inclusion is too deep'

doc <<'EOF'
{% frobnicate %}
EOF
run build -d
check 'an unknown directive is an error' 1 <<'EOF'
buildenv: unknown directive: {% frobnicate %}
EOF

doc <<'EOF'
The value is ${BUILDENV_TEST_UNSET}.
EOF
run build -d
check_has 'an unset variable is an error' 1 'unbound variable'

#
# Executing the commands
#

doc <<'EOF'
  $ echo one
  $ echo two
EOF
run build -y
check 'the commands are executed in order' 0 <<'EOF'
==> echo one
one
==> echo two
two
EOF

doc <<'EOF'
  $ shared=x
  $ echo \${shared}
EOF
run build -y
check 'the commands share one shell' 0 <<'EOF'
==> shared=x
==> echo ${shared}
x
EOF

doc <<'EOF'
  $ printf '%s\n' one \
        two
  > printf '%s\n' three
EOF
run build -y
check 'a command of several lines is executed as one' 0 <<'EOF'
==> printf '%s\n' one two
one
two
three
EOF

doc <<'EOF'
  $ false
  $ echo unreachable
EOF
run build -y
check 'a failing command stops the run' 1 <<'EOF'
==> false
EOF

doc <<'EOF'
Nothing to do here, only text.
EOF
run build -y
check 'a document without a command does nothing' 0 <<'EOF'
EOF

#
# The interactive mode
#

doc <<'EOF'
  $ echo one
  $ echo two
EOF
answer y n
run build -i
check 'y executes and n skips' 0 <<'EOF'
  $ echo one
one
  $ echo two
EOF

answer '' ''
run build -i
check 'an empty answer is a yes' 0 <<'EOF'
  $ echo one
one
  $ echo two
two
EOF

answer n a
run build -i
check 'a executes the rest without asking' 0 <<'EOF'
  $ echo one
  $ echo two
two
EOF

answer q
run build -i
check 'q stops the run' 0 <<'EOF'
  $ echo one
EOF

answer z y y
run build -i
check 'an answer that is not understood asks again' 0 <<'EOF'
  $ echo one
y: execute, n: skip, a: execute the rest, q: quit
one
  $ echo two
two
EOF

answer
run build -i
check 'the end of the input is an error, not a quit' 1 <<'EOF'
  $ echo one

buildenv: no answer to read; the input has ended
EOF

input='y'
run build -i
check 'an answer without a newline at the end is read' 1 <<'EOF'
  $ echo one
one
  $ echo two

buildenv: no answer to read; the input has ended
EOF

answer_file n y
run build -i
check 'the answers are read on from a file, not its first line over again' 0 <<'EOF'
  $ echo one
  $ echo two
two
EOF

doc <<'EOF'
  $ cat > /dev/null

  $ echo after
EOF
answer y y
run build -i
check 'a command that eats the answers does not pass for a success' 1 <<'EOF'
  $ cat > /dev/null
  $ echo after

buildenv: no answer to read; the input has ended
EOF

doc <<'EOF'
  $ printf '%s\n' one \
        two
  > printf '%s\n' three
EOF
answer y
run build -i
check 'the whole command is shown before it is asked for' 0 <<'EOF'
  $ printf '%s\n' one two
  > printf '%s\n' three
one
two
three
EOF

#
# The command line
#

doc build.1 <<'EOF'
  $ echo one
EOF
doc_add build.2 <<'EOF'
  $ echo two
EOF
run build -p
check 'the files of one command are read together' 0 <<'EOF'
echo one
echo two
EOF

doc build <<'EOF'
  $ echo one
EOF
doc_add extract <<'EOF'
  $ echo two
EOF

run build -h
check 'the usage of a command is printed with -h' 0 <<EOF
usage: ${CMD} build [-Ddhimpxy]
EOF

run extract -h
check 'the usage of extract holds -f' 0 <<EOF
usage: ${CMD} extract [-Ddfhimpxy]
EOF

# getopts names the script as it was invoked, which is the path we run.
run build -Z
check 'an unknown option is an error' 1 <<EOF
${BUILDENV}: illegal option -- Z
usage: ${CMD} build [-Ddhimpxy]
EOF

run build extra-argument
check 'an argument that is not an option is an error' 1 <<EOF
usage: ${CMD} build [-Ddhimpxy]
EOF

run nosuch
check 'a command that is not in the CONFDIR is an error' 1 <<EOF
usage: ${CMD} init
       ${CMD} build [args]
       ${CMD} extract [args]
EOF

run
check 'without a command the usage is printed' 1 <<EOF
usage: ${CMD} init
       ${CMD} build [args]
       ${CMD} extract [args]
EOF

run init
check 'init prints the aliases' 0 <<EOF
alias build='${CMD} build'
alias extract='${CMD} extract'
EOF

doc extract <<'EOF'
  $ echo extracting
EOF
run extract -y
check 'extract runs in an empty directory' 0 <<'EOF'
==> echo extracting
extracting
EOF

doc extract <<'EOF'
  $ echo extracting
EOF
: >"${workdir}/in-the-way"
answer n
run extract -y
# The prompt of "read -p" is written only to a terminal, and the tests give
# the answers over a pipe, so what is asked is not in the output; that nothing
# was executed is what this tests.
check 'extract asks before it runs in a directory that is not empty' 0 <<'EOF'
Target directory is not empty.
EOF

doc extract <<'EOF'
  $ echo extracting
EOF
: >"${workdir}/in-the-way"
run extract -f -y
check 'extract does not ask with -f' 0 <<'EOF'
==> echo extracting
extracting
EOF

doc <<'EOF'
  $ echo one
EOF
run build -f
check 'a command that is not extract has no -f' 1 <<EOF
usage: ${CMD} build [-Ddhimpxy]
EOF

#
# Asking once
#

doc <<'EOF'
  $ printf '%s\n' one
  > printf '%s\n' two
EOF
answer y
run build
check 'the commands are shown and asked for once' 0 <<'EOF'
Build commands:

  $ printf '%s\n' one
  > printf '%s\n' two

==> printf '%s\n' one
one
two
EOF

answer n
run build
check 'nothing is executed when the answer is no' 0 <<'EOF'
Build commands:

  $ printf '%s\n' one
  > printf '%s\n' two
EOF

printf '\n'
if [[ ${nfailures} -eq 0 ]]; then
    printf 'all %d tests passed\n' "${ntests}"
    exit 0
fi

printf '%d of %d tests failed\n' "${nfailures}" "${ntests}"
exit 1
