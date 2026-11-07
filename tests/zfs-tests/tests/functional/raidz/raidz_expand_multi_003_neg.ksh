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
#	Attaching several disks at once is refused cleanly when it is not
#	allowed, and the raidz width does not change.  Every step is done
#	for raidz1, raidz2 and raidz3.  (The boot area limit is checked in
#	raidz_expand_multi_013_neg.)
#
# STRATEGY:
#	For raidz1, raidz2 and raidz3, each with its own width:
#	1. raidz_expansion_multi disabled: two disks are refused, one disk
#	   works, and two disks work once the feature is enabled.
#	2. The same disk given twice is refused.
#	3. Two new disks for a mirror, a dRAID vdev of the same parity or a
#	   replace are refused.  So are vdev type keywords such as "log"
#	   among the new disks.
#	4. Two disks while another expansion is paused are refused.
#	5. A raidz of old width W plus more disks than make it 32 * W / 7
#	   wide is refused as too wide for one step (the scratch copy would
#	   need more than 16 MiB per old disk); up to 32 * W / 7 wide works.
#	   W is 3 for raidz1 (13 wide works), 4 for raidz2 (18) and 5 for
#	   raidz3 (22).
#

verify_runnable "global"

typeset -r dev_size_mb=128
# Parity and width of the raidz vdev in steps 1 to 4
typeset -a layouts=("1 3" "2 5" "3 4")
# Parity and width of the raidz vdev in step 5
typeset -a wide_layouts=("1 3" "2 4" "3 5")

function cleanup
{
	poolexists "$TESTPOOL" && zpool status "$TESTPOOL"
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"
	poolexists "$TESTPOOL1" && log_must_busy zpool destroy "$TESTPOOL1"

	log_must rm -f $TEST_BASE_DIR/dev-*

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
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


for layout in "${layouts[@]}"; do
	set -- $layout
	typeset -i parity=$1 width=$2
	typeset vdev=raidz$parity-0
	typeset -a old=()
	typeset -a draid=()

	log_note "raidz$parity of $width"

	#
	# Devices 1 to <width> make up the raidz vdev, the next 3 are
	# attached in step 1 and the next one is given twice in step 2.
	# The following parity + 2 make up the second pool of step 3.  The
	# last 4 are refused in step 3, and attached and refused in step 4.
	#
	make_devs $((width + parity + 10))
	for i in {1..$width}; do
		old[i]=${d}$i
	done
	for i in {1..$((parity + 2))}; do
		draid[i]=${d}$((width + 4 + i))
	done
	x1=${d}$((width + parity + 7))
	x2=${d}$((width + parity + 8))
	y1=${d}$((width + parity + 9))
	y2=${d}$((width + parity + 10))

	# 1. Feature disabled
	log_must zpool create -f -o cachefile=none \
	    -o feature@raidz_expansion_multi=disabled $TESTPOOL \
	    raidz$parity "${old[@]}"
	log_mustnot_expect "raidz_expansion_multi" \
	    zpool attach $TESTPOOL $vdev ${d}$((width + 1)) ${d}$((width + 2))
	check_width $TESTPOOL $width
	log_must zpool attach -w $TESTPOOL $vdev ${d}$((width + 1))
	check_width $TESTPOOL $((width + 1))
	log_must zpool set feature@raidz_expansion_multi=enabled $TESTPOOL
	log_must zpool attach -w $TESTPOOL $vdev \
	    ${d}$((width + 2)) ${d}$((width + 3))
	check_width $TESTPOOL $((width + 3))

	# 2. The same disk twice
	log_mustnot zpool attach $TESTPOOL $vdev \
	    ${d}$((width + 4)) ${d}$((width + 4))
	check_width $TESTPOOL $((width + 3))

	# 3. Several disks for a mirror, a dRAID vdev or a replace
	log_must zpool create -f -o cachefile=none $TESTPOOL1 \
	    mirror ${draid[1]} ${draid[2]}
	log_mustnot_expect "raidz" zpool attach $TESTPOOL1 ${draid[1]} $x1 $x2
	check_width $TESTPOOL1 2
	log_must zpool destroy $TESTPOOL1
	log_must zpool create -f -o cachefile=none $TESTPOOL1 \
	    draid$parity "${draid[@]}"
	draid_vdev=$(zpool status $TESTPOOL1 | \
	    awk -v p="^draid$parity:" '$1 ~ p { print $1 }')
	log_mustnot_expect "raidz" \
	    zpool attach $TESTPOOL1 $draid_vdev $x1 $x2
	check_width $TESTPOOL1 $((parity + 2))
	log_mustnot_expect "too many arguments" \
	    zpool replace $TESTPOOL ${d}1 $x1 $x2
	check_width $TESTPOOL $((width + 3))
	log_must zpool destroy $TESTPOOL1
	for kw in log special dedup cache spare mirror; do
		log_mustnot_expect "only devices" \
		    zpool attach $TESTPOOL $vdev $x1 $kw $x2
		check_width $TESTPOOL $((width + 3))
	done
	log_mustnot_expect "only devices" zpool attach $TESTPOOL $vdev log $x1
	check_width $TESTPOOL $((width + 3))

	# 4. Another expansion is paused
	log_must zfs create $TESTPOOL/fs
	log_must fill_fs /$TESTPOOL/fs 1 32 1048576 1 R
	reflow_size=$(get_pool_prop allocated $TESTPOOL)
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES \
	    $((reflow_size / 2))
	log_must zpool attach $TESTPOOL $vdev $x1 $x2
	wait_raidz_expand_paused $TESTPOOL
	log_mustnot_expect "in progress" zpool attach $TESTPOOL $vdev $y1 $y2
	check_width $TESTPOOL $((width + 5))
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must zpool wait -t raidz_expand $TESTPOOL
	is_pool_scrubbing $TESTPOOL && wait_scrubbed $TESTPOOL
	verify_pool $TESTPOOL
	log_must zpool destroy $TESTPOOL
done

#
# 5. Too wide for the scratch copy
#
# vdev_raidz_attach_check() refuses an expansion when the scratch copy would
# read more than SPA_MAXBLOCKSIZE (16 MiB) from each old disk, that is when
# VDEV_BOOT_SIZE (7 << 19) * new width / old width > 16 MiB, or
# 7 * new width > 32 * old width.  The rounding up to whole sectors does not
# matter, as 16 MiB is a whole number of sectors.
#
for layout in "${wide_layouts[@]}"; do
	set -- $layout
	typeset -i parity=$1 width=$2
	typeset -i maxwidth
	(( maxwidth = 32 * width / 7 ))
	typeset vdev=raidz$parity-0
	typeset -a old=()
	typeset -a new=()

	log_note "raidz$parity of $width, at most $maxwidth wide in one step"

	make_devs $((maxwidth + 1))
	for i in {1..$width}; do
		old[i]=${d}$i
	done
	for i in {$((width + 1))..$((maxwidth + 1))}; do
		new[${#new[*]}+1]=${d}$i
	done

	log_must zpool create -f -o cachefile=none $TESTPOOL \
	    raidz$parity "${old[@]}"
	log_must dd if=/dev/urandom of=/$TESTPOOL/file bs=1M count=16
	log_mustnot_expect "too wide to add this many devices in one step" \
	    zpool attach $TESTPOOL $vdev "${new[@]}"
	check_width $TESTPOOL $width
	unset "new[${#new[*]}]"
	log_must zpool attach -w $TESTPOOL $vdev "${new[@]}"
	check_width $TESTPOOL $maxwidth
	is_pool_scrubbing $TESTPOOL && wait_scrubbed $TESTPOOL
	verify_pool $TESTPOOL
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must zpool destroy $TESTPOOL
done

log_pass "several-disk raidz attach refused cleanly when not allowed"
