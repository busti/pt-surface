#!/bin/bash

linux_version_major="4.19"
linux_version_minor="98"
linux_version="v${linux_version_major}${linux_version_minor}"

function first_stage() {
	echo "Hello, World!" #Its tradition
}

function second_stage() {
	set -e
	apt install -y git
	
	mkdir /root/bootstrap
	( cd /root/bootstrap;
		sudo apt install -y build-essential binutils-dev libncurses5-dev libssl-dev ccache bison flex libelf-dev
		git clone --depth 1 https://github.com/linux-surface/linux-surface linux-surface/
		git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-kernel/
		git clone https://github.com/linux-surface/linux-surface-kernel-configs kernel-configs/
	
		( cd linux-kernel/;
			git checkout ${linux_version}
			git switch -c ${linux_version}-surface
			for i in /root/bootstrap/linux-surface/patches/${linux_version_major}/*.patch; do patch -p1 < $i; done
			cp kernel-configs/debian-${linux_version_major}-x86_64.config/ .config
			make -j `getconf _NPROCESSORS_ONLN` deb-pkg LOCALVERSION=-linux-surface
		)
	
		dpkg -i linux*.deb
	)
}
