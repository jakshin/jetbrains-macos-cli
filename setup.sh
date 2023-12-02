#!/bin/bash -e
# Setup script for the jetbrains-macos-cli script: install, uninstall, repair.

if [[ -n $JETBRAINS_CLI_INSTALL_DIR ]]; then
	install_dir=$JETBRAINS_CLI_INSTALL_DIR
else
	install_dir=/usr/local/bin
fi

if [[ -n $JETBRAINS_CLI_MAN_DIR ]]; then
	man_dir=$JETBRAINS_CLI_MAN_DIR
else
	man_dir=/usr/local/share/man/man1
fi

if [[ -z $NO_COLOR ]]; then
	bright='\033[0;1m'
	plain='\033[0m'
	light_red='\033[1;31m'
	dark_red='\033[0;31m'
else
	bright=''
	plain=''
	light_red=''
	dark_red=''
fi

setup_script_path=$0
while [[ -L $setup_script_path ]]; do
	setup_script_path="$(readlink -- "$setup_script_path")"
done

setup_script_dir="$(dirname -- "$setup_script_path")"
setup_script_name="$(basename -- "$setup_script_path")"

function usage() {
	echo -e "\n${bright}${setup_script_name} [directory ...]${plain}"
	echo "  Create launch scripts and man pages for all installed JetBrains IDEs"
	echo "  that use JetBrains' standard command-line format and options"
	echo "  (including IntelliJ IDEA and their other marquee IDEs)."
	echo
	echo "  Optionally pass a list of directories to search for JetBrains IDEs"
	echo "  (in case this installer doesn't find them itself for some reason)."

	echo -e "\n${bright}${setup_script_name} --uninstall${plain}"
	echo "  Remove scripts and man pages created by this script."

	echo
	echo "Scripts are created in \$JETBRAINS_CLI_INSTALL_DIR (/usr/local/bin by default);"
	echo "Man pages are created in \$JETBRAINS_CLI_MAN_DIR (/usr/local/share/man/man1)."
}

function array_contains() {
	local needle=$1
	shift  # All remaining parameters are the haystack/array

	local array_item
	for array_item in "$@"; do
		if [[ $array_item == "$needle" ]]; then
			return 0
		fi
	done

	return 1  # Item not found in the array
}

function delete_from_array() {
	local needle=$1
	shift  # All remaining parameters are the haystack/array

	for array_item in "$@"; do
		if [[ $array_item != "$needle" ]]; then
			echo "$array_item"  # All not-deleted items are echoed; read output lines into an array
		fi
	done
}

# Creates a directory recursively, using "mkdir -p", and using sudo if needed,
# based on write permissions in the nearest existing ancestor path
function mkdirp() {
	local dir=$1
	if [[ -d $dir ]]; then
		return 0
	fi

	local ancestor=$dir
	while [[ ! -e $ancestor ]]; do
		ancestor="$(dirname -- "$ancestor")"
	done

	if [[ -w $ancestor ]]; then
		local sudo=""
	else
		local sudo="sudo"
		if [[ $sudo_explained != true ]]; then
			echo "ℹ️  We need to use sudo to create $dir"
			sudo_explained=true
		fi
	fi

	$sudo mkdir -p "$dir"
}

# Finds instances of an app anywhere in the file system, using Spotlight and bundle IDs
# Pass one or more bundle IDs
function mdfind_apps() {
	local id
	for id in "$@"; do
		local apps=()
		IFS=$'\n' read -r -d '' -a apps < <(mdfind kMDItemCFBundleIdentifier="$id" 2> /dev/null; printf '\0')
		ide_apps+=("${apps[@]}")  # Append to the global array
	done
}

# Finds instances of an app in a list of directories, using its name
# Pass an IDE's name, and one or more directories (absolute paths expected)
function find_apps() {
	local name=$1
	shift  # All remaining parameters are directory paths

	local dir
	for dir in "$@"; do
		local apps=()
		IFS=$'\n' read -r -d '' -a apps < <(find "$dir" -type d -name "$name*.app" -maxdepth 2 2> /dev/null; printf '\0')

		local app
		for app in "${apps[@]}"; do
			if ! array_contains "$app" "${ide_apps[@]}"; then
				ide_apps+=("$app")  # Append to the global array
			fi
		done
	done
}

# Parse the command line
options_done=false
uninstall=false
find_ide_apps_in_directories=()

for arg; do
	if [[ $options_done == true || $arg != -* ]]; then
		find_ide_apps_in_directories+=("$arg")
		options_done=true

	elif [[ $arg == -- ]]; then
		options_done=true

	elif [[ $arg == --help || $arg == -help || $arg == -h ]]; then
		echo -e "${bright}JetBrains IDE launch script installer/uninstaller${plain}"
		usage
		exit 0

	elif [[ $arg == --uninstall || $arg == -uninstall ]]; then
		uninstall=true

	else
		echo -e "${light_red}Error: ${dark_red}Invalid option: ${arg}${plain}" >&2
		echo "Run '$setup_script_name --help' for usage info" >&2
		exit 1
	fi
done

# Try to handle all the JetBrains IDEs that have these same command-line options
# (I've only actually tested a few of these, though)
# Get an app's bundle ID with: mdls -name kMDItemCFBundleIdentifier Foo.app
ides=(
	"com.jetbrains.CLion|CLion"
	"com.jetbrains.datagrip|DataGrip"
	"com.jetbrains.dataspell|DataSpell"
	"com.jetbrains.goland|GoLand"
	"com.jetbrains.intellij|IntelliJ IDEA"
	"com.jetbrains.PhpStorm|PhpStorm"
	"com.jetbrains.pycharm|PyCharm"
	"com.jetbrains.rider|Rider"
	"com.jetbrains.rubymine|RubyMine"
	"com.jetbrains.rustrover|RustRover"
	"com.jetbrains.WebStorm|WebStorm"
)

echo "ℹ️  Script location: $install_dir"

for ide in "${ides[@]}"; do
	ide_bundle_id=${ide/|*}
	ide_name=${ide/*|}

	if [[ $ide_name == IntelliJ* ]]; then
		ide_binary=idea
	else
		# IDE name's first word, lowercase
		ide_binary="$(echo "${ide_name/ *}" | tr '[:upper:]' '[:lower:]')"
	fi

	# Get a list of any scripts we previously created; we'll try to clean them up later
	# (Actually this list may contain scripts we didn't create, but we'll notice that later if so)
	cleanup_scripts=()

	if [[ -d $install_dir ]]; then
		ide_name_first_word="${ide_name// *}"
		IFS=$'\n' read -r -d '' -a cleanup_scripts < <(cd "$install_dir" && printf "%s\n" "$ide_name_first_word"*; printf '\0')

		if [[ ${cleanup_scripts[0]} == "$ide_name*" ]]; then
			cleanup_scripts=()
		fi
	fi

	if [[ $uninstall == false ]]; then
		ide_apps=()
		mdfind_apps "$ide_bundle_id" "$ide_bundle_id-EAP"

		if [[ $ide_bundle_id == com.jetbrains.intellij || $ide_bundle_id == com.jetbrains.pycharm ]]; then
			mdfind_apps "$ide_bundle_id.ce" "$ide_bundle_id.ce-EAP"  # Look for community editions
		fi

		# Try manually searching some common directories for any app whose name starts with $ide_name,
		# in case something is wrong with mdfind, or we have an outdated bundle ID
		find_apps "$ide_name" /Applications ~/Applications ~/Desktop ~/Downloads "${find_ide_apps_in_directories[@]}"

		if [[ ${#ide_apps[@]} == 0 ]]; then
			echo "⏭️  $ide_name isn't installed"  # We still may need to delete outdated scripts

		elif [[ ${#ide_apps[@]} != 1 ]]; then
			# Sort by path & version (global before user-specific, unversioned before any version)
			IFS=$'\n' read -r -d '' -a ide_apps < <(IFS=$'\n'; echo "${ide_apps[*]}" | sort -V 2> /dev/null; printf '\0')
		fi

		if [[ $ide_bundle_id == com.jetbrains.intellij || $ide_bundle_id == com.jetbrains.pycharm ]]; then
			# We'll tweak how we name scripts based on whether pro and/or community versions are installed
			pro=false
			community=false

			for app in "${ide_apps[@]}"; do
				if [[ $app == *Community* ]]; then
					community=true
				else
					pro=true
				fi
			done
		fi

		# Create scripts
		created_scripts=()

		for app in "${ide_apps[@]}"; do
			app_basename="$(basename -s .app "$app")"

			if [[ $app_basename == IntelliJ* && $community == true ]]; then
				# IntelliJ: use "community" in the name only if ultimate is also installed
				app_basename=${app_basename// Edition}  # Remove "Edition" from "IntelliJ IDEA Community Edition"
				if [[ $pro == false ]]; then
					app_basename=${app_basename// Community}
				fi
			elif [[ $app_basename == PyCharm* && ($pro == false || $community == false) ]]; then
				# PyCharm: use "professional" or "community" in the name only if both are installed
				app_basename=${app_basename// Professional}
				app_basename=${app_basename// Community}
			fi

			script_name=${app_basename// /-}
			install_path="$install_dir/$script_name"

			while [[ -e $install_path || -L $install_path ]]; do
				if [[ -L $install_path ]]; then
					echo "⚠️  Can't replace symlink: $install_path"
				elif [[ -d $install_path ]]; then
					echo "⚠️  Can't replace directory: $install_path"
				elif ! grep -q jetbrains-macos-cli "$install_path"; then
					echo "⚠️  Can't overwrite existing file: $install_path"
				elif ! array_contains "$script_name" "${created_scripts[@]}"; then
					break  # Overwrite the script we previously created
				fi

				if [[ $script_name =~ -[0-9]+$ ]]; then
					script_name="${script_name%-[0-9]*}-$(( -BASH_REMATCH + 1))"
				else
					script_name+="-1"
				fi

				install_path="$install_dir/$script_name"
			done

			mkdirp "$install_dir"
			if [[ -w $install_dir ]]; then
				sudo_for_install=""
			else
				sudo_for_install="sudo"
				if [[ $sudo_explained != true ]]; then
					echo "ℹ️  We need to use sudo to create scripts in $install_dir"
					sudo_explained=true
				fi
			fi

			echo "✅ $script_name -> $app"
			sed -e "s|^ide_app=.*|ide_app=\"$app\"|" \
				-e "s|^ide_binary=.*|ide_binary=\"$ide_binary\"|" \
				-e "s|^ide_name=.*|ide_name=\"$ide_name\"|" \
				"$setup_script_dir/jetbrains-macos-cli.sh" | $sudo_for_install tee "$install_path" > /dev/null
			$sudo_for_install chmod 755 "$install_path"

			created_scripts+=("$script_name")
			IFS=$'\n' read -r -d '' -a cleanup_scripts < <(delete_from_array "$script_name" "${cleanup_scripts[@]}"; printf '\0')

			# Quietly create the man page too, if possible
			mkdirp "$man_dir"
			if [[ -w $man_dir ]]; then
				sudo_for_man=""
			else
				sudo_for_man="sudo"
				if [[ $sudo_explained != true ]]; then
					echo "ℹ️  We need to use sudo to create man pages in $man_dir"
					sudo_explained=true
				fi
			fi

			man_path="$man_dir/$script_name.1"
			if [[ -L $man_path ]]; then
				echo "❌ Can't replace symlink: $man_path"
			elif [[ -d $man_path ]]; then
				echo "❌ Can't replace directory: $man_path"
			elif test -f "$man_path" && test -s "$man_path" && ! grep -q jetbrains-macos-cli "$man_path"; then
				echo "❌ Can't overwrite existing file: $man_path"
			else
				if [[ $ide_name == Rider* ]]; then
					cli_help_url="https://www.jetbrains.com/help/rider/Working_with_the_IDE_Features_from_Command_Line.html"
				else
					case $ide_binary in
						go*) ide_short_name=go;;
						ruby*) ide_short_name=ruby;;
						rust*) ide_short_name=rust;;
						*) ide_short_name=$ide_binary;;
					esac

					cli_help_url="https://www.jetbrains.com/help/$ide_short_name/working-with-the-ide-features-from-command-line.html"
				fi

				sed -e "s|script_name|$script_name|" \
					-e "s|ide_name|$ide_name|" \
					-e "s|cli_help_url|$cli_help_url|" \
					"$setup_script_dir/manpage/jetbrains-macos-cli.1" | $sudo_for_man tee "$man_path" > /dev/null
			fi
		done
	fi

	# Uninstall scripts -OR- Delete any scripts we previously created, and didn't just recreate
	if [[ $uninstall == true ]]; then
		action="Uninstalling script"
	else
		action="Removing outdated script"
	fi

	[[ -w $install_dir ]] && sudo_for_install="" || sudo_for_install="sudo"
	[[ -w $man_dir ]] && sudo_for_man="" || sudo_for_man="sudo"

	for script_name in "${cleanup_scripts[@]}"; do
		cleanup_path="$install_dir/$script_name"
		if test -f "$cleanup_path" && grep -q jetbrains-macos-cli "$cleanup_path"; then
			echo "🗑️  $action: $script_name"
			$sudo_for_install rm -f "$cleanup_path"
			removed_something=true
		fi

		cleanup_path="$man_dir/$script_name.1"
		if test -f "$cleanup_path" && grep -q jetbrains-macos-cli "$cleanup_path"; then
			$sudo_for_man rm -f "$cleanup_path"
		fi
	done
done

if [[ $uninstall == true && $removed_something != true ]]; then
	echo "ℹ️  Nothing to uninstall"
fi

# Clean up any lingering man pages: remove those without a corresponding script
if [[ -d $man_dir && -r $man_dir && -x $man_dir ]]; then
	[[ -w $man_dir ]] && sudo_for_man="" || sudo_for_man="sudo"

	cleanup_pages=()
	IFS=$'\n' read -r -d '' -a cleanup_pages < <(cd "$man_dir" &&
		grep -al --directories=skip jetbrains-macos-cli -- * 2> /dev/null; printf '\0')

	for page_name in "${cleanup_pages[@]}"; do
		script_name="$(basename -s .1 "$page_name")"
		if ! test -f "$install_dir/$script_name" && ! type "$script_name" &> /dev/null; then
			$sudo_for_man rm -f "$man_dir/$page_name"
		fi
	done
fi
