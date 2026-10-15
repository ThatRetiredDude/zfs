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
#	What 'zpool' shows and records for an expansion that adds several
#	disks: the old and new width in 'zpool status' and 'zpool status -j',
#	one history line and one vdev_attach event per new disk.  'zpool
#	attach -s' is refused for a raidz target before any disk is labelled,
#	and 'zpool attach -w' waits for the expansion when the raidz target
#	is given by its GUID.  All of it is checked for raidz1, raidz2 and
#	raidz3.
#
# STRATEGY:
#	For each layout (parity P, old width W, disks added A), one each for
#	raidz1, raidz2 and raidz3, with the raidz vdev named raidzP-0:
#	1. Create a raidzP of W with some data and clear the events.
#	2. 'zpool attach -s' to it, with one disk, with the A disks, and with
#	   the A disks and the raidz given by its GUID, is refused with
#	   "-s does not apply to raidz expansion" and exit status 1.  The
#	   width does not change, no expansion starts, the new disks have no
#	   label, and no history line or vdev_attach event is recorded.
#	3. Attach the A disks with the copy paused.  'zpool status' shows
#	   "from W to W+A disks"; 'zpool status -j' has old_width W and
#	   new_width W+A in raidz_expand_stats, as strings, and as numbers
#	   with --json-int.
#	4. Let the copy finish.  'zpool status' shows the finished line and
#	   the JSON has no widths.  'zpool history -i' has one "vdev attach"
#	   line per new disk, one "raidz vdev expansion started" and one
#	   "raidz vdev expansion completed" line, both with new width W+A.
#	   'zpool events' has one vdev_attach event per new disk.
#	5. Create a second raidzP of W, attach one disk with the copy
#	   paused: 'zpool status' shows "from W to W+1 disks", the JSON has
#	   old_width W and new_width W+1.  Let the copy finish.
#	6. 'zpool attach -w' A disks to the second pool, with the raidz
#	   given by its GUID.  Right after it returns, 'zpool status' shows
#	   the expansion finished, not in progress, and the pool is W+1+A
#	   wide.  The history and the events have one record per new disk.
#

verify_runnable "global"

typeset -r dev_size_mb=128
# Parity, old width and disks added at once
typeset -a layouts=("1 3 2" "2 5 3" "3 4 4")
# The raidz vdev of the layout being checked
typeset vdev=raidz1-0

function cleanup
{
	poolexists "$TESTPOOL" && zpool status "$TESTPOOL"
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"
	poolexists "$TESTPOOL1" && zpool status "$TESTPOOL1"
	poolexists "$TESTPOOL1" && log_must_busy zpool destroy "$TESTPOOL1"

	log_must rm -f $TEST_BASE_DIR/dev-* $TEST_BASE_DIR/attach-s.out

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
}

function check_width # <pool> <width>
{
	typeset -i found=$(zpool status $1 | grep -c "$TEST_BASE_DIR/dev-")
	if (( found != $2 )); then
		log_fail "expected $2 disks in $1, found $found"
	fi
}

#
# 'zpool attach -s' to a raidz is refused by zpool before any new disk is
# labelled: exit status 1 and "cannot attach to <target>: -s does not apply
# to raidz expansion".
#
function check_attach_s_refused # <pool> <target> <new disk> ...
{
	typeset pool=$1
	typeset target=$2
	typeset out=$TEST_BASE_DIR/attach-s.out
	typeset msg="cannot attach to $target:"
	typeset -i rv
	shift 2

	msg="$msg -s does not apply to raidz expansion"
	zpool attach -s $pool $target "$@" >$out 2>&1
	rv=$?
	log_note "zpool attach -s $pool $target $* exited $rv: $(<$out)"
	if (( rv != 1 )); then
		log_fail "zpool attach -s $pool $target $* exited $rv," \
		    "expected 1"
	fi
	if ! grep -qxF -- "$msg" $out; then
		log_fail "zpool attach -s $pool $target $* did not print" \
		    "\"$msg\""
	fi
	for disk in "$@"; do
		log_mustnot zdb -lq $disk
	done
}

#
# Print old_width and new_width from the raidz_expand_stats object of
# 'zpool status -j', as a JSON array.  Extra arguments go to zpool status.
#
function json_widths # <pool> [zpool status options]
{
	typeset pool=$1
	shift

	zpool status -j "$@" $pool | jq -c --arg p $pool \
	    '.pools[$p].raidz_expand_stats | [.old_width, .new_width]'
}

#
# The widths are formatted like expanding_vdev in the same object: strings
# by default and numbers with --json-int.
#
function check_json_widths # <pool> <old width> <new width>
{
	typeset pool=$1
	typeset str=$(json_widths $pool)
	typeset int=$(json_widths $pool --json-int)

	if [[ "$str" != "[\"$2\",\"$3\"]" ]]; then
		log_fail "zpool status -j $pool: widths $str, expected" \
		    "[\"$2\",\"$3\"]"
	fi
	if [[ "$int" != "[$2,$3]" ]]; then
		log_fail "zpool status -j --json-int $pool: widths $int," \
		    "expected [$2,$3]"
	fi
}

#
# Once the expansion has finished, the JSON object says so and has no
# widths.
#
function check_json_finished # <pool>
{
	typeset pool=$1
	typeset out=$(zpool status -j $pool | jq -c --arg p $pool \
	    '.pools[$p].raidz_expand_stats |
	    [.state, has("old_width"), has("new_width")]')

	if [[ "$out" != '["FINISHED",false,false]' ]]; then
		log_fail "zpool status -j $pool after the expansion: $out"
	fi
}

#
# Attach a paused expansion: wait until the copy stops, and check that it
# is still in progress.  The copy after the scratch step can be less than
# half of the allocated space (on raidz2 of 5 plus 3 it copies 27M of 55M),
# so it pauses at a quarter of it.
#
function attach_paused # <pool> <new disk> ...
{
	typeset pool=$1
	shift
	typeset -i reflow_size=$(get_pool_prop allocated $pool)

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES \
	    $((reflow_size / 4))
	log_must zpool attach $pool $vdev "$@"
	wait_raidz_expand_paused $pool
	log_must check_pool_status $pool "expand" "in progress"
}

function finish_expansion # <pool>
{
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must zpool wait -t raidz_expand $1
	log_must check_pool_status $1 "expand" "expanded $vdev copied"
	check_json_finished $1
}

#
# Count the lines of 'zpool history -i' that contain a string.
#
function count_history # <pool> <string>
{
	zpool history -i $1 | grep -cF -- "$2"
}

#
# 'zpool history -i' has exactly one "vdev attach" line for each new disk
# given, and no other.
#
function check_attach_history # <pool> <new disk> ...
{
	typeset pool=$1
	typeset -i n
	shift

	sync_pool $pool
	n=$(count_history $pool "] vdev attach attach vdev=")
	if (( n != $# )); then
		log_fail "expected $# vdev attach lines in the history of" \
		    "$pool, found $n"
	fi
	for disk in "$@"; do
		n=$(count_history $pool \
		    "] vdev attach attach vdev=$disk to vdev=$vdev")
		if (( n != 1 )); then
			log_fail "expected one vdev attach line for $disk in" \
			    "the history of $pool, found $n"
		fi
	done
}

#
# 'zpool history -i' has exactly one "started" and one "completed" line for
# the expansion to <width>.
#
function check_expand_history # <pool> <new width>
{
	typeset pool=$1
	typeset -i n

	sync_pool $pool
	for what in started completed; do
		n=$(count_history $pool \
		    "] raidz vdev expansion $what $pool vdev 0 new width $2")
		if (( n != 1 )); then
			log_fail "expected one \"raidz vdev expansion $what\"" \
			    "line with new width $2 in the history of $pool," \
			    "found $n"
		fi
	done
}

#
# Print the vdev_path of every vdev_attach event of a pool, one per line.
#
function attach_event_paths # <pool>
{
	zpool events -vH $1 | awk '
	    /^[^[:space:]]/ { class = $NF; next }
	    class == "sysevent.fs.zfs.vdev_attach" && $1 == "vdev_path" {
		gsub(/"/, "", $3); print $3
	    }'
}

#
# There is exactly one vdev_attach event for each new disk given, and no
# other.
#
function check_attach_events # <pool> <new disk> ...
{
	typeset pool=$1
	shift
	typeset -i n=$(zpool events -H $pool | \
	    grep -c 'sysevent\.fs\.zfs\.vdev_attach$')
	typeset got=$(attach_event_paths $pool | sort | xargs)
	typeset want=$(printf "%s\n" "$@" | sort | xargs)

	if (( n != $# )); then
		log_fail "expected $# vdev_attach events for $pool, found $n"
	fi
	if [[ "$got" != "$want" ]]; then
		log_fail "vdev_attach events for $pool are for '$got'," \
		    "expected '$want'"
	fi
}

log_onexit cleanup

log_assert "zpool shows and records the widths and new disks of a" \
    "several-disk raidz expansion, refuses -s and waits by GUID"

d=$TEST_BASE_DIR/dev-

for layout in "${layouts[@]}"; do
	set -- $layout
	typeset -i parity=$1 width=$2 added=$3
	typeset -a old=()
	typeset -a new=()
	typeset -a old1=()
	typeset -a new1=()
	vdev=raidz$parity-0

	log_note "raidz$parity of $width, attaching $added disks at once"

	#
	# The first pool has dev-1 to dev-<width> and the next <added> are
	# attached to it.  The second pool has the next <width>, the one
	# after them is attached alone, and the last <added> at once.
	#
	log_must rm -f $TEST_BASE_DIR/dev-*
	for i in {1..$((2 * width + 2 * added + 1))}; do
		log_must truncate -s ${dev_size_mb}M ${d}$i
	done
	for i in {1..$width}; do
		old[i]=${d}$i
		old1[i]=${d}$((width + added + i))
	done
	for i in {1..$added}; do
		new[i]=${d}$((width + i))
		new1[i]=${d}$((2 * width + added + 1 + i))
	done
	one=${d}$((2 * width + added + 1))

	# 1. A raidz of <width> with some data
	log_must zpool create -f -o cachefile=none $TESTPOOL \
	    raidz$parity "${old[@]}"
	log_must zfs create $TESTPOOL/fs
	log_must fill_fs /$TESTPOOL/fs 1 32 1048576 1 R
	log_must zpool events -c

	# 2. -s is refused for a raidz target, before any disk is labelled
	guid=$(get_vdev_prop guid $TESTPOOL $vdev)
	check_attach_s_refused $TESTPOOL $vdev ${new[1]}
	check_attach_s_refused $TESTPOOL $vdev "${new[@]}"
	check_attach_s_refused $TESTPOOL $guid "${new[@]}"
	check_width $TESTPOOL $width
	log_mustnot check_pool_status $TESTPOOL "expand" "expansion"
	check_attach_history $TESTPOOL
	log_mustnot eval "zpool history $TESTPOOL | grep -q 'zpool attach'"
	check_attach_events $TESTPOOL

	# 3. <added> disks, paused: from <width> to <width + added> disks
	attach_paused $TESTPOOL "${new[@]}"
	msg="expansion of $vdev from $width to $((width + added)) disks"
	log_must check_pool_status $TESTPOOL "expand" "$msg in progress since"
	check_json_widths $TESTPOOL $width $((width + added))
	check_width $TESTPOOL $((width + added))

	# 4. Finished: one history line and one event per new disk
	finish_expansion $TESTPOOL
	check_width $TESTPOOL $((width + added))
	check_attach_history $TESTPOOL "${new[@]}"
	check_expand_history $TESTPOOL $((width + added))
	check_attach_events $TESTPOOL "${new[@]}"
	is_pool_scrubbing $TESTPOOL && wait_scrubbed $TESTPOOL
	log_must zpool destroy $TESTPOOL

	# 5. One disk, paused: from <width> to <width + 1> disks
	log_must zpool create -f -o cachefile=none $TESTPOOL1 \
	    raidz$parity "${old1[@]}"
	log_must zfs create $TESTPOOL1/fs
	log_must fill_fs /$TESTPOOL1/fs 1 32 1048576 1 R
	attach_paused $TESTPOOL1 $one
	msg="expansion of $vdev from $width to $((width + 1)) disks"
	log_must check_pool_status $TESTPOOL1 "expand" "$msg in progress since"
	check_json_widths $TESTPOOL1 $width $((width + 1))
	finish_expansion $TESTPOOL1
	check_width $TESTPOOL1 $((width + 1))
	check_expand_history $TESTPOOL1 $((width + 1))

	# 6. -w with the raidz given by its GUID waits for the expansion
	guid=$(get_vdev_prop guid $TESTPOOL1 $vdev)
	log_must zpool attach -w $TESTPOOL1 $guid "${new1[@]}"
	status=$(zpool status $TESTPOOL1)
	if echo "$status" | grep -q 'expansion of .* in progress'; then
		log_note "$status"
		log_fail "zpool attach -w $TESTPOOL1 $guid returned before the" \
		    "expansion finished"
	fi
	log_must check_pool_status $TESTPOOL1 "expand" "expanded $vdev copied"
	check_json_finished $TESTPOOL1
	check_width $TESTPOOL1 $((width + 1 + added))
	check_attach_history $TESTPOOL1 $one "${new1[@]}"
	check_expand_history $TESTPOOL1 $((width + 1 + added))
	check_attach_events $TESTPOOL1 $one "${new1[@]}"
	is_pool_scrubbing $TESTPOOL1 && wait_scrubbed $TESTPOOL1
	log_must zpool destroy $TESTPOOL1
done

log_pass "zpool shows and records the widths and new disks of a" \
    "several-disk raidz expansion, refuses -s and waits by GUID"
