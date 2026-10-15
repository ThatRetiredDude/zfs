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
#	During a raidz expansion by several disks, a block that straddles
#	the reflow offset has rows at their new location and rows still at
#	their old one, which is narrower by the number of added disks.
#	Damage from a single failed disk must remain repairable in such a
#	block, also when the reflow has copied some of the damage to the
#	new location.  This is raidz_expand_boundary_repair with several
#	disks attached at once, for raidz1, raidz2 and raidz3.
#
# STRATEGY:
#	For each layout (parity, old width, disks added):
#	1. Create a raidz pool, write a file and attach the new disks with
#	   the reflow paused early on.
#	2. Export the pool and zero the part of one old disk that holds the
#	   data the reflow has not copied yet: the disk with a data column
#	   of the most blocks that the pauses of steps 3 and 4 can reach.
#	3. Import the pool and let the reflow copy a little more of the
#	   data, a sector at a time, with the writes to one new disk delayed
#	   and the pool synced all the while, so that it pauses soon after
#	   the amount asked for, inside a block.  It copies the damage
#	   along, spread over all disks.
#	4. Verify that a block of the file straddles the new reflow offset,
#	   with its first part copied from the damaged area and a data
#	   column on the zeroed disk (if none does, move the pause point on
#	   a little and look again; if the expansion ends first, start the
#	   layout again on a new pool).  Every row of that block has one
#	   damaged sector, on the zeroed disk in the rows at the old
#	   location and wherever the reflow put it in the others.
#	5. Scrub with the reflow paused.  Verify that it found no data
#	   errors and that the file is intact.
#	6. Let the expansion finish, scrub again and verify that it repairs
#	   nothing.
#

verify_runnable "global"

typeset -r dev_size_mb=256
#
# Parity, old width, disks added.  In none of them is the new width minus
# one a multiple of the old width, so numbering the rows at the old
# location by that width instead of by the old one would point a simulated
# failure of the zeroed disk at other sectors there.
#
typeset -a layouts=("1 3 3" "2 5 2" "3 6 3")
# A directory of our own, so that zdb -e and zpool import only see this pool.
typeset -r devdir=$TEST_BASE_DIR/raidz_expand_multi_011_pos

# The layout being tested, for parity_on_disk().
typeset -i parity width added

prefetch_disable=$(get_tunable PREFETCH_DISABLE)
scrub_after_expand=$(get_tunable SCRUB_AFTER_EXPAND)
max_copy_bytes=$(get_tunable RAIDZ_EXPAND_MAX_COPY_BYTES)

function cleanup
{
	log_must zinject -c all
	poolexists "$TESTPOOL" && log_must_busy zpool destroy "$TESTPOOL"

	log_must rm -rf "$devdir"

	log_must set_tunable32 PREFETCH_DISABLE $prefetch_disable
	log_must set_tunable32 SCRUB_AFTER_EXPAND $scrub_after_expand
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $max_copy_bytes
}

function reflowed # pool
{
	zpool status -jp $1 | jq -r '.pools[].raidz_expand_stats.reflowed'
}

#
# Let the reflow go on until it has copied $1 bytes and wait for it to
# pause.  It only notices that it has reached the pause point when a txg
# syncs, so sync the pool all the while.
#
function reflow_until # bytes
{
	typeset -i t0=$SECONDS

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES $1
	while (( $(reflowed $TESTPOOL) < $1 )); do
		zpool status $TESTPOOL | \
		    grep -q 'expansion of .* in progress' || return
		(( SECONDS - t0 < 300 )) || \
		    log_fail "the reflow did not copy $1 bytes in 300 seconds"
		log_must zpool sync $TESTPOOL
	done
	# What was copied since the last sync counts once its txg has synced.
	log_must zpool sync $TESTPOOL
	wait_raidz_expand_paused $TESTPOOL
}

#
# The reflow offset (in the raidz vdev's address space) of the exported pool.
#
function reflow_offset
{
	zdb -e -p $devdir -u $TESTPOOL | \
	    awk '/raidz_reflow/ { sub("off=", "", $3); print $3 }'
}

#
# Print the offset and allocated size of each level 0 block of the file in
# the exported pool, in decimal.
#
function file_blocks # object
{
	zdb -e -p $devdir -ddddd $TESTPOOL/fs $1 | \
	    awk '$2 == "L0" { print $3 }' | while IFS=: read _ off asize; do
		echo $((16#$off)) $((16#$asize))
	done
}

#
# Is the column of the block at vdev offset $2 on old disk $1 a parity
# column?  The block was written $width wide.  In the rows at the old
# location, column c is on old disk (offset / 4k + c) % width in every
# row, and columns 0 to parity - 1 hold the parity, except that raidz1
# swaps the first two columns in every other MiB (see
# vdev_raidz_map_alloc_expanded()).
#
function parity_on_disk # disk off
{
	typeset -i first

	(( first = $2 / 4096 ))
	if (( parity == 1 && (($2 >> 20) & 1) )); then
		(( first += 1 ))
	fi
	(( ($1 + width - first % width) % width < parity ))
}

#
# Damage an old disk of a raidz$1 vdev $2 disks wide while it is expanded
# by $3 disks, scrub with a block straddling the reflow offset and verify
# the damage is repaired.  Return 1 if the reflow did not stop inside a
# suitable block.
#
function test_layout # parity width added
{
	typeset -a disks newdisks votes
	typeset -i i disk straddling=0 reach=0
	typeset device digest object allocated offset1 offset2 row rowsize
	typeset blocks slow before off asize

	parity=$1
	width=$2
	added=$3
	# The file takes a quarter to a third of the space of the old disks.
	typeset -i file_mb
	(( file_mb = 40 * width ))

	log_note "raidz$parity, $width -> $((width + added)) wide"
	log_must mkdir -p $devdir
	for i in {0..$((width + added - 1))}; do
		device=$devdir/dev-$i
		log_must truncate -s ${dev_size_mb}M $device
		if (( i < width )); then
			disks[${#disks[*]}+1]=$device
		else
			newdisks[${#newdisks[*]}+1]=$device
		fi
	done

	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $max_copy_bytes
	log_must zpool create -f -o cachefile=none -o ashift=12 $TESTPOOL \
	    raidz$parity "${disks[@]}"
	log_must zfs create -o recordsize=128k -o compression=off \
	    -o primarycache=metadata $TESTPOOL/fs
	log_must dd if=/dev/urandom of=/$TESTPOOL/fs/file bs=1M count="$file_mb"
	digest=$(xxh128digest /$TESTPOOL/fs/file)
	object=$(ls -i /$TESTPOOL/fs/file | awk '{print $1}')

	log_must zpool sync $TESTPOOL
	allocated=$(get_pool_prop allocated $TESTPOOL)
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES $((allocated / 80))
	log_must zpool attach "$TESTPOOL" "raidz$parity-0" "${newdisks[@]}"
	wait_raidz_expand_paused $TESTPOOL
	log_must zpool export $TESTPOOL

	offset1=$(reflow_offset)
	log_note "reflow offset $offset1 after the first pause"
	(( offset1 > 0 )) || log_fail "no reflow offset in the uberblock"
	blocks=$(file_blocks $object)
	[[ -n $blocks ]] || log_fail "zdb shows no blocks of the file"

	#
	# The scrub must find damaged data in the block that will straddle
	# the reflow offset, so the column of that block on the zeroed disk
	# must not be parity (see parity_on_disk()), or the scrub finds the
	# data intact and only rewrites the parity.  Which block that will
	# be is not known yet: take the old disk that has a data column of
	# the most blocks the pauses below can reach, the first allocated / 8
	# bytes of the file past the reflow offset (20 pauses of allocated /
	# 160).  Not of the whole file: the blocks of a contiguous run start
	# at the same sector modulo the width, and raidz1 swaps its parity
	# and first data column every other MiB, so a disk with a data
	# column of most blocks of the file can have the parity of every
	# block in every other MiB of the run the pauses land in.
	#
	for (( i = 0; i < width; i++ )); do
		votes[i]=0
	done
	echo "$blocks" | sort -n | while read off asize; do
		(( off >= offset1 )) || continue
		(( reach < allocated / 8 )) || break
		(( reach += asize ))
		for (( i = 0; i < width; i++ )); do
			parity_on_disk $i "$off" || (( votes[i] += 1 ))
		done
	done
	disk=0
	for (( i = 1; i < width; i++ )); do
		(( votes[i] > votes[disk] )) && disk=$i
	done
	log_note "disk $disk has a data column of ${votes[disk]} of the" \
	    "blocks the pauses can reach"

	#
	# Rows past the reflow offset are still at their old location, as
	# wide as the old disks, row r on each of them at byte offset 4M (the
	# labels and boot area) + r * 4k.  Zero the disk from the first such
	# row on.  The copied part of the pool is in the rows before that
	# (they are wider) and stays intact.
	#
	row=$((offset1 / 4096 / width))
	log_must dd conv=notrunc if=/dev/zero of=$devdir/dev-$disk bs=4k \
	    seek=$((1024 + row)) count=$((dev_size_mb * 256 - 1024 - row - 256))

	log_must zpool import -o cachefile=none -d $devdir $TESTPOOL

	#
	# Left alone, the reflow copies on until the next txg syncs.  By
	# then it has usually reached the limit of what it may copy in one
	# txg, which is added / width of the offset on disk further on, and
	# with several disks added that is far away and often in free space.
	# So copy a sector at a time, slow the copy down by delaying the
	# writes to one new disk, and sync the pool all the while (see
	# reflow_until()): then the reflow pauses soon after the amount
	# asked for, somewhere in the data.
	#
	# It can still pause between two blocks.  Move the pause point on
	# until a block straddles the offset, with at least one full row on
	# either side (a full row of the block spans every old disk; the
	# last row can be shorter) and a data column on the zeroed disk.
	#
	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES 4096
	slow=$devdir/dev-$((width + added - 1))
	rowsize=$((width * 4096))
	for (( i = 0; i < 20 && straddling == 0; i++ )); do
		log_must zinject -d $slow -D 10:1 $TESTPOOL
		reflow_until $(($(reflowed $TESTPOOL) + allocated / 160))
		log_must zinject -c all
		log_must zpool export $TESTPOOL

		offset2=$(reflow_offset)
		log_note "reflow offset $offset2 after the second pause"
		echo "$blocks" | while read off asize; do
			if (( off >= offset1 && off + rowsize <= offset2 &&
			    offset2 + 2 * rowsize <= off + asize )) &&
			    ! parity_on_disk $disk "$off"; then
				log_note "block at $off (asize $asize)" \
				    "straddles it"
				(( straddling += 1 ))
			fi
		done
		log_must zpool import -o cachefile=none -d $devdir $TESTPOOL
		# The offset is 0 once the expansion is done.
		(( offset2 > 0 )) || break
	done
	if (( straddling == 0 )); then
		log_note "no block of the file straddles the reflow offset"
		log_must zpool destroy "$TESTPOOL"
		log_must rm -rf "$devdir"
		return 1
	fi

	before=$(reflowed $TESTPOOL)
	log_must zpool scrub -w $TESTPOOL
	log_note "reflowed $before before the scrub, $(reflowed $TESTPOOL)" \
	    "after it"
	log_must eval "zpool status -v $TESTPOOL"
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must eval "zpool status $TESTPOOL | \
	    grep -q 'expansion of .* in progress'"
	log_mustnot check_pool_status $TESTPOOL "scan" "repaired 0B"
	[[ $(xxh128digest /$TESTPOOL/fs/file) == "$digest" ]] || \
	    log_fail "the file changed"
	log_must zpool clear $TESTPOOL

	log_must set_tunable64 RAIDZ_EXPAND_MAX_COPY_BYTES $max_copy_bytes
	log_must set_tunable64 RAIDZ_EXPAND_MAX_REFLOW_BYTES 0
	log_must zpool wait -t raidz_expand $TESTPOOL
	log_must zpool scrub -w $TESTPOOL
	log_must eval "zpool status -v $TESTPOOL"
	log_must check_pool_status $TESTPOOL "errors" "No known data errors"
	log_must check_pool_status $TESTPOOL "scan" "repaired 0B"
	[[ $(xxh128digest /$TESTPOOL/fs/file) == "$digest" ]] || \
	    log_fail "the file changed"

	log_must zpool destroy "$TESTPOOL"
	log_must rm -rf "$devdir"
	return 0
}

log_onexit cleanup

log_must set_tunable32 PREFETCH_DISABLE 1
log_must set_tunable32 SCRUB_AFTER_EXPAND 0

typeset -i tries
for layout in "${layouts[@]}"; do
	tries=0
	# shellcheck disable=SC2086
	until test_layout $layout; do
		(( ++tries < 3 )) || log_unsupported "raidz layout $layout:" \
		    "no block of the file straddles the reflow offset"
	done
done

log_pass "Damage across the reflow offset of an expansion by several disks" \
    "is repairable."
