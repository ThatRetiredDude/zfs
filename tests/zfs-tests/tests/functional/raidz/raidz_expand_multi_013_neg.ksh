#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	Attaching more disks at once than fit in the boot area is refused
#	cleanly, and zpool says how many more disks fit.  Done for raidz1,
#	raidz2 and raidz3.
#
# STRATEGY:
#	For raidz1, raidz2 and raidz3, each with ashift=16 and half as many
#	disks as fit (28 of VDEV_BOOT_SIZE / 64 KiB = 56):
#	1. Attaching one disk more than fits is refused, with the number of
#	   disks that do fit in the message, and the width does not change.
#	2. Attaching as many as fit works, and the pool scrubs clean.
#	This is a separate test from raidz_expand_multi_003_neg because it
#	uses vdevs up to 56 disks wide, which take minutes on a slow disk.
#

verify_runnable "global"

typeset -r dev_size_mb=128

function cleanup
{
	poolexists "$TESTPOOL" && zpool status "$TESTPOOL"
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	log_must rm -f $TEST_BASE_DIR/dev-*
}

function check_width # <pool> <width>
{
	typeset -i found=$(zpool status $1 | grep -c "$TEST_BASE_DIR/dev-")
	if [[ $found -ne $2 ]]; then
		log_fail "expected $2 disks in $1, found $found"
	fi
}

#
# Create <count> new, empty file devices, ${d}1 to ${d}<count>.  Each call
# uses new names and leaves the old files to cleanup: on FreeBSD, creating
# files right after removing dozens of them can wait minutes for the file
# system to free the old ones.
#
typeset -i round=0
function make_devs # <count>
{
	(( round += 1 ))
	d=$TEST_BASE_DIR/dev-$round-
	for i in {1..$1}; do
		log_must truncate -s ${dev_size_mb}M ${d}$i
	done
}

log_onexit cleanup

#
# Too wide for the boot area
#
# vdev_raidz_attach_check() refuses an expansion when the new width times
# the sector size is larger than VDEV_BOOT_SIZE (3.5 MiB), and zpool then
# says how many more disks fit.
#
# The vdev starts at half the largest width.  The copy can only run ahead
# of the progress on disk by about (added disks / old width) of it per txg,
# so doubling the width takes a few txgs, where a vdev of 54 disks plus 2
# takes more than a hundred.
#
typeset -r ashift=16
typeset -r maxdevs=$(( (7 << 19) >> ashift ))
for parity in 1 2 3; do
	typeset -i room width
	(( width = maxdevs / 2 ))
	(( room = maxdevs - width ))
	typeset vdev=raidz$parity-0
	typeset -a old=()
	typeset -a new=()

	log_note "raidz$parity of $width with ashift=$ashift, room for $room"

	make_devs $((maxdevs + 1))
	for i in {1..$width}; do
		old[i]=${d}$i
	done
	for i in {$((width + 1))..$((maxdevs + 1))}; do
		new[${#new[*]}+1]=${d}$i
	done

	log_must zpool create -f -o cachefile=none -o ashift=$ashift \
	    $TESTPOOL raidz$parity "${old[@]}"
	log_mustnot_expect "at most $room more devices" \
	    zpool attach $TESTPOOL $vdev "${new[@]}"
	check_width $TESTPOOL $width
	unset "new[${#new[*]}]"
	log_must zpool attach -w $TESTPOOL $vdev "${new[@]}"
	check_width $TESTPOOL $maxdevs
	is_pool_scrubbing $TESTPOOL && wait_scrubbed $TESTPOOL
	verify_pool $TESTPOOL
	log_must zpool destroy $TESTPOOL
done

log_pass "several-disk raidz attach beyond the boot area refused cleanly"
