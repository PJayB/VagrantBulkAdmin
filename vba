#!/usr/bin/python
import subprocess
import tempfile
import argparse
import fnmatch
import json
import stat
import sys
import re
import os

class Condition:
    key = ''
    condition = None
    value = ''
    case_sensitive = True

def create_condition(k, ce, v, cs = True):
    c = Condition()
    c.key = k
    c.condition = ce
    c.value = v
    c.case_sensitive = cs
    return c

def pattern_match(pattern, value, match_case):
    flags = 0
    if not match_case:
        flags |= re.IGNORECASE
    return re.match(pattern, value, flags)

def condition_equal(x, y, match_case):
    if match_case:
        return x == y
    else:
        return x.lower() == y.lower()

def condition_notequal(x, y, match_case):
    return not condition_equal(x, y, match_case)

def condition_match_glob(x, y, match_case):
    # Replace naughty regex characters with slashed versions
    r = re.sub(r'([\-\[\]\/\{\}\(\)\+\.\\\^\$\|])', r'\\\1', y)
    # Replace * with .*
    r = r.replace("*", ".*")
    # Replace ? with .
    r = r.replace("?", ".")

    return pattern_match(r, x, match_case)

def condition_nomatch_glob(x, y, match_case):
    return not condition_match_glob(x, y, match_case)

def condition_match_regex(x, y, match_case):
    return pattern_match("%s" % y, x, match_case)

def condition_nomatch_regex(x, y, match_case):
    return not condition_match_regex(x, y, match_case)

conditionFuncs = {
    "is": condition_equal,
    "isnt": condition_notequal,
    "matches": condition_match_glob,
    "doesntmatch": condition_nomatch_glob,
}

global_conditions = []

# -----------------------------------------------------------------------------

class Printer:
    enable_color=True

    styleStack = []

    # colors
    defaultColor = '\033[39m'
    black = '\033[30m'
    red = '\033[31m'
    green = '\033[32m'
    yellow = '\033[33m'
    blue = '\033[34m'
    magenta = '\033[35m'
    cyan = '\033[36m'
    lightGray = '\033[37m'
    darkGray = '\033[90m'
    lightRed = '\033[91m'
    lightGreen = '\033[92m'
    lightYellow = '\033[93m'
    lightBlue = '\033[94m'
    lightMagenta = '\033[95m'
    lightCyan = '\033[96m'
    white = '\033[97m'

    # styles
    bold = '\033[1m'
    underlined = '\033[4m'
    noBold = '\033[21m'
    noUnderlined = '\033[24m'

    def raw(self, s):
        sys.stdout.write('%s' % s)
        return self

    def eol(self, clear=True):
        if clear:
            self.clear()
        sys.stdout.write('\n')
        sys.stdout.flush()
        return self

    def text(self, s):
        self.raw(s)
        return self

    def styleText(self, style, text):
        self.push(style)
        self.text(text)
        self.pop()
        return self

    def push(self, code):
        if self.enable_color:
            self.styleStack.append(code)
            self.raw(code)
        return self

    def pop(self):
        if self.enable_color:
            if len(self.styleStack) > 0:
                self.styleStack.pop()
            if len(self.styleStack) > 0:
                self.raw(self.styleStack[len(self.styleStack) - 1])
            else:
                self.clear()
        return self

    # NOTE resets color only!
    def clear(self):
        if self.enable_color:
            self.styleStack = []
            self.raw('\033[0m')
        return self

printer = Printer()

# -----------------------------------------------------------------------------

def table_state_format(v):
    statusColors = {
        'running': printer.lightGreen,
        'poweroff': printer.darkGray,
        'suspended': printer.darkGray
    }
    if v in statusColors:
        printer.styleText(statusColors[v], v)
    else:
        printer.text(v)

def table_returncode_format(v):
    if v == '0':
        printer.styleText(printer.green, 'succeeded')
    else:
        printer.styleText(printer.lightRed, 'failed')
    printer.text(' (%s)' % v)

table_formats = {
    'name': printer.yellow,
    'directory': printer.cyan,
}

table_custom_formatters = {
    'state': table_state_format,
    'returncode': table_returncode_format
}

def table_print_spaces(count):
    printer.text(' ' * (2 + count))

def table_print_heading(name, width):
    printer.styleText(printer.underlined + printer.white, name)
    table_print_spaces(width - len(name))

def table_get_iterator(l):
    if isinstance(l, dict):
        return l.itervalues()
    elif isinstance(l, list):
        return iter(l)
    else:
        fatal("Table is of unknown type")

def table_get_key_iterator(l):
    if isinstance(l, dict):
        return l.iterkeys()
    elif isinstance(l, list):
        return range(0, len(l))
    else:
        fatal("Table is of unknown type")

def table_print_value(field_name, value, width):
    if field_name in table_custom_formatters:
        table_custom_formatters[field_name](value)
    elif field_name in table_formats:
        printer.styleText(table_formats[field_name], value)
    else:
        printer.text(value)
    table_print_spaces(width - len(value))

def table_get_column_iterator(fields, columns):
    if not fields:
        return columns.iterkeys()
    else:
        return iter(fields)

# A table is a list of dictionaries
def print_table(table, fields=None, print_headings=True):
    def set_column_width(columns, heading, width):
        if heading in columns:
            columns[heading] = max(columns[heading], width)
        else:
            columns[heading] = width

    if len(table) == 0:
        print("No data.")
        return

    columns = {}
    for r in table_get_iterator(table):
        # Find headings and get their widths
        for heading in table_get_key_iterator(r):
            if not fields or heading in fields:
                if print_headings:
                    set_column_width(columns, heading, len('%s' % heading))
                set_column_width(columns, heading, len('%s' % r[heading]))

    if len(columns) == 0:
        print("No data.")
        return

    # Print the headings
    if print_headings:
        for h in table_get_column_iterator(fields, columns):
            table_print_heading('%s' % h, columns[h])
        printer.eol()

    # Print the values
    for r in table_get_iterator(table):
        for h in table_get_column_iterator(fields, columns):
            table_print_value('%s' % h, '%s' % r[h], columns[h])
        printer.eol()

# -----------------------------------------------------------------------------

def get_arg(i, name):
    if i >= len(sys.argv):
        print("Expected: %s" % name)
        usage(1)
    return sys.argv[i]

# -----------------------------------------------------------------------------

def next_arg_is(i, value):
    if i >= len(sys.argv):
        return False
    return sys.argv[i] == value

# -----------------------------------------------------------------------------

def next_arg_is_switch(i):
    if i >= len(sys.argv):
        return False
    return sys.argv[i].startswith('-')

# -----------------------------------------------------------------------------

def next_arg_is_of(i, values):
    if i >= len(sys.argv):
        return False
    return sys.argv[i] in values

# -----------------------------------------------------------------------------

def fatal(message):
    print(message)
    sys.exit(1)

# -----------------------------------------------------------------------------

# Get the boxes directory
def get_boxes_path():
    path = os.path.realpath(os.getcwd())
    if not os.path.exists(path) or not os.path.isdir(path):
        fatal("Can't find boxes folder at %s" % path)
    return path

# -----------------------------------------------------------------------------
# Evaluate the a condition
def evaluate_condition(c, value):
    return c.condition(value, c.value, c.case_sensitive)

# -----------------------------------------------------------------------------
# Checks the vagrant against the criteria
def matches_conditions(v, cs):
    for c in cs:
        if c.key in v:
            if not evaluate_condition(c, v[c.key]):
                return False
    return True

# -----------------------------------------------------------------------------
# Gets the headings from vagrant global-status
def get_vagrant_field_headings():
    # Get the vagrant statuses
    try:
        vagrantStatus = subprocess.check_output(["vagrant", "global-status"])
    except subprocess.CalledProcessError as err:
        fatal(err)

    # Ensure vagrant hasn't changed underneath us
    vagrantRecords = vagrantStatus.split('\n')
    if (len(vagrantRecords) == 0):
        fatal("Malformed response from vagrant global-status")

    return vagrantRecords[0].split()

# -----------------------------------------------------------------------------
# Returns the list of vagrants registered with vagrant without global conditions
def get_all_registered_vagrants(key = 'id', conditions = []):

    #
    # TODO: load metadata about the vagrants as well
    #

    # Get the vagrant statuses
    try:
        vagrantStatus = subprocess.check_output(["vagrant", "global-status"])
    except subprocess.CalledProcessError as err:
        fatal(err)

    # Get the vagrant boxes directory
    boxesPath = get_boxes_path()

    # Ensure vagrant hasn't changed underneath us
    vagrantRecords = vagrantStatus.split('\n')
    if (len(vagrantRecords) == 0):
        fatal("Malformed response from vagrant global-status")

    requiredHeadings = ['id', 'name', 'state', 'directory']
    vagrantHeadings = vagrantRecords[0].split()
    for heading in requiredHeadings:
        if not heading in vagrantHeadings:
            fatal("Malformed headings from vagrant global-status: missing %s" % heading)

    if key not in vagrantHeadings:
        fatal("Script requested sorting by '%s' but that key doesn't exist" % key)

    # Find all the registered vagrant IDs that exist in the directory
    vagrants = {}

    # Tokenize the string by newline so we can weed out what we don't want
    vagrantRegex = re.compile(r"^([0-9a-f]{7}).*(%s[^\\?%%:|\"<> ]+)" % boxesPath)
    for vr in vagrantRecords:
        if vagrantRegex.match(vr):
            tokens = vr.split()
            if len(tokens) == len(vagrantHeadings):
                v = {}
                for i in range(0, len(vagrantHeadings)):
                    v[vagrantHeadings[i]] = tokens[i]

                # Process conditions on this
                if matches_conditions(v, conditions):
                    vagrants[v[key]] = v
    return vagrants

# -----------------------------------------------------------------------------
# Get registered vagrants filtered by global_conditions *and* additional_conditions

def get_registered_vagrants(key = 'id', additional_conditions = []):
    return get_all_registered_vagrants(key, global_conditions + additional_conditions)

# -----------------------------------------------------------------------------
# Get *running* vagrants filtered by global_conditions *and* additional_conditions

def get_running_vagrants(key = 'id', additional_conditions = []):
    return get_registered_vagrants(additional_conditions = additional_conditions + [ create_condition('state', condition_equal, 'running') ])

# -----------------------------------------------------------------------------
# Print the status of registered vagrants

def status():
    vagrants = get_registered_vagrants()
    print_table(vagrants, ['name', 'id', 'state', 'directory'])

# -----------------------------------------------------------------------------
# Do a vagrant thing and return a Popen object

def vagrant_do(id, action, args=[], shell=False):
    cwd = None
    pargs = ["vagrant", action]
    for arg in args:
        pargs.append("%s" % arg)
    if not os.path.isdir(id):
        pargs.append("%s" % id)
    else:
        cwd = '%s' % id

    return subprocess.Popen(pargs, stdout=sys.stdout, stderr=sys.stderr, cwd=cwd, shell=shell)

# -----------------------------------------------------------------------------
# Do a vagrant thing

def vagrant_do_immediate(id, action, args=[], fatal_on_error=True, shell=False):
    p = vagrant_do(id, action, args, shell)
    p.wait()

    if p.returncode == 0:
        printer.push(printer.green)
    else:
        printer.push(printer.lightRed)
    printer.text("%s: '%s %s' exited with code '%d'" % (id, action, ' '.join(args), p.returncode)).eol()
    if p.returncode != 0:
        if fatal_on_error:
            sys.exit(p.returncode)
        else:
            return False

    return True

# -----------------------------------------------------------------------------
# Find unregistered vagrants and register them

def refresh_existing(args):
    # Parse the arguments
    force = False
    unattended = False
    vargs = []
    vagrant_switches = [ '--provision', '--no-provision', '--destroy-on-error', '--no-destroy-on-error']
    for a in args:
        if a == "--force" or a == "-f":
            force = True
        elif a == "-y" or a == "--unattended":
            unattended = True
        elif a in vagrant_switches:
            vargs.append(a)
        else:
            raise Exception("Unknown option: %s" % a)

    vagrants = get_registered_vagrants()

    if len(vagrants) == 0:
        print("No Vagrants registered.")
        return

    print("%d Vagrants will be refreshed:" % len(vagrants))
    for v in vagrants.itervalues():
        print("  %s (%s)" % (v['name'], v['directory']))

    if not unattended:
        try:
            raw_input("Press any key to begin, or Ctrl+C now to exit.")
        except KeyboardInterrupt:
            fatal("User aborted.")
        print("This may take some time...")

    oldCWD = os.getcwd()
    failures = []

    for v in vagrants.itervalues():
        if v['state'] == 'running':
            if force:
                if not vagrant_do_immediate(v['directory'], 'reload', fatal_on_error=False):
                    failures.append(v['directory'])
            else:
                print("Skipping running VM %s (use refresh -f to force)" % v['name'])
        else:
            if vagrant_do_immediate(v['directory'], 'up', vargs, fatal_on_error=False):
                vagrant_do_immediate(v['directory'], 'halt', fatal_on_error=False)
            else:
                failures.append(v['directory'])

    if len(failures) > 0:
        print("The following Vagrants failed to start:")
        for f in failures:
            print("  %s" % f)

    os.chdir(oldCWD)

# -----------------------------------------------------------------------------
# Find unregistered vagrants and register them

def register_missing(args):
    # Parse the arguments
    vargs = []
    unattended = False
    vagrant_switches = [ '--provision', '--no-provision', '--destroy-on-error', '--no-destroy-on-error']
    for a in args:
        if a in vagrant_switches:
            vargs.append(a)
        elif a == "-y" or a == "--unattended":
            unattended = True
        else:
            raise Exception("Unknown option: %s" % a)

    allVagrants = get_all_registered_vagrants('directory')

    # Scan the global conditions for anything that doesn't make sense
    for c in global_conditions:
        if c.key != "directory":
            fatal("Invalid key in where clause for add-missing: '%s' (only 'directory' can be used)" % c.key)

    oldCWD = os.getcwd()
    failures = []

    # Find Vagrant files 
    boxesPath = get_boxes_path()
    boxes = []
    for root, dirnames, filenames in os.walk(boxesPath):
        v = { 'directory' : root }
        if matches_conditions(v, global_conditions):
            for filename in fnmatch.filter(filenames, 'Vagrantfile'):
                boxes.append(os.path.join(root, filename))
    if len(boxes) == 0:
        fatal("Couldn't find any Vagrantfiles in %s" % boxesPath)

    boxesToAdd = []

    for file in boxes:
        path = os.path.dirname(file)
        if not path in allVagrants:
            boxesToAdd.append(path)

    if len(boxesToAdd) == 0:
        print("All boxes registered.")
        return

    print("Found %d unregistered boxes:" % len(boxesToAdd))
    for box in boxesToAdd:
        print("  %s" % box)

    if not unattended:
        try:
            raw_input("Press any key to begin, or Ctrl+C now to exit.")
        except KeyboardInterrupt:
            fatal("User aborted.")
        print("This may take some time...")

    for path in boxesToAdd:
        if vagrant_do_immediate(path, 'up', vargs, fatal_on_error=False):
            vagrant_do_immediate(path, 'halt', fatal_on_error=False)
        else:
            failures.append(path)

    if len(failures) > 0:
        print("The following Vagrants failed to start:")
        for f in failures:
            print("  %s" % f)

    os.chdir(oldCWD)

# -----------------------------------------------------------------------------
# List all the known vagrant details
def list_vagrants(key):
    vagrants = get_registered_vagrants(key)
    for v in vagrants.iterkeys():
        print(v)

# -----------------------------------------------------------------------------
# Default summary printer for a batch operation
vagrant_batch_default_summary_fields = ['name', 'id', 'returncode']

# -----------------------------------------------------------------------------
# Returns (commandArgs, summary_fields, sequential)
def vagrant_batch_initialize(switches, summary_fields=vagrant_batch_default_summary_fields):
    sequential = False
    commandArgs = []
    for s in switches:
        if s == "-q" or s == "--no-summary":
            summary_fields = None
        elif s == "-s" or s == "--sequential":
            sequential = True
        else:
            commandArgs.append(s)
    return (commandArgs, summary_fields, sequential)

# -----------------------------------------------------------------------------
def vagrant_batch_finalize(vagrants, results, summary_fields=vagrant_batch_default_summary_fields, wait_all=True):
    # Wait on the results
    if wait_all:
        for p in results.itervalues():
            p.wait()

    # Print the results
    if summary_fields:
        if len(vagrants) > 0 and len(results) > 0:
            summary = []
            for r in results.iterkeys():
                # Aggregate the fields
                record = {}
                for f in summary_fields:
                    if f == "returncode":
                        record[f] = results[r].returncode
                    elif f in vagrants[r]:
                        record[f] = vagrants[r][f]
                    else:
                        record[f] = '' # Unknown field
                summary.append(record)
            print_table(summary, summary_fields)
        else:
            print("No results.")

    # Exit with an appropriate code
    for r in results.itervalues():
        if r.returncode != 0:
            sys.exit(r.returncode)

# -----------------------------------------------------------------------------
# Runs a batch operation on a list of vagrants
def vagrant_batch_operation(vagrants, command, switches, key='id', summary_fields=vagrant_batch_default_summary_fields):
    # Get the quiet and sequential args if applicable
    commandArgs, summary_fields, sequential = vagrant_batch_initialize(switches, summary_fields)

    # Execute the operation on each vagrant
    results = {}
    for v in vagrants.itervalues():
        p = vagrant_do(v[key], command, commandArgs)
        if sequential:
            p.wait()
        results[v[key]] = p

    # Finalize
    vagrant_batch_finalize(vagrants, results, summary_fields)

# -----------------------------------------------------------------------------
# For each registered vagrant, do a thing

def for_each_vagrant(command, switches):
    vagrants = get_registered_vagrants()
    vagrant_batch_operation(vagrants, command, switches)

# -----------------------------------------------------------------------------
# For each registered *running* vagrant, do a thing

def for_each_running_vagrant(command, switches):
    vagrants = get_running_vagrants()
    vagrant_batch_operation(vagrants, command, switches)

# -----------------------------------------------------------------------------
# For each registered *not running* vagrant, do a thing

def for_each_not_running_vagrant(command, switches):
    vagrants = get_registered_vagrants(key='directory', additional_conditions = [ create_condition('state', condition_notequal, 'running') ])
    vagrant_batch_operation(vagrants, command, switches, key='directory', summary_fields=['directory', 'returncode'])

# -----------------------------------------------------------------------------

def vagrant_ssh(switches):
    vagrants = get_running_vagrants()
    if len(vagrants) == 0:
        fatal("No Vagrants to ssh into")

    shell_script=''
    shell_name=''
    interactive=False

    # Get the quiet and sequential args if applicable
    commandArgs, summary_fields, sequential = vagrant_batch_initialize(switches)
    for a in commandArgs:
        # split based on =
        try:
            k, v = a.split('=')
        except ValueError as e:
            k = a
            v = ''
            
        if k == "--shell":
            shell_name = v
        elif k == "--interactive" or k == "-i":
            interactive = True
        else:
            fatal("Unknown option '%s'" % k)

    if shell_name == '' and not interactive:
        shell_name="/bin/sh"
    elif shell_name != '' and interactive:
        fatal("ssh --shell not supported with --interactive")

    # If we're looking for interactivity, there can only be one vagrant
    if interactive:
        if len(vagrants) > 1:
            fatal("ssh --interactive is only available for a single Vagrant. Use 'where' to narrow the filter.")

        for v in vagrants.itervalues():
            # Print shell environment variables for convenience
            print("Vagrant information:")
            for key in v.iterkeys():
                print('  VAGRANT_%s="%s"' % (key.upper(), v[key]))

            # Execute the shell
            p = subprocess.Popen(
                ['vagrant', 'ssh', v['id']],
                shell=False,
                cwd=v['directory'])

        p.wait()
        sys.exit(p.returncode)

    # Read all of stdin. We'll be executing these commands in the vagrant folder of each vagrant.
    shell_script = sys.stdin.read()
    if not shell_script or shell_script.isspace():
        fatal("Empty command.")

    results = {}

    # Establish a connection to each host
    for v in vagrants.itervalues():
        # Execute the process
        p = subprocess.Popen(
            ['vagrant ssh %s -- %s' % (v['id'], shell_name)],
            stdin=subprocess.PIPE,
            stdout=sys.stdout,
            stderr=sys.stderr,
            shell=True,
            cwd=v['directory'])

        # Set shell environment variables
        for key in v.iterkeys():
            p.stdin.write('export VAGRANT_%s="%s"\n' % (key.upper(), v[key]))

        # Send the command string
        #p.communicate(input = shell_script)
        p.stdin.write(shell_script + "\n");
        p.stdin.flush()
        p.stdin.close()

        # Wait for completion (if specified)
        if sequential:
            p.wait()

        # Store this so we can print the results
        results[v['id']] = p

    # Print the results
    vagrant_batch_finalize(vagrants, results, summary_fields, wait_all=not sequential)

# -----------------------------------------------------------------------------

def vagrant_exec(switches):
    vagrants = get_registered_vagrants()

    # Get the quiet and sequential args if applicable
    commandArgs, summary_fields, sequential = vagrant_batch_initialize(switches)
    if len(commandArgs) > 0:
        fatal("invalid argument: %s" % commandArgs[0])

    # Read all of stdin. We'll be executing these commands in the vagrant folder of each vagrant.
    shell_script = sys.stdin.read()

    # Dump it to a script
    tmpFileHandle, tmpFileName = tempfile.mkstemp(text=True)
    os.write(tmpFileHandle, shell_script)
    os.close(tmpFileHandle)
    os.chmod(tmpFileName, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

    results = {}

    # Start a shell and set the path and environment variables
    for v in vagrants.itervalues():
        env = dict(os.environ)
        for key in v.iterkeys():
            env['VAGRANT_' + key.upper()] = v[key]

        p = subprocess.Popen(
            [tmpFileName],
            env=env,
            stdout=sys.stdout,
            stderr=sys.stderr,
            shell=True,
            cwd=v['directory'])
        if sequential:
            p.wait()
        results[v['id']] = p

    # Wait on the results
    if not sequential:
        for p in results.itervalues():
            p.wait()

    os.remove(tmpFileName)

    # Print the results
    vagrant_batch_finalize(vagrants, results, summary_fields, wait_all=False)

# -----------------------------------------------------------------------------

def usage(exitCode):
    print("Usage:")
    usageStyle = printer.white + printer.bold
    commandStyle = printer.lightYellow + printer.bold
    whereStyle = printer.lightCyan + printer.bold
    noteStyle = printer.darkGray
    printer.styleText(usageStyle, "    %s" % os.path.basename(sys.argv[0]))
    printer.text(" [--no-color] ")
    printer.styleText(commandStyle, "<command>")
    printer.text(" [additional command options...] [")
    printer.styleText(whereStyle, "where")
    printer.text(" <key> <operator> <value> [")
    printer.styleText(whereStyle, "and")
    printer.text(" <key2> <operator2> <value2>...]]").eol().eol()
    printer.text("Available ").styleText(commandStyle, "commands").text(":").eol()
    commands = []
    commands.append(['status', '', 'Prints the status of all registered Vagrants'])
    commands.append(['refresh', '[--(no-provision)] [--(no-)destroy-on-error] [-y|--unattended]', 'Reloads Vagrant configuration for existing Vagrants'])
    commands.append(['add-missing', '[--(no-provision)] [--(no-)destroy-on-error] [-y|--unattended]', 'Adds unregistered Vagrantfiles found in the working directory'])
    commands.append(['ssh', '[-q|--no-summary] [-s|--sequential] [--shell=/bin/sh] [-i|--interactive]', 'Remotely executes commands specified by stdin on each running Vagrant*'])
    commands.append(['exec', '[-q|--no-summary] [-s|--sequential]', 'Locally executes commands specified by stdin for each Vagrant*'])
    commands.append(['list-[ids|directories|names]', '', 'Lists all ids/directories/names'])
    commands.append(['halt|provision|resume|suspend|reload', '[-q|--no-summary] [-s|--sequential] [Vagrant args...]', 'These Vagrant commands are run on all running Vagrants*'])
    commands.append(['up', '[-q|--no-summary] [-s|--sequential] [Vagrant args...]', 'These Vagrant commands are run on all stopped Vagrants*'])
    commands.append(['help', '', 'Prints this help text'])
    for c in commands:
        printer.styleText(commandStyle, c[0]).styleText(usageStyle, ' %s' % c[1]).eol()
        printer.text('    %s' % c[2]).eol()

    printer.eol().styleText(noteStyle + printer.bold, "NOTE:")
    printer.push(noteStyle).text(" Commands are only performed on Vagrants:\n    1) whose Vagrantfiles reside anywhere under the current working directory,\n    2) and matching the critera specified by '").styleText(whereStyle, 'where').text("'.").eol().eol()

    printer.styleText(noteStyle + printer.bold, "NOTE:")
    printer.push(noteStyle).text(" Commands marked with a * are run in parallel by default. Use ").styleText(usageStyle, "--sequential").text(" to force sequential execution.").eol().eol()

    printer.styleText(whereStyle, "where").text(" usage:").eol()
    printer.text("Available keys:").eol().text('    ')
    headings = get_vagrant_field_headings()
    for i in range(0, len(headings)):
        if i != 0:
            printer.text(", ")
        printer.styleText(usageStyle, headings[i])
    printer.eol()
    printer.text("Available operators:").eol()
    condition_names = [
        ['is', '[-i|--insensitive] <value>', 'Matches a string value exactly (with optional case insensitivity)'],
        ['isnt', '[-i|--insensitive] <value>', 'Inverse of \'is\''],
        ['matches', '[-r|--regex] [-i|--insensitive] <glob/regex pattern>', 'Matches a glob (or optionally regex) value (with optional case insensitivity)'],
        ['doesntmatch', '[-r|--regex] [-i|--insensitive] <glob/regex pattern>', 'Inverse of \'matches\'']
    ]
    for c in condition_names:
        printer.styleText(whereStyle, '%s ' % c[0]).styleText(usageStyle, c[1]).eol()
        printer.text('    %s' % c[2]).eol()

    printer.eol().styleText(noteStyle + printer.bold, "NOTE:")
    printer.push(noteStyle).text(" simply using a name pattern instead of ").styleText(whereStyle, 'where').text(" is a shorthand for '").styleText(whereStyle, 'where name matches <pattern>').text("'.").eol()
    printer.push(noteStyle).text("For example, to bring up all boxes matching 'ubuntu*64':").eol().eol()
    printer.styleText(usageStyle, "    %s " % os.path.basename(sys.argv[0]))
    printer.styleText(commandStyle, "up")
    printer.text(" ")
    printer.styleText(whereStyle, "ubuntu*64")
    printer.eol().eol()

    # TODO: explain where keys and conditions
    # TODO: explain --no-summary
    # TODO: explain --sequential
    # TODO: explain exec usage and environment variables
    sys.exit(exitCode)

# -----------------------------------------------------------------------------
def usage_error(e):
    fatal(e)

# -----------------------------------------------------------------------------
#
# Now the real work begins...
#

# Validate command line
if len(sys.argv) < 2:
    usage(1)

# Get any switches
argCur = 1
go_to_help = False
while argCur < len(sys.argv) and next_arg_is_switch(argCur):
    a = get_arg(argCur, "option")
    if a == "--no-color":
        printer.enable_color = False
    elif a == "--help":
        go_to_help = True
    else:
        fatal("Unknown switch: %s" % a)
        usage(1)
    argCur = argCur + 1

if go_to_help:
    usage(0)
if argCur == len(sys.argv):
    usage(1)

command = sys.argv[argCur]
if command == '':
    usage_error("Command cannot be empty string")

class Options:
    case_sensitive = True,
    use_regex = False

def switch_insensitive(o):
    o.case_sensitive = False
def switch_regex(o):
    o.use_regex = True

condition_switches = {
    '-i': switch_insensitive,
    '--insensitive': switch_insensitive,
    '-r': switch_regex,
    '--regex': switch_regex
}

argCur = argCur + 1
endArgCur = argCur
while endArgCur < len(sys.argv) and next_arg_is_switch(endArgCur):
    endArgCur = endArgCur + 1

commandArgs = sys.argv[argCur:endArgCur]

# Determine whether or not we have a single or fully-qualified criteria
if len(sys.argv) == endArgCur + 1:
    # Simple 'where name matches' shorthand criteria
    c = Condition()
    c.key = "name"
    c.condition = conditionFuncs["matches"]
    c.value = get_arg(endArgCur, 'pattern')
    c.case_sensitive = True
    global_conditions.append(c)

# Determine what criteria we should be assessing
# Can compare to any field in a vagrant's status
# Chain together with 'and' ('or' must be done with separate invocations)
elif len(sys.argv) > endArgCur + 3:
    if sys.argv[endArgCur] != 'where':
        usage_error("Expected 'where'")
    if len(sys.argv) < endArgCur + 3:
        usage_error("Expected 'where' clauses")

    # Read the next three in the form "x is/isnt/matches/nomatches y"
    cur = endArgCur + 1
    while cur < len(sys.argv):
        key = get_arg(cur, 'where condition key')
        condition = get_arg(cur + 1, 'where condition clause')

        # Check for switches
        condition_options = Options()
        while next_arg_is_of(cur + 2, condition_switches):
            condition_switches[get_arg(cur + 2, 'condition option')](condition_options)
            cur += 1

        # Now get the value
        value = sys.argv[cur + 2]

        if not condition in conditionFuncs:
            usage_error("Unknown condition %s" % condition)

        c = Condition()
        c.key = key
        c.condition = conditionFuncs[condition]
        c.value = value
        c.case_sensitive = condition_options.case_sensitive
        global_conditions.append(c)

        # If we want the regex variant of the glob functions, process that
        if condition_options.use_regex:
            if c.condition == condition_match_glob:
                c.condition = condition_match_regex
            elif c.condition == condition_nomatch_glob:
                c.condition = condition_nomatch_regex
            else:
                fatal('%s: --regex cannot be applied to this operator' % condition)

        cur += 3

        # Swallow 'and'
        if cur < len(sys.argv) and sys.argv[cur] == "and":
            cur += 1

massRunningVagrantCommands = ["halt", "provision", "resume", "suspend", "reload"]
massHaltedVagrantCommands = ["up"]

listKeys = {
    "list-ids": "id",
    "list-paths": "directory",
    "list-directories" : "directory",
    "list-names" : "name"
}

# Execute the requested command
if command == "status":
    if len(commandArgs) > 0:
        usage_error("Unexpected: %s" % commandArgs[0])
    status()
elif command == "help":
    if len(commandArgs) > 0:
        usage_error("Unexpected: %s" % commandArgs[0])
    usage(0)
elif command == "refresh":
    refresh_existing(commandArgs)
elif command == "add-missing":
    register_missing(commandArgs)
elif command == "ssh":
    vagrant_ssh(commandArgs)
elif command == "exec":
    vagrant_exec(commandArgs)
elif command == "destroy":
    fatal("'destroy' not supported through this interface (yet). Use 'echo \"vagrant destroy\" | %s exec' instead." % os.path.basename(sys.argv[0]))
elif command in listKeys:
    if len(commandArgs) > 0:
        usage_error("Unexpected: %s" % commandArgs[0])
    list_vagrants(listKeys[command])
elif command in massRunningVagrantCommands:
    for_each_running_vagrant(command, commandArgs)
elif command in massHaltedVagrantCommands:
    for_each_not_running_vagrant(command, commandArgs)
else:
    fatal("Not sure how to '%s'" % command)
