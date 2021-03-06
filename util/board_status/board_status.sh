#!/bin/sh
#
# This file is part of the coreboot project.
#
# Copyright (C) 2013 Google Inc.
# Copyright (C) 2014 Sage Electronic Engineering, LLC.
#

EXIT_SUCCESS=0
EXIT_FAILURE=1

# Stuff from command-line switches
COREBOOT_IMAGE="build/coreboot.rom"
REMOTE_HOST=""
CLOBBER_OUTPUT=0
UPLOAD_RESULTS=0
SERIAL_PORT_SPEED=115200

# Used to specify whether a command should always be run locally or
# if command should be run remoteley when a remote host is specified.
LOCAL=0
REMOTE=1
FATAL=0
NONFATAL=1

# test a command
#
# $1: 0 ($LOCAL) to run command locally,
#     1 ($REMOTE) to run remotely if remote host defined
# $2: command to test
# $3: 0 ($FATAL) Exit with an error if the command fails
#     1 ($NONFATAL) Don't exit on command test failure
test_cmd()
{
	local rc

	if [ -e "$2" ]; then
		return
	fi

	if [ "$1" -eq "$REMOTE" ] && [ -n "$REMOTE_HOST" ]; then
		ssh root@${REMOTE_HOST} command -v "$2" > /dev/null
		rc=$?
	else
		command -v "$2" >/dev/null
		rc=$?
	fi

	if [ $rc -eq 0 ]; then
		return 0
	fi

	if [ "$3" = "1" ]; then
		return 1
	fi

	echo "$2 not found"
	exit $EXIT_FAILURE
}

_cmd()
{
	if [ -e "$2" ]; then
		return $EXIT_FAILURE
	fi

	if [ -n "$3" ]; then
		pipe_location="${3}"
	else
		pipe_location="/dev/null"
	fi

	if [ "$1" -eq "$REMOTE" ] && [ -n "$REMOTE_HOST" ]; then
		ssh "root@${REMOTE_HOST}" "$2" > "$pipe_location" 2>&1
	else
		$2 > "$pipe_location" 2>&1
	fi

	return $?
}

# run a command
#
# $1: 0 ($LOCAL) to run command locally,
#     1 ($REMOTE) to run remotely if remote host defined
# $2: command
# $3: filename to direct output of command into
cmd()
{
	_cmd $1 "$2" "$3"

	if [ $? -eq 0 ]; then
		return
	fi

	echo "Failed to run \"$2\", aborting"
	rm -f "$3"	# don't leave an empty file
	exit $EXIT_FAILURE
}

# run a command where failure is considered to be non-fatal
#
# $1: 0 ($LOCAL) to run command locally,
#     1 ($REMOTE) to run remotely if remote host defined
# $2: command
# $3: filename to direct output of command into
cmd_nonfatal()
{
	_cmd $1 "$2" "$3"

	if [ $? -eq 0 ]; then
		return
	fi

	echo "Failed to run \"$2\", ignoring"
	rm -f "$3"	# don't leave an empty file
}

# read from a serial port device
#
# $1: serial device to read from
# $2: serial port speed
# $3: filename to direct output of command into
get_serial_bootlog () {

	local TTY=$1
	local SPEED=$2
	local FILENAME=$3

	if [ ! -c "$TTY" ]; then
		echo "$TTY is not a valid serial device"
		exit $EXIT_FAILURE
	fi

	# make the text more noticible
	test_cmd $LOCAL "tput" $NONFATAL
	tput_not_available=$?
	if [ $tput_not_available -eq 0 ]; then
		tput bold
		tput setaf 10 # set bright green
	fi

	echo
	echo "Waiting to receive boot log from $TTY"
	echo "Press [Enter] when the boot is complete and the"
	echo "system is ready for ssh to get the dmesg log."
	echo

	if [ $tput_not_available -eq 0 ]; then
		tput sgr0
	fi

	# set up the serial port
	stty -F $TTY $SPEED cs8 -cstopb -parenb clocal

	# read from the serial port - user must press enter when complete
	test_cmd $LOCAL "tee"
	while read LINE; do
		echo "$LINE" | tee -a "$FILENAME"
	done < "$SERIAL_DEVICE" &
	PID=$!

	read foo
	kill "$PID" 2>/dev/null

	echo "Finished reading boot log."
}

show_help() {
	echo "Usage:
	${0} <option>

Options
    -h
        Show this message.
    -C
        Clobber temporary output when finished. Useful for debugging.
    -i  <image>
        Path to coreboot image (Default is $COREBOOT_IMAGE).
    -r  <host>
        Obtain machine information from remote host (using ssh).
    -s  </dev/xxx>
        Obtain boot log via serial device.
    -S  <speed>
        Set the port speed for the serial device (Default is $SERIAL_PORT_SPEED).
    -u
        Upload results to coreboot.org.
"
}

while getopts "Chi:r:s:S:u" opt; do
	case "$opt" in
		h)
			show_help
			exit $EXIT_SUCCESS
			;;
		C)
			CLOBBER_OUTPUT=1
			;;
		i)
			COREBOOT_IMAGE="$OPTARG"
			;;
		r)
			REMOTE_HOST="$OPTARG"
			;;
		s)
			SERIAL_DEVICE="$OPTARG"
			;;
		S)
			SERIAL_PORT_SPEED="$OPTARG"
			;;
		u)
			UPLOAD_RESULTS=1
			;;
	esac
done

grep -rH 'coreboot.org' .git/config >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Script must be run from root of coreboot directory"
	exit $EXIT_FAILURE
fi

# Results will be placed in a temporary location until we're ready to upload.
# If the user does not wish to upload, results will remain in /tmp.
tmpdir=$(mktemp -d --tmpdir coreboot_board_status.XXXXXXXX)

# Obtain coreboot config by running cbfstool on the ROM image. cbfstool may
# already exist in build/ or util/cbfstool/, but if not then we'll build it
# now and clean it when we're done.
cbfstool_cmd="build/cbfstool"
do_clean_cbfstool=0
if [ ! -x $cbfstool_cmd ]; then
	cbfstool_cmd="util/cbfstool/cbfstool"
	if [ -e $cbfstool_cmd ]; then
		if test ! -x $cbfstool_cmd; then
			echo "Cannot execute $cbfstool_cmd."
			exit $EXIT_FAILURE
		fi
	else
		make -C util/cbfstool/
		do_clean_cbfstool=1
	fi
fi
test_cmd $LOCAL "$cbfstool_cmd"

tmpcfg=$(mktemp coreboot_config.XXXXXX)
echo "Extracting config.txt from $COREBOOT_IMAGE"
$cbfstool_cmd "$COREBOOT_IMAGE" extract -n config -f "${tmpdir}/config.txt" >/dev/null 2>&1
mv "${tmpdir}/config.txt" "${tmpdir}/config.short.txt"
cp "${tmpdir}/config.short.txt" "${tmpcfg}"
yes "" | make "DOTCONFIG=${tmpcfg}" oldconfig 2>/dev/null >/dev/null
mv "${tmpcfg}" "${tmpdir}/config.txt"
rm -f "${tmpcfg}.old"
$cbfstool_cmd "$COREBOOT_IMAGE" print > "${tmpdir}/cbfs.txt"
rom_contents=$($cbfstool_cmd "$COREBOOT_IMAGE" print 2>&1)
if [ -n "$(echo $rom_contents | grep payload_config)" ]; then
	echo "Extracting payload_config from $COREBOOT_IMAGE"
	$cbfstool_cmd "$COREBOOT_IMAGE" extract -n payload_config -f "${tmpdir}/payload_config.txt" >/dev/null 2>&1
fi
if [ -n "$(echo $rom_contents | grep payload_version)" ]; then
	echo "Extracting payload_version from $COREBOOT_IMAGE"
	$cbfstool_cmd "$COREBOOT_IMAGE" extract -n payload_version -f "${tmpdir}/payload_version.txt" >/dev/null 2>&1
fi
md5sum -b "$COREBOOT_IMAGE" > "${tmpdir}/rom_checksum.txt"

if test $do_clean_cbfstool -eq 1; then
	make -C util/cbfstool clean
fi

# Obtain board and revision info to form the directory structure:
# <vendor>/<board>/<revision>/<timestamp>
mainboard_dir="$(grep CONFIG_MAINBOARD_DIR "${tmpdir}/config.txt" | awk -F '"' '{ print $2 }')"
vendor=$(echo "$mainboard_dir" | awk -F '/' '{ print $1 }')
mainboard=$(echo "$mainboard_dir" | awk -F '/' '{ print $2 }')

getrevision="util/board_status/getrevision.sh"
test_cmd $LOCAL $getrevision
tagged_version=$($getrevision -T)
timestamp=$($getrevision -t)

results="${vendor}/${mainboard}/${tagged_version}/${timestamp}"

echo "Temporarily placing output in ${tmpdir}/${results}"
mkdir -p "${tmpdir}/${results}"

mv "${tmpdir}/config.txt" "${tmpdir}/${results}"
test -f "${tmpdir}/payload_config.txt" && mv "${tmpdir}/payload_config.txt" "${tmpdir}/${results}"
test -f "${tmpdir}/payload_version.txt" && mv "${tmpdir}/payload_version.txt" "${tmpdir}/${results}"
mv "${tmpdir}/config.short.txt" "${tmpdir}/${results}"
mv "${tmpdir}/cbfs.txt" "${tmpdir}/${results}"
mv "${tmpdir}/rom_checksum.txt" "${tmpdir}/${results}"

touch "${tmpdir}/${results}/revision.txt"
printf "Local revision: %s\n" "$($getrevision -l)" >> "${tmpdir}/${results}/revision.txt"
printf "Tagged revision: %s\n" "${tagged_version}" >> "${tmpdir}/${results}/revision.txt"
printf "Upstream revision: %s\n" "$($getrevision -u)" >> "${tmpdir}/${results}/revision.txt"
printf "Upstream URL: %s\n" "$($getrevision -U)" >> "${tmpdir}/${results}/revision.txt"
printf "Timestamp: %s\n" "$timestamp" >> "${tmpdir}/${results}/revision.txt"

if [ -z "$SERIAL_DEVICE" ]; then
	echo "Verifying that CBMEM is available on remote device"
	test_cmd $REMOTE "cbmem"
	echo "Getting coreboot boot log"
	cmd $REMOTE "cbmem -c" "${tmpdir}/${results}/coreboot_console.txt"
	echo "Getting timestamp data"
	cmd_nonfatal $REMOTE "cbmem -t" "${tmpdir}/${results}/coreboot_timestamps.txt"
else
	get_serial_bootlog "$SERIAL_DEVICE" "$SERIAL_PORT_SPEED" "${tmpdir}/${results}/coreboot_console.txt"
fi

echo "Getting remote dmesg"
cmd $REMOTE dmesg "${tmpdir}/${results}/kernel_log.txt"

#
# Finish up.
#
coreboot_dir=$(pwd)
if [ $UPLOAD_RESULTS -eq 1 ]; then
	# extract username from ssh://<username>@review.coreboot.org/blah
	bsrepo=$(git config --get remote.origin.url | sed "s,\(.*\)/coreboot,\1/board-status,")

	cd "util/board_status/"
	if [ ! -e "board-status" ]; then
		# FIXME: the board-status directory might get big over time.
		# Is there a way we can push the results without fetching the
		# whole repo?
		git clone "$bsrepo"
		if [ $? -ne 0 ]; then
			echo "Error cloning board-status repo, aborting."
			exit $EXIT_FAILURE
		fi
	fi

	cd "board-status"

	echo "Checking for duplicate results"
	# get any updates to board-status
	git pull

	echo "${tagged_version}" | grep dirty >/dev/null 2>&1
	clean_version=$?
	existing_results=$(git ls-files "${mainboard_dir}/${tagged_version}")

	# reject duplicate results of non-dirty versions
	if [ "${clean_version}" -eq 1 ] && [ -n "${existing_results}" ] ; then
		echo "Result is a duplicate, aborting"
		exit $EXIT_FAILURE
	fi

	echo "Copying results to $(pwd)/${results}"

	# Note: Result directory should be unique due to the timestamp.
	cp -R "${tmpdir}/${vendor}" .

	echo "Uploading results"
	git add "${vendor}"
	git commit -a -m "${mainboard_dir}/${tagged_version}/${timestamp}"
	count=0
	until git push origin || test $count -eq 3; do
	        git pull --rebase
		count=$((count + 1))
	done

	# Results have been uploaded so it's pointless to keep the
	# temporary files around.
	rm -rf "${tmpdir}"
	if test $count -eq 3; then
		echo "Error uploading to board-status repo, aborting."
		exit $EXIT_FAILURE
	fi
fi
cd "$coreboot_dir"

if [ $CLOBBER_OUTPUT -eq 1 ]; then
	rm -rf "${tmpdir}"
else
	echo
	echo "output files are in ${tmpdir}/${results}"
fi

exit $EXIT_SUCCESS
