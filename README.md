# docker-buildenv

Tools for build environment on Docker.

You can build software on any Docker containers that include buildenv
(docker-buildenv), like:

```console
$ mkdir build
$ cd build
$ din anyakichi/yocto-builder
builder@build:/build$ extract
builder@build:/build$ setup
builder@build:/build$ build
```

din is the script included in this repository. You need to copy it
to a directory in PATH before using buildenv.

```console
$ curl -o ~/.local/bin/din \
    https://raw.githubusercontent.com/anyakichi/docker-buildenv/main/din.sh
```

extract, setup, and build are commands prepared by buildenv.

- **extract**: Download and extract source trees.
- **setup**: Setup build environment.
- **build**: Build software.

setup is of a different kind: a build environment is set up by
exporting variables, which a command run in a shell of its own cannot
do for the shell that called it. Its alias is therefore
`. <(buildenv setup)`, and buildenv only prints the commands, leaving
the calling shell to run them. DOTCMDS in /etc/buildenv.conf says which
commands are of this kind, and the images choose it.

A command shows what it is about to do and asks once, then runs it all.
With -i it asks for every command instead, so that you can follow the
manual step by step:

```console
builder@build:/build$ build -i
  $ cat > conf/auto.conf <<EOF
  > MACHINE = "qemux86-64"
  > EOF
Execute? [Y/n/a/q/?] y
  $ bitbake core-image-minimal
Execute? [Y/n/a/q/?] a
```

y executes the command, n skips it, a executes it and all that follow
without asking again, and q stops there. The commands share one shell,
so a command still sees what the commands before it have done.

The question is asked on the terminal, so a command that reads its
standard input gets that input and not the answers. Where there is no
terminal the answers are read from the standard input after all, one
line each, and running out of them is an error, not a quit.

There is nothing for -i or -y to execute in a command whose output is
sourced, and both are ignored there; -m still prints its manual.

Normally, extract is required only once, so you can use the container
after the second:

```console
$ cd build
$ din anyakichi/yocto-builder
builder@build:/build$ setup
builder@build:/build$ build
```

## Podman support

din uses Docker by default and falls back to Podman if Docker is not
available. You can also explicitly select the command to use with the
DIN_CMD environment variable:

```console
$ DIN_CMD=podman din anyakichi/yocto-builder
```

When using Podman, it is recommended to use btrfs as the storage driver
for better performance. If your home directory is on a btrfs
filesystem, set the driver in `~/.config/containers/storage.conf`:

```toml
[storage]
driver = "btrfs"
```

## The build cache

Nothing of a container survives it, so a compiler cache in one is a
cache thrown away. If `~/.cache/din` exists (`$XDG_CACHE_HOME` is
honoured), din mounts it at `/cache` and points CCACHE_DIR and
SCCACHE_DIR into it, and the builds of every directory share it. It is
not made for you; make it when you want it:

```console
$ mkdir -p ~/.cache/din
```

Without it there is nowhere for a cache to go, and din sets
CCACHE_DISABLE=1 rather than let ccache fill the container with one.

The directory used to be `~/.cache/buildenv`, which din wrote there and
not under `$XDG_CACHE_HOME`, so that is where the old one is looked for.
It is still used when it is the one that is there, and din says so once
each run; rename it to stop being told:

```console
$ mv ~/.cache/buildenv ~/.cache/din
```

## What din gives the container

Besides the current directory at `/build`, which is also the working
directory, and the cache above, din passes on what a build in the
container is likely to want from the host:

- the directory's name as the hostname, so that a prompt says which
  build it is in;
- TERM, http_proxy, https_proxy, ftp_proxy and no_proxy, those that are
  set;
- `BASH_ENV=/build/.bashrc`, so that a non-interactive bash in the
  container -- one run as `din <image> make`, say, or buildenv itself
  -- reads that file from the tree first, if the tree has one. The
  entrypoint drops privileges before any bash reads it.

The container's `-i` and `--rm` are always given, and `-t` when the
standard input is a terminal.

## Options for din

din gives docker the options a build needs, and the files of
`~/.config/din` say what to add to them (`$XDG_CONFIG_HOME` is honoured).
There is a file for each of the DIN_OPTS of the environment: `config` for
the options that apply to either command, `config_docker` and
`config_podman` for the ones only one of them takes.

A file is a list of options, one command line to a line:

```sh
# ~/.config/din/config
--network host
-v "${HOME}/.ssh:/home/builder/.ssh:ro"
```

```sh
# ~/.config/din/config_podman
--security-opt label=disable
```

A line is expanded by the shell you run din from, the way that shell
expands a command line: a variable is expanded as it is written, an
argument with a space in it is quoted as it would be anywhere else and
stays one argument, and a `#` begins a comment.

The added options come after the ones din itself gives and before the
image name, so one of them can replace what din chose, as both docker
and podman take the last of a repeated option:

```sh
# ~/.config/din/config
-h builder    # a hostname instead of the directory's name
```

### Options for one directory

The environment says the same thing in the same language, in DIN_OPTS,
DIN_DOCKER_OPTS and DIN_PODMAN_OPTS, and is read after the files, so that
what a directory sets has the last word:

```console
$ DIN_OPTS='-v "/opt/tool chain:/opt/toolchain:ro"' din anyakichi/yocto-builder
```

A variable holds as many lines as a file does, and a line means the same
in either place.

din itself reads nothing out of the tree it mounts, so there is no file
to put in a source tree, and nothing of a source tree runs on your host.
A directory that wants options of its own gets them the way it gets the
rest of its environment. With [direnv](https://direnv.net), that is an
`.envrc`:

```bash
# .envrc
export DIN_OPTS='-v /opt/toolchain:/opt/toolchain:ro --shm-size 2g'
```

## Developing and Building

docker-buildenv is just the environment for building, not editing. We
normally open two terminal windows or tabs, one is for docker-buildenv
and the other is for the host environment, and we edit source files in
the host environment, then switch to docker-buildenv and build software
over and over.

Build environment for a specific software often requires a specific OS
version, which is old and inconvenient. We can always use the latest
and customized version of a text editor and other development tools when
we develop with docker-buildenv.

## Executable manual

docker-buildenv is also for executable manual. Development manuals
usually include processes like:

1. Install a specific OS to your machine.
2. Install some packages.
3. Download and extract a source tree.
4. Execute build commands.

docker-buildenv assumes that 1. and 2. are in Dockerfile, 3. is in
/etc/buildenv.d/extract.txt and 4. is in /etc/buildenv.d/build.txt.

The extract command just filter the lines starts with prompt ($) from
extract.txt and simply execute it. So you can execute the manual if it
is put in the container.

### Multi-line commands

A command can span multiple lines. The lines that follow a command
line and start with "> " are its continuation lines; the text after the
"> " is taken as is. It is typically used to write a file with a
here-document:

```
$ cat > conf/site.conf <<'EOF'
> MACHINE = "${MY_MACHINE}"
>
> DL_DIR = "\${TOPDIR}/downloads"
> EOF
```

Anything the shell accepts works, not only here-documents:

```
$ for f in conf/*.sample; do
>     cp "\$f" "\${f%.sample}"
> done
```

The rules are:

- The ">" must stand in the column of the prompt it continues. A line
  indented more deeply is never a continuation line, so a command
  wrapped with backslashes is left to the shell as before, even if its
  lines start with a redirection or a pipe:

  ```
  $ printf '%s\n' one two three \
    | sort \
    > sorted.txt
  ```

- The mark is "> ", a greater-than sign and a space, just as the prompt
  is "$ ", so that a command is written as it is shown. The space is
  required: a line that begins with ">" but not with "> " is text, not
  a continuation line. The text right after the mark is used as is, so
  write an empty line as a line with only ">", and a line that itself
  starts with ">" as "> >...".
- A line is a continuation line only when it follows a command line or
  another continuation line, so a quote in the text is left alone.

buildenv expands variables in a document before the commands are
executed, in continuation lines too, and regardless of whether a
here-document delimiter is quoted. So ${MY_MACHINE} above is replaced
with the value in the container by buildenv. Escape a variable as
\${VAR} to leave it for the executed commands; then the ordinary shell
rules apply, that is, it is expanded on execution with an unquoted
delimiter and written to the file as is with a quoted one.

A command substitution, $(...), is run by buildenv at the same time,
and what stands inside it is left as it is written: the shell parses it
as a command of its own, so a backslash there belongs to that command
and is not to be escaped. A substitution can therefore write out the
commands themselves, prompts and all:

```
$(ls conf/*.sample | sed -E 's,(.*)\.sample,\$ cp \1.sample \1,')
```

Here \1 reaches sed as it is written, while \$ is the escape above,
which leaves a "$ " at the head of every line produced, so that each of
them becomes a command of the document.

A substitution may be written over several lines. While it is open,
every line of the document is a line of it, so a blank line or a line
that looks like a directive is left to the command too:

```
$(
    ls conf/*.sample |

    sed -E 's,(.*)\.sample,\$ cp \1.sample \1,'
)
```

Note that the commands are executed with errexit enabled, so the
execution stops on the first command that fails, including one inside
a loop.

### Optional commands

A command whose prompt is "?" instead of "$" is left out unless the
command is run with -x, so a manual can hold the steps that are not
for every build -- a clean, a fetch that is only needed once -- next to
the ones that are:

```
$ bitbake core-image-minimal
? bitbake -c cleansstate core-image-minimal
```

Everything else is the same for the two prompts: a "?" command is
continued with "> " lines as a "$" command is, and the manual of -m
drops the one prompt as it drops the other.

The prompts and the continuation marks are the notation of buildenv,
not of the shell, so `buildenv <command> -m` prints the document as a
manual with them removed, leaving the commands ready to be copied out
of the text. `-d` keeps them and prints the document as it is written
with the variables expanded.

### Conditions

A part of a document can be left out with a directive, which is a line
of its own and leaves nothing behind:

```
{% if "${CROSS_IMAGE}" %}
Extract the rootfs of ${CROSS_IMAGE} to build against it.

$ podman export \$id | tar -xf - -C sysroot
{% else %}
Nothing to extract; the build is native.
{% endif %}
```

`{% if %}`, `{% elif %}`, `{% else %}` and `{% endif %}` are available,
and they can be nested. The expression is passed to the test command of
the shell as it is written, so anything `[[ ]]` accepts works:

```
{% if "${CROSS_IMAGE}" == alpine* %}
{% if -z "${CROSS_CONTAINER:-}" %}
{% if $(distro) == debian %}
```

Since a directive leaves nothing behind, it can be put anywhere, even
between the continuation lines of a command:

```
$ cat > conf/auto.conf <<EOF
> MACHINE = "${MY_MACHINE}"
{% if "${MY_CCACHE_DIR}" %}
> INHERIT += "ccache"
{% endif %}
> EOF
```

Directives are resolved along with the variables, so every output but
`-D`, which prints a document as it is stored, is free of them. A line
that looks like a directive but is not one of the above is an error.

### Inclusion

A document can be included in another one:

```
{% include extract-sysroot-$(distro) %}
```

The name is expanded by the shell as everything else is, so it can be
chosen by a command or a variable. What is included is the document
expanded to the end, that is, its own variables, directives and
inclusions are all resolved before it is put in place. Every document
is therefore a unit of its own: an `{% if %}` cannot be closed by an
`{% endif %}` of another document.

Lines are what is included, so an included document can even continue
a command of the document that includes it:

```
$ cat > conf/auto.conf <<EOF
> MACHINE = "${MY_MACHINE}"
{% include auto-conf-extra %}
> EOF
```

A document that cannot be included, because there is no such document
or because it has an error in it, stops the whole command. So does a
document that includes itself, after a few rounds.

### Blank lines

A directive leaves nothing behind, but the blank lines around it are
text and are left as they are written. A block whose contents are
spaced out for the sake of the source is therefore printed with the
spacing in it:

```
Prepare the sources.

{% if "${CROSS_IMAGE}" %}

Extract the rootfs of ${CROSS_IMAGE} to build against it.

{% endif %}

Build the firmware.
```

A "-" written right against the "{%" or the "%}" removes the blank
lines on that side: `{%- if %}` removes the ones before the directive
and `{% if -%}` the ones after it. A "-" at the end of both the opening
and the closing directive therefore removes the spacing inside a block
and keeps the one blank line that separates it from the text around it,
whether the block is printed or not:

```
Prepare the sources.

{% if "${CROSS_IMAGE}" -%}

Extract the rootfs of ${CROSS_IMAGE} to build against it.

{% endif -%}

Build the firmware.
```

This prints one blank line between the paragraphs when CROSS_IMAGE is
empty, and the middle paragraph with a blank line on each side when it
is not. `{% elif %}` and `{% else %}` are marked the same way, so that
every branch is printed alike. The two sides are independent, so a
block can be tightened at one end only, or against the text around it
as well.

The marks work on an `{% include %}` as well, where they remove the
blank lines around the directive itself. They do not reach into the
included document, which is expanded as a unit of its own, so the blank
lines at the beginning and at the end of it are for that document to
write.

The rules are:

- The "-" must stand right against the "{%" or the "%}", so an
  expression that begins with a "-" is written as it is, as in
  `{% if -z "${CROSS_CONTAINER:-}" %}`, and one that ends with a "-" is
  written with a space before the "%}", as in
  `{% if "${MY_TAG}" == *- %}`.
- Only blank lines, that is lines that are empty or hold nothing but
  spaces and tabs, are removed. The indentation of a line and the
  spaces at the end of it are left alone.
- Every blank line on that side is removed, however many there are.

## Tests

`tests/run.sh` runs buildenv over documents written for the occasion and
compares the output and the exit status with what is expected. It needs
bash and awk, and setsid when it is run from a terminal, since the
interactive mode would otherwise ask the terminal rather than take the
answers the tests give it. It writes nothing outside its own temporary
directory:

```console
$ ./tests/run.sh
```

It prints a line for every test and exits non-zero if any of them failed.

## Examples

- <https://github.com/anyakichi/docker-yocto-builder>
- <https://github.com/anyakichi/docker-aosp-builder>
