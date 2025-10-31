# Partisia Blockchain Node Installer

Interactive deployment script for Partisia Blockchain reader nodes on the **New Server**. 
This comprehensive installer handles the entire setup process with minimal user input required.



### Prerequisites
- **Peer Information**: Before running the script, obtain peer details from the Partisia Discord community
- **Sufficient Disk Space**: ~350GB recommended for snapshot installation  
- **Ubuntu**: Tested on Ubuntu 24

.
.
.
.



### Installation
```bash
# Download and execute as root
wget https://raw.githubusercontent.com/nexus-sehara/pbc-nodeInstall/main/node-install.sh
chmod +x node-install.sh
./node-install.sh
```





### Post-Installation
```bash
su - $USER
cd pbc
```


.
.
.


### Features

Complete Automation: Installs Docker, dependencies, and configures the node automatically

User Management: Secure non-root user setup with proper permissions

Snapshot Support: Optional blockchain snapshot for faster synchronization

Log Rotation: Automatic Docker log management to prevent disk issues

Firewall Configuration: Secure UFW setup with required ports

Interactive Setup: Guided peer configuration and network key generation



.
.
.


### Sync Progress Tracking

Thanks to @muzo178 for this helpful command:

```bash
docker logs -f --tail=100 pbc-mainnet \
| awk '
function show(){ printf "\rGov:%s  Shard0:%s  Shard1:%s  Shard2:%s   ", latest["Gov"], latest["Shard0"], latest["Shard1"], latest["Shard2"]; fflush(stdout) }
match($0, /\[BlockRequester-([A-Za-z0-9]+)-[0-9]+\]/, a) && match($0, /blockTime=([0-9]+)/, b) { latest[a[1]]=b[1]+0; show() }'
```


.
.
.


### Notes

The script follows official Partisia documentation

Please visit docs for details.

Contributions welcome! Please feel free to submit issues and pull requests.
