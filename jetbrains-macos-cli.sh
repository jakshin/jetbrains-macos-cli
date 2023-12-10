#!/bin/bash
# Command-line interface for IntelliJ IDEA and various other JetBrains IDEs on macOS.
# jetbrains-macos-cli

ide_app="/Applications/IntelliJ IDEA.app"
ide_binary="idea"
ide_name="IntelliJ IDEA"

if [[ -n $JETBRAINS_CLI_TEST_MODE ]]; then
	echo="echo"
else
	echo=""
fi

if [[ -z $NO_COLOR ]]; then
	bright='\033[0;1m'
	plain='\033[0m'
	light_red='\033[1;31m'
	dark_red='\033[0;31m'
	dim='\033[38;5;240m'
else
	bright=''
	plain=''
	light_red=''
	dark_red=''
	dim=''
fi

# This script's name (or symlink's name, if the script was launched via symlink)
script_name="$(basename "$0")"

# Shows usage info
# See https://www.jetbrains.com/help/idea/working-with-the-ide-features-from-command-line.html
function usage() {
	use "$script_name" \
		"Launch the IDE as though via its icon (restoring previously open projects, etc.)
		Options: nosplash, dontReopenProjects, disableNonBundledPlugins"

	use "$script_name <file-or-dir ...>" \
		"Open arbitrary files and/or directories in the IDE. If you open a directory that's
		not in a project, the IDE will add a .idea directory to it, making it a project.
		Options: nosplash, disableNonBundledPlugins"

	use "$script_name --wait <file-or-dir>" \
		"Open a file or directory, and wait for it to be closed.
		Options: nosplash, disableNonBundledPlugins"

	use "$script_name diff <file1> <file2> [file3]" \
		"Open the diff viewer to compare two or three files."

	use "$script_name merge <file1> <file2> [common-base-file] <output-file>" \
		"Open the Merge dialog to perform a three-way or two-way merge."

	use "$script_name format <file-or-dir ...>" \
		"Format the given files and/or the files in the given directories, optionally recursively.
		By default, files are formatted with the project's settings; override with -s/-settings.
		Files outside a project are skipped unless -s/-settings or -allowDefaults is passed.
		Options: -m|-mask masks, -r|-R, -s|-settings file.xml, -allowDefaults, -charset set, -d|-dry"
	
	use "$script_name inspect <project-dir> <inspection-profile-xml-file> <output-dir>" \
		"Run all the configured inspections for a project, and store the results in a file.
		Options: -changes, -d subdir, -format xml|json|plain, -v0|-v1|-v2 (verbosity)"

	use "$script_name installPlugins <plugin-id ...> [repository-url ...]" \
		"Install plugins, by default from the JetBrains Marketplace (https://plugins.jetbrains.com)."

	if man -S1 -w "$script_name" &> /dev/null; then
		echo -e $'\n'"${bright}Run 'man ${script_name}' for full usage details${plain}"
	fi
}

# Helper function for usage()
function use() {
	local form=$1; shift
	local description=$1; shift

	echo -e "\n${bright}${form}${plain}"

	local lines line indent="    "
	if [[ -n $description ]]; then
		# shellcheck disable=SC2206
		IFS=$'\n' lines=($description)

		for line in "${lines[@]}"; do
			line="${line#"${line%%[![:space:]]*}"}"  # Remove leading whitespace
			echo "${indent}${line}"
		done
	fi

	# Show any options
	if (( ${#@} > 0 )); then
		echo

		local opt i=0
		for opt; do
			(( i++ ))
			if (( i % 2 )); then
				echo -e "${indent}${bright}${opt}${plain}"
			else
				# shellcheck disable=SC2206
				IFS=$'\n' lines=($opt)

				for line in "${lines[@]}"; do
					line="${line#"${line%%[![:space:]]*}"}"  # Remove leading whitespace
					echo "${indent}${indent}${line}"
				done
			fi
		done
	fi
}

# Shows an error message on stderr, and exits the script
function error() {
	echo -e "${light_red}Error: ${dark_red}$*${plain}" >&2
	if man -S1 -w "$script_name" &> /dev/null; then
		echo "Run '$script_name --help' for usage info, or 'man $script_name' for full details" >&2
	else
		echo "Run '$script_name --help' for usage info" >&2
	fi

	exit 1
}

# Errors unless all passed files/directories exist
# Symlinks to existing files/directories are allowed (the IDE will resolve them)
function error_unless_all_exist() {
	local allow=$1  # Pass one of: File, Directory, Path
	shift

	local arg=""
	for arg in "$@"; do
		if [[ ! -e $arg ]]; then
			if [[ -L $arg ]]; then
				error "Broken symlink: $arg"
			else
				error "$allow does not exist: $arg"
			fi
		elif [[ $allow == File ]]; then
			if [[ ! -f $arg ]]; then
				if [[ -L $arg ]]; then
					error "Symlink doesn't resolve to a regular file: $arg"
				else
					error "Not a regular file: $arg"
				fi
			fi
		elif [[ $allow == Directory ]]; then
			if [[ ! -d $arg ]]; then
				if [[ -L $arg ]]; then
					error "Symlink doesn't resolve to a directory: $arg"
				else
					error "Not a directory: $arg"
				fi
			fi
		elif [[ ! -f $arg && ! -d $arg ]]; then
			if [[ -L $arg ]]; then
				error "Symlink doesn't resolve to a regular file or directory: $arg"
			else
				error "Not a regular file or directory: $arg"
			fi
		fi
	done
}

# Errors if the IDE is already running
function error_if_running() {
	local command=$1  # e.g. format

	# shellcheck disable=SC2009  # pgrep can't match complete binary paths without also matching their arguments
	if ps -x -o comm= | grep -q "/${ide_name}[^/]*\.app"; then
		error "The $command command won't work right if $ide_name is already running"
	fi
}

# Launches the IDE via its MacOS binary (useful for some commands, not so much for others)
function exec_ide_binary() {
	local binary=""
	binary="$(cd "$ide_app/Contents/MacOS" &> /dev/null && echo *)"

	if [[ -z $binary || $binary == *" "* ]]; then
		binary=$ide_binary
	fi

	binary="$ide_app/Contents/MacOS/$binary"
	if [[ ! -f $binary || ! -x $binary ]]; then
		binary=""
	fi

	if [[ -z $binary ]]; then
		error "Unable to launch $ide_app: Can't find the right binary in its MacOS directory"
	fi

	$echo exec "$ide_app/Contents/MacOS/$binary" "$@"
	exit  # Only reached in test mode
}

# Basic command-line parsing, just handling --wait and the weird no-dash global options
specials=" --nosplash --dontReopenProjects --disableNonBundledPlugins "
commands=" diff merge format inspect installPlugins "

wait=false
open_opts=()
special_opts=()
args=()
command=""

for arg; do
	if [[ $arg == --help || $arg == -help || $arg == -h ]]; then
		echo -e "${bright}${ide_name} launcher${plain}"
		echo -e "${dim}$ide_app${plain}"
		usage
		exit 0

	elif [[ $arg == --wait || $arg == -wait || $arg == -w ]]; then
		wait=true
		open_opts+=(-W)  # We need to pass an option to the "open" command too
		special_opts+=(--wait)

	elif [[ $specials == *" $arg "* || $specials == *" -$arg "* || $specials == *" --$arg "* ]]; then
		special_opts+=("${arg//-}")

	else
		args+=("$arg")
	fi
done

# Ensure the IDE this script was created for still exists
if [[ ! -e $ide_app ]]; then
	echo -e "${light_red}Error: ${dark_red}IDE app not found: ${ide_app}${plain}" >&2
	echo "Please re-run setup.sh" >&2
	exit 1
fi

# Do the things, depending on what arguments/options were passed...
# No arguments, just launch (with any special options)
if [[ ${#args[@]} == 0 ]]; then
	if [[ $wait == true ]]; then
		error "You must pass a file or project directory with the --wait option"
	fi

# First argument is a command
elif [[ $commands == *" ${args[0]} "* ]]; then
	command=${args[0]}

	if [[ $wait == true ]]; then
		error "You cannot use the --wait option with the $command command"
	fi

	if [[ $command == diff ]]; then
		# Open the diff viewer to compare two or three files from the command line
		# https://www.jetbrains.com/help/idea/command-line-differences-viewer.html#d1a81073

		# We need 2 or 3 files; no options are allowed here
		if [[ ${#args[@]} != 3 && ${#args[@]} != 4 ]]; then
			error "You must pass the paths/names of 2 or 3 files to compare"
		else
			error_unless_all_exist File "${args[@]:1}"
		fi

	elif [[ $command == merge ]]; then
		# Open the Merge dialog to perform a three-way or a two-way merge from the command line
		# https://www.jetbrains.com/help/idea/command-line-merge-tool.html#macos

		# We need 3 or 4 files; no options are allowed here
		if [[ ${#args[@]} != 4 && ${#args[@]} != 5 ]]; then
			error "You must pass the paths/names of 2 versions of a file to merge," $'\n'\
				"optionally the base revision (a common origin of both modified versions)," $'\n'\
				"and then the output file to save merged results into."
		else
			error_unless_all_exist File "${args[@]:1}"
		fi

	elif [[ $command == format ]]; then
		# https://www.jetbrains.com/help/idea/command-line-formatter.html#9f540e09
		# If you pass a mask, only files that match it will be formatted,
		# even if you explicitly pass a non-matching file on the command line;
		# we don't check for that condition in this script, or consider it a problem

		error_if_running format

		unset need_mask need_settings_path need_charset
		paths=()

		for arg in "${args[@]:1}"; do
			if [[ -n $need_mask ]]; then
				if [[ ! $arg =~ [*?] ]]; then
					error "Invalid mask used with the $need_mask option (no wildcards): $arg"
				else
					unset need_mask
				fi
			elif [[ -n $need_settings_path ]]; then
				error_unless_all_exist File "$arg"
				if [[ $arg != *.xml ]]; then
					error "The code style settings must be an XML file: $arg"
				else
					unset need_settings_path
				fi
			elif [[ -n $need_charset ]]; then
				unset need_charset  # We don't try to check this value

			elif [[ $arg == -m || $arg == -mask ]]; then
				need_mask=$arg
			elif [[ $arg == -s || $arg == -settings ]]; then
				need_settings_path=$arg
			elif [[ $arg == -charset ]]; then
				need_charset=$arg

			elif [[ $arg == -r || $arg == -R || $arg == -allowDefaults || $arg == -d || $arg == -dry ]]; then
				# Miscellaneous valid option, carry on
				continue
			elif [[ $arg == -* && ! -f $arg && ! -d $arg ]]; then
				error "Invalid option: $arg"
			else
				paths+=("$arg")
			fi
		done

		if [[ -n $need_mask ]]; then
			error "You must pass a file mask after the $need_mask option"
		elif [[ -n $need_settings_path ]]; then
			error "You must pass a path to a code style settings file after the $need_settings_path option"
		elif [[ -n $need_charset ]]; then
			error "You must pass a character set after the $need_charset option, e.g. ISO-8859-15"
		fi

		if [[ ${#paths[@]} == 0 ]]; then
			error "Nothing to format! (No files or directories passed)"
		else
			error_unless_all_exist Path "${paths[@]}"
		fi

		# Delegate to format.sh, if we can
		format_sh="$ide_app/Contents/bin/format.sh"

		if [[ -f $format_sh && -x $format_sh ]]; then
			$echo exec "$format_sh" "${special_opts[@]}" "${args[@]:1}"
			exit  # Only reached in test mode
		else
			exec_ide_binary format "${special_opts[@]}" "${args[@]:1}"
		fi

	elif [[ $command == inspect ]]; then
		# https://www.jetbrains.com/help/idea/command-line-code-inspector.html#7d86c34f

		# Mostly you can put options anywhere on a command line, and the IDE will handle them as expected,
		# but for the inspect command, they must come at the end, or the command will fail,
		# so we accept them anywhere here, and manually move them to the end to keep the IDE happy

		error_if_running inspect

		unset need_subdir need_format profile
		dirs=()
		opts=()

		for arg in "${args[@]:1}"; do
			if [[ -n $need_subdir ]]; then
				error_unless_all_exist Directory "$arg"
				unset need_subdir
				opts+=("$arg")

			elif [[ -n $need_format ]]; then
				formats=" xml json plain "
				if [[ $formats != *" $arg "* ]]; then
					error "Invalid format used with $need_format: $arg"
				else
					unset need_format
					opts+=("$arg")
				fi
			
			elif [[ $arg == -d ]]; then
				need_subdir=$arg
				opts+=("$arg")
			elif [[ $arg == -format ]]; then
				need_format=$arg
				opts+=("$arg")
			
			elif [[ $arg == -changes || $arg =~ ^-v[012]$ ]]; then
				# Miscellaneous valid option, carry on
				opts+=("$arg")
			elif [[ $arg == -* && ! -f $arg && ! -d $arg ]]; then
				error "Invalid option: $arg"
			elif [[ ${#dirs[@]} == 1 && -z $profile ]]; then
				profile=$arg
			else
				dirs+=("$arg")
			fi
		done

		if [[ -n $need_subdir ]]; then
			error "You must pass a subdirectory path after the $need_subdir option"
		elif [[ -n $need_format ]]; then
			error "You must pass a format after the $need_format option (xml, json, or plain)"
		fi

		if [[ ${#dirs[@]} != 2 || -z $profile ]]; then
			error "Wrong number of arguments passed, check usage"
		elif [[ $profile != *.xml ]]; then
			error "The inspection profile must be an XML file: $profile"
		fi

		error_unless_all_exist Directory "${dirs[@]}"
		error_unless_all_exist File "$profile"

		# Rewrite $args with all options (and their values) at the end
		args=(inspect "${dirs[0]}" "$profile" "${dirs[1]}" "${opts[@]}")

		# Delegate to inspect.sh, if we can
		inspect_sh="$ide_app/Contents/bin/inspect.sh"

		if [[ -f $inspect_sh && -x $inspect_sh ]]; then
			$echo exec "$inspect_sh" "${special_opts[@]}" "${args[@]:1}"
			exit  # Only reached in test mode
		else
			DEFAULT_PROJECT_PATH="$(pwd)"  # Copied from inspect.sh, unsure whether/why it's needed
			export DEFAULT_PROJECT_PATH
			exec_ide_binary inspect "${special_opts[@]}" "${args[@]:1}"
		fi

	elif [[ $command == installPlugins ]]; then
		# https://www.jetbrains.com/help/idea/install-plugins-from-the-command-line.html#macos

		error_if_running installPlugins
		exec_ide_binary installPlugins "${special_opts[@]}" "${args[@]:1}"
	fi

# Arguments are paths; the IDE will create files if they don't already exist,
# and add a .idea subdirectory when opening a directory that doesn't already have one.
# As of v2023.2.5: --line and its value are accepted, anywhere on the command line,
# including multiple times, but ignored AFAICT.
# https://www.jetbrains.com/help/idea/opening-files-from-command-line.html#macos
else
	need_line_num=false
	path_count=0

	for arg in "${args[@]}"; do
		if [[ $need_line_num == true ]]; then
			if [[ $arg =~ ^[0-9]+$ ]]; then
				need_line_num=false
			else
				break
			fi
		elif [[ $arg == --line ]]; then
			need_line_num=true
		else
			(( path_count+=1 ))
		fi
	done

	if [[ $need_line_num == true ]]; then
		error "You must pass a line number after the --line option"
	elif [[ $wait == true && $path_count != 1 ]]; then
		error "You must pass exactly one file or project directory with the --wait option"
	fi
fi

# Launch the IDE via 'open'
$echo open -na "$ide_app" "${open_opts[@]}" --args "${special_opts[@]}" "${args[@]}"
