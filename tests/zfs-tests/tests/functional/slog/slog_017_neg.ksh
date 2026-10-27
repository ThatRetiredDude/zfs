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

. $STF_SUITE/tests/functional/slog/slog.kshlib

#
# DESCRIPTION:
#	Removing a faulted log device that still holds log blocks fails
#	cleanly: the pool is not suspended, other zpool commands work and
#	the log device stays in the pool.  Once the device is back, the
#	removal succeeds.
#
# STRATEGY:
#	1. Create a pool with a log device, sync writes, then unmount the
#	   file system so its log chain stays on the log device.
#	2. Fault the log device with zinject.
#	3. Verify "zpool remove" of the log device fails.
#	4. Verify the pool is not suspended and the log device is still
#	   part of the pool.
#	5. Clear the fault, verify "zpool remove" succeeds.
#

verify_runnable "global"

function cleanup_testenv
{
	zinject -c all >/dev/null 2>&1
	cleanup
}

log_assert "Removing a faulted log device with log blocks fails cleanly."
log_onexit cleanup_testenv
log_must setup

log_must zpool create -O sync=always -O compression=off \
    $TESTPOOL $VDEV log $SDEV
log_must zfs create $TESTPOOL/$TESTFS
for i in {1..20}; do
	log_must dd if=/dev/urandom of=/$TESTPOOL/$TESTFS/file.$i \
	    bs=128k count=8 conv=fsync
done
log_must zfs unmount $TESTPOOL/$TESTFS
log_must zpool sync $TESTPOOL

alloc=$(zpool list -HpvP -o name,alloc $TESTPOOL | \
    awk -v d="$SDEV" '$1 == d {print $2}')
log_note "log device allocated: $alloc"
[[ -n "$alloc" && "$alloc" != "0" && "$alloc" != "-" ]] || \
    log_unsupported "log device holds no blocks, removal path not reached"

log_must zinject -d $SDEV -A fault $TESTPOOL
log_must verify_slog_device $TESTPOOL $SDEV 'FAULTED'

log_mustnot zpool remove $TESTPOOL $SDEV

log_must zpool status $TESTPOOL
log_mustnot eval "zpool status $TESTPOOL | grep -q suspended"
log_must eval "zpool status -P $TESTPOOL | grep -qF $SDEV"
log_must check_state $TESTPOOL "" "DEGRADED"

log_must zinject -c all
log_must zpool clear $TESTPOOL
log_must zpool remove $TESTPOOL $SDEV
log_must zpool wait -t remove $TESTPOOL
log_mustnot eval "zpool status -P $TESTPOOL | grep -qF $SDEV"

log_pass "Removing a faulted log device with log blocks fails cleanly."
