# Ubuntu WSL Configuration
[wsl2]
networkingMode=bridged
vmSwitch=WSL-Bridge
dnsTunneling=false
firewall=false

sudo nano /etc/resolv.conf
Add:
nameserver 8.8.8.8
Then retry:
bashsudo apt update
