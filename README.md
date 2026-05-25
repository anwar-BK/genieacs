# INSTALL GENIEACS OTOMATIS
This is autoinstall GenieACS 

# Usage
```
apt install git curl -y
```
```
git clone https://github.com/alijayanet/genieacs
```
```
cd genieacs
```
```
chmod +x *.sh
```
INSTALL GENIEACS DARKMODE Ubuntu OS 22.04
```
bash darkmode.sh
```
INSTALL GENIEACS DARKMODE ARMBIAN (STB)
```
bash darkmode-arm.sh
```
INSTALL GENIEACS THEMA ORIGINAL v@1.2.13
```
bash install.sh
```

Baca terlebih dahulu !!!

#=== Script update GenieACS ====#

Config sebelumnya akan terhapus dan tergantikan oleh config baru

Yang akan diupdate, yaitu:

   • Admin >> Preset <br>
   • Admin >> Provosions <br>
   • Admin >> Virtual Parameter<br>
   • Admin >> Config<br>
   
#===Script/config tersebut akan terganti dengan yang baru ====#

Jika anda memiliki config/script custom buatan anda sendiri,<br> 
silahkan backup terlebih dahulu, kemudian setelah update lakukan config manual lagi sesuai config custom anda.<br>

Akses GenieACS

Web UI: http://localhost:3000
Username: admin
Password: admin (menu virtualparameter dll di sembunyikan)<br>
API: http://localhost:7557 <br>
CWMP (TR-069): http://your-server-ip:7547<br>

======= CARA RESTORE ========<br>
```
cd
```
```
sudo mongorestore --db=genieacs --drop genieacs-backup/genieacs
```
🤝 Kontribusi
Kontribusi selalu diterima! Silakan buat pull request atau laporkan issue jika menemukan bug.

https://wa.me/6281947215703


SILAHKAN YANG INGIN BERBAGI UANG KOPI <br>
1730011827673 a/n taufik anwar MANDIRI
