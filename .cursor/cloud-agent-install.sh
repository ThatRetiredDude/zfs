#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
	acl attr autoconf automake bc build-essential cpio curl \
	fakeroot gdb git ksh libacl1-dev libaio-dev libattr1-dev \
	libblkid-dev libcurl4-openssl-dev libelf-dev libffi-dev \
	libmount-dev libpam0g-dev libselinux-dev libssl-dev \
	libtirpc-dev libtool libtool-bin libudev-dev libunwind-dev \
	pkg-config python3 python3-cffi python3-dev python3-packaging \
	python3-setuptools python3-sphinx uuid-dev zlib1g-dev \
	parallel shellcheck devscripts cppcheck mandoc pax-utils gettext
./autogen.sh
./configure --with-config=user --enable-debug --enable-debuginfo
make -j"$(nproc)"
