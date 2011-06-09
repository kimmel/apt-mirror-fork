apt-mirror-fork (apt-mirror.pl) is a mirroring tool for Debian / Ubuntu or any other apt based source.

MAIN FEATURES
-------------

 * It works on all POSIX compliant systems with perl and wget. Tested on OpenSUSE 11.4 ( http://en.opensuse.org/Portal:11.4 ) and Ubuntu 10.04 LTS ( http://releases.ubuntu.com/lucid/ ).
 * Config file similar to apts F<sources.list>
 * Fully pool comply
 * Supports multithreaded downloading
 * Supports the downloading of multiple architectures at the same time (i386, amd64, etc...)
 * It can automatically remove unneeded files

NOTES
-----

apt-mirror.pl by default uses /etc/apt/mirror.list as a configuration file. Please change the settings in this file before your first run.

LICENSING INFORMATION
---------------------

This application is licensed under the GNU General Public License (GPL) Version 3. LICENSE.txt contains a copy of the GPL v3.

ADDITIONAL DOCUMENTATION
------------------------

More information on this application can be found via the perldoc. To view this information use the following command:

perldoc apt-mirror.pl


