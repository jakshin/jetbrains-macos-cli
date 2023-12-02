#!/bin/bash -e
# Build the man page from its ronn source
# http://rtomayko.github.io/ronn/ronn.1.html

build_script_path=$0
while [[ -L $build_script_path ]]; do
	build_script_path="$(readlink -- "$build_script_path")"
done

build_script_dir="$(dirname -- "$build_script_path")"
cd -- "$build_script_dir"

if ! type ronn &> /dev/null; then
	echo "Error: ronn must be installed (e.g. via Homebrew)"
	exit 1
fi

if ! type groff &> /dev/null; then
	# Expose the dummy groff script in this directory,
	# to suppress ronn's error about the groff command not being found
	PATH="$PATH:$PWD"
fi

set -x
ronn --organization=JetBrains --roff jetbrains-macos-cli.1.ronn

{ set +x ;} 2> /dev/null
if test -f jetbrains-macos-cli.1 && ! grep -q jetbrains-macos-cli jetbrains-macos-cli.1; then
	echo -e '.\" jetbrains-macos-cli\n' >> jetbrains-macos-cli.1
fi
