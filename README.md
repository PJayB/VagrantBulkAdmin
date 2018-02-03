# Usage

    vba [--no-color] <command> [additional command options...] [where <key> <operator> <value> [and <key2> <operator2> <value2>...]]

or,

    vba [--no-color] <command> [additional command options...] <name pattern>

## Available commands

> `status`
> 
> Prints the status of all registered Vagrants

> `refresh [--(no-provision)] [--(no-)destroy-on-error] [-y|--unattended]`
> 
> Reloads Vagrant configuration for existing Vagrants

> `add-missing [--(no-provision)] [--(no-)destroy-on-error] [-y|--unattended]`
> 
> Adds unregistered Vagrantfiles found in the working directory

> `ssh [-q|--no-summary] [-s|--sequential] [--shell=/bin/sh] [-i|--interactive]`
> 
> Remotely executes commands specified by stdin on each running Vagrant*

> `exec [-q|--no-summary] [-s|--sequential]`
> 
> Locally executes commands specified by stdin for each Vagrant*

> `list-[ids|directories|names]`
> 
> Lists all ids/directories/names

> `halt|provision|resume|suspend|reload [-q|--no-summary] [-s|--sequential] [Vagrant args...]`
> 
> These Vagrant commands are run on all running Vagrants*

> `up [-q|--no-summary] [-s|--sequential] [Vagrant args...]`
> 
> These Vagrant commands are run on all stopped Vagrants*

> `help`
> 
> Prints this help text

**NOTE**: If no command is specified, the default is `status`.

**NOTE**: Commands are only performed on Vagrants:
1) whose Vagrantfiles reside anywhere under the current working directory,
2) and matching the critera specified by `where`.

**NOTE**: Commands marked with a * are run in parallel by default. Use `--sequential` to force sequential execution.

## `where` usage

Available keys:

> `id`, `name`, `provider`, `state`, `directory`

Available operators:

> `is [-i|--insensitive] <value>`
> 
> Matches a string value exactly (with optional case insensitivity)

> `isnt [-i|--insensitive] <value>`
> 
> Inverse of 'is'

> `matches [-r|--regex] [-i|--insensitive] <glob/regex pattern>`
> 
> Matches a glob (or optionally regex) value (with optional case insensitivity)

> `doesntmatch [-r|--regex] [-i|--insensitive] <glob/regex pattern>`
> 
> Inverse of 'matches'

**NOTE**: simply using a name pattern instead of `where` is a shorthand for `where name matches <pattern>`.
For example, to bring up all boxes matching 'ubuntu*64':

    vba up ubuntu*64


# TODO
- explain where keys and conditions
- explain `--no-summary`
- explain `--sequential`
- explain piping to `exec` and `ssh`
- explain exec usage and environment variables
- explain SSH environment variables
- explain SSH `-i` (and environment variables)
