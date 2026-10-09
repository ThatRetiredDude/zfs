#!/bin/bash
# Run inside a DISPOSABLE Ubuntu 24.04 VM as a normal user with sudo.
# Never run this on a machine with real ZFS pools: it loads/unloads the
# zfs kernel modules and the test suite creates and destroys pools.
#
# Usage: bash vm-run.sh <dir containing fix.patch, vmA.run, vmB.run>
set -euo pipefail
SRC=$(cd "$1" && pwd)
W=$HOME/zts
OUT=$W/out
mkdir -p "$W" "$OUT"
exec > >(tee -a "$OUT/vm-run.log") 2>&1

sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    build-essential autoconf automake libtool gawk alien fakeroot dkms \
    libblkid-dev uuid-dev libudev-dev libssl-dev zlib1g-dev libaio-dev \
    libattr1-dev libelf-dev libtirpc-dev libffi-dev python3 python3-dev \
    python3-setuptools python3-cffi linux-headers-"$(uname -r)" \
    ksh bc fio acl attr jq lsscsi parted sysstat xxhash pax git

cd "$W"
[ -d zfs ] || git clone https://github.com/openzfs/zfs.git
cd zfs
git fetch origin refs/pull/18324/head:pr18324
git worktree add -f "$W/base" pr18324 2>/dev/null || true
git worktree add -f --detach "$W/fix" pr18324 2>/dev/null || true
git -C "$W/fix" -c user.name=t -c user.email=t@t am "$SRC/fix.patch"
# Give the original PR the new test too, so 013 runs on both.
git -C "$W/fix" diff pr18324 HEAD -- tests | git -C "$W/base" apply

for t in base fix; do
	cp "$SRC"/vmA.run "$SRC"/vmB.run "$W/$t/tests/runfiles/"
	cd "$W/$t"
	./autogen.sh && ./configure --enable-debug && make -j"$(nproc)"
done

mkdir -p /var/tmp/zts 2>/dev/null || sudo mkdir -p /var/tmp/zts
sudo chmod 1777 /var/tmp/zts
run() {
	local t=$1 p=$2
	echo "=== $t $p $(date)" | tee -a "$OUT/progress.log"
	cd "$W/$t"
	sudo ./scripts/zfs.sh -u || true
	sudo ./scripts/zfs.sh
	set +e
	./scripts/zfs-tests.sh -v -d /var/tmp/zts -s 2G -r "vm$p" \
	    > "$OUT/zts-$t-$p.log" 2>&1
	echo "$t $p: exit $? $(date)" | tee -a "$OUT/progress.log"
	set -e
	cp -r /var/tmp/test_results "$OUT/results-$t-$p" 2>/dev/null || true
	sudo rm -rf /var/tmp/test_results
	sudo dmesg > "$OUT/dmesg-$t-$p.log"
	sudo ./scripts/zfs.sh -u || true
}
run base A
run fix A
run fix B
run base B
echo "=== all done $(date)" | tee -a "$OUT/progress.log"
