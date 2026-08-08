# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Four standalone shell scripts, no build step. `buildenv.sh` is the whole
program; `din.sh`, `entrypoint.sh` and `buildenv.conf` are what carries it
into a container.

- `buildenv.sh` — installed as `buildenv` inside a builder image. Reads
  *documents* from `/etc/buildenv.d/` and executes the commands in them.
  bash on purpose, unlike the two below: the image is the consumer's to
  build and can be told to have a bash, and the documents are written for
  one — a `{% if %}` condition is a `[[ ]]`. Making it POSIX, or letting the
  image name the shell the documents run under, was weighed and dropped;
  that shell could only be a worse one than the image already has.
- `din.sh` — copied to the host's PATH as `din`. Runs a container with the
  current directory bind-mounted at `/build`. POSIX sh, since it runs on
  whatever host the builder is driven from. What to add to the options it
  gives docker comes from the files of `~/.config/din` (`config`,
  `config_docker`, `config_podman`) and from the `DIN_OPTS` family in the
  environment, a line of either being expanded as a command line; it reads
  nothing out of the mounted tree, on purpose, so nothing of a source tree
  runs on the host.
- `entrypoint.sh` — the image's entrypoint. POSIX sh, since it runs on
  whatever shell the image has. Aligns the builder user's uid/gid with the
  owner of the mounted directory, then drops privileges via
  gosu/setpriv/sudo.
- `buildenv.conf` — sourced from `/etc/buildenv.conf`; documents `ALIASES`
  and `DOTCMDS`.

Consumers are separate repositories (docker-yocto-builder,
docker-aosp-builder) that provide the Dockerfile and the documents.

## Commands

```console
$ ./tests/run.sh                  # the whole suite; prints ok/FAIL per test
$ shfmt -i 4 -s -d buildenv.sh din.sh entrypoint.sh tests/run.sh
$ shellcheck -S warning buildenv.sh din.sh entrypoint.sh tests/run.sh
```

There is no way to run a single test; the suite is a flat script and is fast.
To work on one case, comment out the rest or copy the `doc`/`run`/`check`
block into a scratch script. CI (`.github/workflows/tests.yml`) runs the
three above, the tests once per awk implementation.

## The pipeline

`main_generic` is the spine. Every subcommand is the same pipeline, and the
options only choose where to stop:

```
get_content_of_scmd   read /etc/buildenv.d/<scmd>.* in order   -D stops here
  -> expand_vars      variables, directives, inclusions        -d stops here
  -> select_commands  keep the prompt lines                    -m, -p stop here
  -> exec_commands    run them                                 -y, -i, default
```

`-m` (manual) branches off after `expand_vars` and runs `print_manual`
instead, which strips prompts and continuation marks but keeps the prose.

Subcommand names are not hardcoded: `list_scmds` derives them from the
filenames in `CONFDIR`, so `extract`, `setup` and `build` are conventions of
the images, not of this script. A subcommand gets a dedicated `main_<name>`
function only when it needs one (`main_init`); everything else falls through
to `main_generic`. `-f` is accepted for `extract` only, because only extract
guards against a non-empty working directory.

## Two ideas worth knowing before editing

**expand_vars compiles the document into a shell script that prints it.**
Prose becomes `cat <<__BUILDENV_EXPAND_EOF__` blocks and `{% if %}` becomes
real `if [[ ]]`, so the shell does the expansion and the branching. This is
why anything `[[ ]]` accepts works in a condition, why an unset variable is a
hard error (`bash -u`), and why an `{% include %}` is a recursive call to
`"${__BUILDENV__}" <name> -d` guarded by `__BUILDENV_DEPTH__`.

**MARK (`$'\001'`) is the seam between the awk stages.** `select_commands`
prefixes command lines with it and leaves continuation lines bare;
`exec_commands` and `print_commands` read that back. A continuation line is
one whose `>` stands in the *same column* as the prompt it continues — the
indentation is the syntax, which is what lets a deeper-indented line stay a
line of the shell (a wrapped pipeline) rather than of buildenv.

## awk portability

The awk in `buildenv.sh` runs inside whatever container the software is built
in: mawk on Debian/Ubuntu, busybox awk on Alpine, gawk or original-awk
elsewhere. Write to the common subset — no gawk extensions (`gensub`,
`length(array)`, `RS` as a regex, `\s`), no `--` long options. CI runs the
tests against all four; a construct only one implementation takes will fail
there.

## Conventions

- Commit subjects are `<area>: <Imperative sentence>` with the area being the
  script or topic touched (`buildenv:`, `din:`, `tests:`, `ci:`, `README:`).
- Comments are prose in full sentences, placed above a function to explain
  *why* the thing is shaped that way. Match that register; the file has a
  deliberate voice.
- New behaviour in `buildenv.sh` needs a case in `tests/run.sh` (a `doc`
  heredoc, a `run`, and a `check` with the expected output and status) and a
  section in `README.md`. The suite runs documents through `buildenv.sh` and
  has nothing for the other scripts; a change to `din.sh` gets its section in
  `README.md` and is tried by hand against a `docker` on PATH that only
  prints its arguments.
