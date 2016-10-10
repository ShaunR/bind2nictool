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
5. tar zxvf server/NicToolServer-x.xx.tar.gz
6. cd NicToolServer-x.xx
7. perl Makefile.PL (Make sure you satisfy the required dependencys)
8. make && make install
9. cd /usr/src/bind2nictool
10. edit bind2nictool.conf with your info
11. perl bind2nictool.pl --configfile=bind2nictool.conf

	
	
Authors
-------

**Shaun Reitan** (shaun.reitan@ndchost.com)
