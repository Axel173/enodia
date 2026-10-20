NFQUEUE support profiles

These archives are authenticated data inside Enodia's signed code package. They are
installed on demand through the Zapret component. Profiles match the model, firmware,
kernel build, kernel configuration, stock netfilter module and userspace libraries.
A matching kernel release number alone does not establish compatibility.

ax3600-stock-1.1.21: Xiaomi R3600 stock ROM 1.1.21, Linux 4.4.60, aarch64.
No other firmware or BE3600 variant is covered by this profile.

nfnetlink_queue.ko, xt_NFQUEUE.ko, iptable_raw.ko and xt_CT.ko are Linux/QSDK modules
under GPL-2.0, built from the corresponding netfilter sources in:
https://github.com/Smolder3955/ipq8074/tree/ed68915f52872d1682fd3b2dd2d15f30bb329ef1/qsdk/qca/src/linux-4.4
The source repository's Linux COPYING file supplies their license.

libxt_NFQUEUE.so is the OpenWrt 18.06.9 aarch64 iptables extension. libxt_CT.so is
built from upstream iptables 1.6.2, also GPL-2.0:
https://www.netfilter.org/projects/iptables/files/iptables-1.6.2.tar.bz2

enodia_noflow.ko is the explicitly assigned no-op conntrack helper. Its complete MIT
source is included alongside this file as enodia_noflow.c. It never reads conntrack
private data or changes packet contents. TCP443 selectors alone opt connections out
of hardware acceleration; the global accelerator remains enabled.

Release preparation strips debug sections, checking that allocated sections do not
change. Private source-directory prefixes in diagnostic read-only strings are then
replaced with equal-length neutral prefixes. All executable sections remain identical
to the validated input artifacts. Package checksums describe the final distributed bytes.
