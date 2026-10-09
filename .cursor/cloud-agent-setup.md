# Cloud Agent setup record

This file records the OpenZFS userspace environment prepared on
2026-10-09 for the fork `github.com/ThatRetiredDude/zfs-18324`.
The branch that carries it is `cursor/cloud-agent-userspace-6bac`.

`.cursor/environment.json` points `install` at
`.cursor/cloud-agent-install.sh`. A committed `environment.json`
is the environment source for agents that start from a revision
that contains it. There is no `start` command: OpenZFS has no
long-running dev server in this setup.

## Why userspace only

The agent VM was Ubuntu 24.04.5 LTS with kernel `6.12.94+`.
That kernel does not ship matching `linux-headers-$(uname -r)`,
so `./configure` (default `--with-config=all`) cannot build
kernel modules. The install script uses the same userspace
configuration as `.github/workflows/unit-tests.yml`:

```sh
./configure --with-config=user --enable-debug --enable-debuginfo
```

Leave `scripts/zfs.sh` and `zfs-tests.sh` unused. They load
kernel modules and create and destroy pools.

## What the install script does

1. `apt-get update` and install the userspace build packages
   (autoconf, libssl, libaio, Python cffi, checkstyle tools,
   and the other packages listed in the script).
2. `./autogen.sh`
3. `./configure --with-config=user --enable-debug --enable-debuginfo`
4. `make -j$(nproc)`

The script was run twice on the setup VM. Both runs exited 0.

## Checks that passed

Tool versions on the setup VM: gcc 13.3.0, GNU Make 4.3,
Python 3.12.3.

`make unit` after the second install, exit 0:

| Binary | Result |
| --- | --- |
| test_zap | 59 of 59 |
| test_namecheck | 8 of 8 |
| test_btree | 8 of 8 |
| test_fletcher | 7 of 7 |
| test_sha2 | 7 of 7 |
| test_cityhash | 3 of 3 |
| test_nvpair | 60 of 60 |

Short `ztest` from a scratch directory, exit 0:

```sh
mkdir -p /var/tmp/zfs-ztest
./ztest -f /var/tmp/zfs-ztest -K raidz -v 3 -s 64M -m 2 \
	-r 3 -d 2 -t 4 -T 40 -P 15 -V
rm -rf /var/tmp/zfs-ztest
```

## Cursor environment ids

These ids belong to the Cursor environment draft created during
setup. They are not used as the base image in
`environment.json`. New agents that use this branch run the
install script on Cursor's default image.

| Item | Id |
| --- | --- |
| Environment | `540338b1-c408-11f1-ac31-5e2d0494121f` |
| VM snapshot | `snapshot-20261009-46986004-30b5-4a1a-ae9d-6947c0e33698` |
| Draft build | `bld-20261009-8f5b5844-0cc0-4688-9fcf-e9c8679dde5c` |

The draft build ran this same install and exited 0. A fresh
Cloud Agent booted from that build, on `master` at
`5d1ed14b3eb5d83158c12cd9c1b49fc1fc3677d1`, and reported gcc
13.3.0, GNU Make 4.3, Autoconf 2.71, Python 3.12.3,
`pkg-config libcrypto` present, `make unit` exit 0, and
`ztest` exit 0. `/tmp/cursor/start-user/` was absent, which
matches having no `start` script.
