#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2026 by Skountz. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	Blocks born in the same txg in which raidz_expansion_accounting is
#	enabled (on an already-expanded pool) must be freed with the same
#	deflated size they were charged at birth.
#
#	Sync tasks run after dirty datasets are synced, so data dirtied in
#	the enabling txg is charged before the feature activates.  If the
#	per-birth-txg boundary were the enabling txg itself, those blocks
#	would be freed at the new (larger) ratio and the dataset's used
#	space would drop below its starting value (or wrap).
#
# STRATEGY:
#	1. Create a RAIDZ1 pool with 3 disks, feature disabled
#	2. Expand to 4 disks and wait for the expansion to finish
#	3. Record the dataset's used space
#	4. With a long txg timeout, dirty data and enable the feature so
#	   both land in the same txg
#	5. Delete the data and verify used space returns to its baseline
#	6. Repeat the delete check after export/import
#

typeset -r devs=4
typeset -r dev_size_mb=512
typeset -r write_mb=32

typeset -a disks

txg_timeout=$(get_tunable TXG_TIMEOUT)

function cleanup
{
	log_must set_tunable64 TXG_TIMEOUT $txg_timeout
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	for i in {1..$devs}; do
		log_must rm -f "$TEST_BASE_DIR/dev-$i"
	done
}

log_onexit cleanup

for i in {1..$devs}; do
	device=$TEST_BASE_DIR/dev-$i
	log_must truncate -s ${dev_size_mb}M $device
	disks[${#disks[*]}+1]=$device
done

pool=$TESTPOOL

function check_used # <label> <baseline>
{
	typeset label=$1
	typeset baseline=$2
	typeset used=$(zfs get -Hpo value used $pool/fs)
	typeset slack=$((1024 * 1024))

	log_note "$label: used=$used baseline=$baseline"
	if [[ $used -lt $(($baseline - $slack)) ||
	    $used -gt $(($baseline + $slack)) ]]; then
		log_fail "$label: used ($used) does not match baseline" \
		    "($baseline); blocks were freed with a different" \
		    "deflated size than they were born with."
	fi
}

log_must zpool create -f -o cachefile=none \
    -o feature@raidz_expansion_accounting=disabled \
    $pool raidz1 ${disks[1..3]}
log_must zfs create $pool/fs

log_must zpool attach -w $pool raidz1-0 ${disks[4]}
is_pool_scrubbing $pool && wait_scrubbed $pool
log_must sync_pool $pool

typeset baseline=$(zfs get -Hpo value used $pool/fs)

#
# Keep the open txg open long enough that the dirty data and the
# feature-enable sync task are synced in the same txg.
#
log_must set_tunable64 TXG_TIMEOUT 600
log_must dd if=/dev/urandom of=/$pool/fs/same_txg bs=1M count=$write_mb
log_must zpool set feature@raidz_expansion_accounting=enabled $pool
log_must set_tunable64 TXG_TIMEOUT $txg_timeout

typeset feat=$(zpool list -H -o feature@raidz_expansion_accounting $pool)
[[ "$feat" == "active" ]] || log_fail "feature should be active, got $feat"

# Data written after activation, for comparison.
log_must dd if=/dev/urandom of=/$pool/fs/after bs=1M count=$write_mb
log_must sync_pool $pool

log_must rm -f /$pool/fs/same_txg
log_must sync_pool $pool
log_must rm -f /$pool/fs/after
log_must sync_pool $pool
check_used "after delete" $baseline

# The boundary must be the same after re-import.
log_must dd if=/dev/urandom of=/$pool/fs/again bs=1M count=$write_mb
log_must sync_pool $pool
log_must zpool export $pool
log_must zpool import -d $TEST_BASE_DIR $pool
log_must rm -f /$pool/fs/again
log_must sync_pool $pool
check_used "after re-import and delete" $baseline

log_must zpool scrub -w $pool
verify_pool $pool

log_pass "Blocks born in the enabling txg are freed with their birth size."
