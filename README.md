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

A command shows what it is about to do and asks once, then runs it all.
With -i it asks for every command instead, so that you can follow the
manual step by step:

```console
builder@build:/build$ setup -i
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

Note that the commands are executed with errexit enabled, so the
execution stops on the first command that fails, including one inside
a loop.

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

## Examples

- <https://github.com/anyakichi/docker-yocto-builder>
- <https://github.com/anyakichi/docker-aosp-builder>
