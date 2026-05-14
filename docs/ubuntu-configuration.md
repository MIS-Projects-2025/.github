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


add (optional but highly recommended)
Port 2222 (this is to be used for ssh into wsl directly)
ListenAddress 0.0.0.0
PasswordAuthentication yes

and add windows rule thingy on 2222.

disable socket thingy. dunno why 
```powershell
    New-NetFirewallRule -Name "AllowSSH-WSL-2222" -DisplayName "Allow SSH WSL (Port 2222)" -Direction Inbound -Protocol TCP -LocalPort 2222 -Action Allow
    ```
*   **Layer 2: Hyper-V Firewall Rule (Required for Mirrored Mode)**
    
```powershell
    New-NetFirewallHyperVRule -DisplayName "Allow WSL SSH Port 2222" -Direction Inbound -LocalPorts 2222 -Action Allow
```


setting permissions permanently granted on parents directory in Ubuntu
sudo chown -R $(whoami):www-data /var/www
sudo chmod -R 775 /var/www
sudo chmod g+s /var/www
sudo usermod -aG www-data $(whoami)

sudo usermod -aG docker $USER
newgrp docker


