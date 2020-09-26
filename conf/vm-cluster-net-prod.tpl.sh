
auto vmbr24
iface vmbr24 inet static
  address 192.168.24.1
  netmask 255.255.255.0
  bridge-ports eth1
  bridge-stp off
  bridge-fd 0
