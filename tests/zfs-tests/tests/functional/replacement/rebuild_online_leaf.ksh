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
# A leaf onlined while a sequential rebuild runs must be resilvered,
# and the rebuild must not copy its stale data to the new leaf.  When
# the scrub after the rebuild is enabled, it must still cover the
# whole pool.
#
# STRATEGY:
# Once with the scrub after the rebuild disabled, which would otherwise
# repair both leaves, and once with it enabled:
# 1. Create a two-way mirror, write file A, offline the second leaf
#    and write file B, which that leaf misses.
# 2. With the rebuild paused, attach a third leaf with 'zpool attach -s'
#    and online the second leaf.
# 3. Resume the rebuild and wait for it, for the resilver of the
#    onlined leaf and, if enabled, for the scrub.  An enabled scrub
#    must not be limited to the txgs the onlined leaf missed.
# 4. Move the other leaves away and import the pool read-only from the
#    onlined leaf alone, then from the new leaf alone, and verify A and
#    B each time.
#

verify_runnable "global"

DIR=$TEST_BASE_DIR/rebuild_online_leaf
REF=$DIR/ref

function cleanup
{
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS \
	    $ORIG_SCAN_SUSPEND_PROGRESS
	log_must set_tunable32 REBUILD_SCRUB_ENABLED \
	    $ORIG_REBUILD_SCRUB_ENABLED
	poolexists $TESTPOOL1 && destroy_pool $TESTPOOL1
	rm -rf $DIR
}

function write_file # name
{
	log_must dd if=/dev/urandom of=$REF/$1 bs=1M count=32
	log_must cp $REF/$1 /$TESTPOOL1/$1
	sync_pool $TESTPOOL1
}

# Import the pool read-only from the leaf in directory $1 alone.  The
# other leaves are moved away, or the import would open them by path.
function check_leaf # dir
{
	typeset d f
	typeset bad=""

	for d in d0 d1 d2; do
		[[ $d == "$1" ]] || log_must mv $DIR/$d/f $DIR/away/$d
	done
	if zpool import -o readonly=on -d $DIR/$1 $TESTPOOL1; then
		for f in A B; do
			cmp -s $REF/$f /$TESTPOOL1/$f || bad="$bad $f"
		done
	else
		bad=" (import failed)"
	fi
	if poolexists $TESTPOOL1; then
		zpool status -v $TESTPOOL1
		log_must zpool export $TESTPOOL1
	fi
	for d in d0 d1 d2; do
		[[ $d == "$1" ]] || log_must mv $DIR/away/$d $DIR/$d/f
	done
	[[ -z "$bad" ]] || log_fail "leaf $1 alone is missing data:$bad"
}

function run_case # scrub_enabled
{
	typeset scrub=$1
	typeset -i timer n

	rm -rf $DIR
	# Each leaf in its own directory, so the pool can be imported from
	# one.
	log_must mkdir -p $DIR/d0 $DIR/d1 $DIR/d2 $DIR/away $REF
	log_must truncate -s 512M $DIR/d0/f $DIR/d1/f $DIR/d2/f
	log_must zpool create -f $TESTPOOL1 mirror $DIR/d0/f $DIR/d1/f
	write_file A
	log_must zpool offline $TESTPOOL1 $DIR/d1/f
	write_file B

	log_must set_tunable32 REBUILD_SCRUB_ENABLED $scrub
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 1
	log_must zpool events -c
	log_must zpool attach -s $TESTPOOL1 $DIR/d0/f $DIR/d2/f
	log_must zpool online $TESTPOOL1 $DIR/d1/f
	log_must set_tunable32 SCAN_SUSPEND_PROGRESS 0

	# The rebuild, then the resilver of d1 it requests when it ends.
	log_must zpool wait -t resilver $TESTPOOL1
	for (( timer = 0; timer < 60; timer++ )); do
		n=$(zpool events -H $TESTPOOL1 | \
		    grep -c sysevent.fs.zfs.resilver_finish)
		(( n >= 2 )) && break
		sleep 1
	done
	(( n >= 2 )) || log_note "scrub=$scrub: only $n resilver_finish" \
	    "events after 60 seconds"
	log_must zpool wait -t resilver $TESTPOOL1

	if (( scrub )); then
		log_must zpool wait -t scrub $TESTPOOL1
		typeset last=$(zpool history -i $TESTPOOL1 | \
		    grep "scan setup" | tail -1)
		log_note "scrub=$scrub: $last"
		[[ "$last" == *"func=1 mintxg=0 "* ]] || \
		    log_fail "the scrub after the rebuild was not a full scrub"
	fi
	zpool events $TESTPOOL1
	zpool status -v $TESTPOOL1

	log_must zpool export $TESTPOOL1
	check_leaf d1
	check_leaf d2
	log_must zpool import -d $DIR/d0 -d $DIR/d1 -d $DIR/d2 $TESTPOOL1
	destroy_pool $TESTPOOL1
}

log_assert "A leaf onlined during a rebuild is resilvered, not copied"

ORIG_SCAN_SUSPEND_PROGRESS=$(get_tunable SCAN_SUSPEND_PROGRESS)
ORIG_REBUILD_SCRUB_ENABLED=$(get_tunable REBUILD_SCRUB_ENABLED)

log_onexit cleanup

run_case 0
run_case 1

log_pass "A leaf onlined during a rebuild is resilvered, not copied"
