Bind2NicTool
=============
		
Script to keep bind zones and records synced with NicTool.

	
	
Requirements
-----------

* NicToolServerAPI 
* DNS::ZoneParse (perl)
* Unix::PID (perl)

	
	
Installation
-----------

1. cd /usr/src
2. git clone https://github.com/ShaunR/bind2nictool.git
3. Go to https://github.com/msimerson/NicTool and download the latest release
4. tar zxvf NicTool-x.xx.tar.gz
5. tar zxvf client/NicToolClient-x.xx.tar.gz
6. cd NicToolClient-x.xx
7. perl bin/install_deps.pl
8. perl Makefile.PL
9. make && make install
10. cd /usr/src/bind2nictool
11. cpan -i DNS::ZoneParse
12. cpan -i Unix::PID
13. edit bind2nictool.conf with your info
14. perl bind2nictool.pl --configfile=bind2nictool.conf

	
	
Authors
-------

**Shaun Reitan** (shaun.reitan@ndchost.com)
