#!/bin/bash

##############################################################################
#                                                                            #
# setup-vm-builder.sh - Download CentOS boot images and set them up for use  #
#                       by vm-builder. This is a basic example of what needs #
#                       to be done. Make *SURE* to properly set the ks= line #
#                       to a valid ks.cfg.                                   #
#                                                                            #
##############################################################################

# -*- mode: sh; -*-
# vim:textwidth=78:

# $Id$

# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
# Written by: Jeff Schroeder
# (C) Copyright Ticketmaster, Inc. 2007
#

# Exits on any error
set -e

if [ -f '/etc/vm-builder/vmware-gsx.conf' ]; then
	. /etc/vm-builder/vmware-gsx.conf
else
	echo "ERROR: Could not load required configuration file!" >&2
	exit 1
fi


if [ "$(id -u 2>/dev/null)" != "0" ]; then
	echo "ERROR: try sudo $0 or running it as root" >&2
	exit 255
fi

TEMPDIR="$(mktemp -d)"

mkdir -p ${IMAGEDIR} ${TEMPLATES}/{linux,win2k3}

mkdir -p ${TEMPDIR}/{ro,rw}
cd "$TEMPDIR"

# Download CentOS 4.6 and 5.1 images to setup and use
for dist in 4.6 5.1; do

  # Download disk images for both 32 and 64 bit x86 installs
  for arch in i386 x86_64; do

	filename="centos${dist}_${arch}.iso"
  	
	# Lets not overwrite existing files
	if [ -e "${IMAGEDIR}/${filename}" ]; then
		echo "${IMAGEDIR}/${filename} already exists. Skipping" >&2
		continue
	fi

	if [ ! -x "$(which mkisofs)" ]; then
		echo "ERROR: install mkisofs or make sure it is in \$PATH"
		exit 1
	fi

	echo -n "Downloading CentOS ${dist} for ${arch}... "
	wget -q -o ${TEMPDIR}/wget.log -c http://mirrors.usc.edu/pub/linux/distributions/centos/${dist}/os/${arch}/images/boot.iso \
		 -O ${TEMPDIR}/${filename} \
			 || { echo "Could not download boot.iso"; exit 1; }
	echo "done"

	mount -t iso9660 -o loop ${TEMPDIR}/${filename} ro/
	rsync -a ro/ rw/

	cat << EOF > rw/isolinux/isolinux.cfg
default linux
prompt 1
timeout 1
label linux
kernel vmlinuz
##### EDIT THE ks= LINE TO A VALID ks.cfg. THIS IS CENTOS $dist FOR $arch
append initrd=initrd.img text ramdisk_size=8192 ks=http://your.kickstartserver/kickstart/centos${dist}-${arch}-ks.cfg ksdevice=eth0 keeppxe nofb
EOF

	chmod 644 rw/isolinux/isolinux.cfg

	# Some people are weird and prefer emacs or nano
	if [ "$EDITOR" ]; then
		$EDITOR rw/isolinux/isolinux.cfg
	else
		vi rw/isolinux/isolinux.cfg
	fi

	# Seriously, I hate mkisofs. This was a pain to figure out
	mkisofs -o ${BASEDIR}/images/ks/${filename}  \
	  -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot \
	  -boot-load-size 5 -boot-info-table -l -R  -r rw/ >/dev/null 2>&1 \
		   || { echo "$filename" creation failed; exit 1; }

	echo "Wrote: ${IMAGEDIR}/${filename}"

	umount ro
	rm -rf ro/* rw/*
  done
done

rm -rf "$TEMPDIR" 

cat << EOF

vm-builder is now setup! Just run vm_builder with no arguments to
see a list of of available installation images to choose from. If you
didn't put a valid ks= line in the configuration when they were opened,
you can remove them from /etc/vm-builder/images/ks/*.iso and run this
again.

Example Usage:
# vm-builder -d centos5.1_i386 -h web001.yourdomain.com -m 256
EOF
