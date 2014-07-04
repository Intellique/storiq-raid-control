storiq-lib-raid
===============

This is the RAID monitoring StorIQ tool.

Simply build the content of the repository as a Debian package :

dpkg --build .  ../storiq-raid-control_<version>_all.deb

And install the package. The resulting package works on Squeeze and Wheezy.

For Adaptec, LSI Megaraid, 3Ware and Xyratex controllers, you'll need the additional proprietary command line tools. LVM, MD raid and DDN controllers work without any tools other than the usual lvm2 tools, mdadm and ssh.
