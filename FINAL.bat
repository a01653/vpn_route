route change 0.0.0.0 mask 0.0.0.0 192.168.1.1 if 15 metric 25
route change 0.0.0.0 mask 0.0.0.0 0.0.0.0 if 21 metric 100
route change 10.136.0.0 mask 255.255.0.0 0.0.0.0 if 21
route change 172.28.0.0 mask 255.255.0.0 0.0.0.0 if 21
route change 10.143.0.0 mask 255.255.0.0 0.0.0.0 if 21
route change 10.142.0.0 mask 255.255.0.0 0.0.0.0 if 21
route change 10.141.0.0 mask 255.255.0.0 0.0.0.0 if 21
route change 10.140.0.0 mask 255.255.0.0 0.0.0.0 if 21
route delete 192.168.1.0 mask 255.255.255.0 0.0.0.0 if 21
route change 192.168.1.0 mask 255.255.255.0 0.0.0.0 if 15 metric 500
