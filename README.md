# SimpleSaferServer
Basic scripts designed to run on Debian-based (Raspberry Pi or Ubuntu Server) machines to back up data, monitor hard drive health and more.

## Migrate To The New Version

To migrate an existing legacy installation to the new SimpleSaferServer implementation, run:

```bash
curl -fsSL https://raw.githubusercontent.com/chrismin13/SimpleSaferServer-old/main/migrate.sh | sudo bash
```

The migration script will:

- Back up the legacy config, SMTP config, and rclone config
- Install the new SimpleSaferServer release
- Prompt for the new admin username and password
- Import the legacy backup settings into the new system
- Disable the old timers after the new setup succeeds

If the machine is still on Debian 10 (Buster), `apt-get update` may fail because the normal Debian mirrors no longer serve it.

**Warning:** this is only a temporary workaround for migrating or testing an old Debian 10 machine.

For temporary testing on an old machine, switch APT to the Debian archive first:

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i 's|http://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list
sudo sed -i 's|http://deb.debian.org/debian-security|http://archive.debian.org/debian-security|g' /etc/apt/sources.list
sudo sed -i '/buster-updates/d' /etc/apt/sources.list
sudo tee /etc/apt/apt.conf.d/99buster-archive >/dev/null <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::AllowInsecureRepositories "true";
Acquire::AllowDowngradeToInsecureRepositories "true";
EOF
sudo apt-get update
```

# Install
## Preparation
### Install dependencies
Install git - will be used to download this script later
```
sudo apt install git
```

### Set up fstab to mount an external NTFS backup drive 
1. Find the NTFS partition UUID  by running `sudo lsblk -f | grep -v loop` and getting just the UUID of the partition you want
2. `sudo mkdir /media/backup`  to create the directory that will contain the partition
3. `sudo nano /etc/fstab` 
    
    ```
    # <uuid>		<dir>		<type>	<options>	<dump>	<pass>
    UUID=		/media/backup	ntfs-3g	defaults,nofail	0	0
    ```
    
    `nofail` is important, if missing the system won't boot if the drive is disconnected
    
4. `sudo mount -a` to apply the changes and remount the disks

### Download and set up rclone
1. Run `sudo -v ; curl https://rclone.org/install.sh | sudo bash`
2. Set up rclone by running `rclone config`. Some useful resources:
    1. https://rclone.org/drive/
    2. https://rclone.org/onedrive/
    3. https://rclone.org/crypt/ 
        1. USE OBFUSCATE to keep paths short
        2. Store your keys in a password manager!
3. Install screen for testing `sudo apt install screen`
4. Run `screen`
    1. `rclone sync /media/backup/ YourRemote: -P --create-empty-src-dirs` (Replace YourRemote: with your rclone mount point or folder etc.)
    2. If the script is running correctly, detach with Ctrl+A and Ctrl+D
    3. To resume, run `screen -r`.

### Download HDSentinel (temporary, see #4)
```bash
wget https://www.hdsentinel.com/hdslin/hdsentinel-armv8.bz2
bzip2 -d hdsentinel-armv8.bz2
chmod +x hdsentinel-armv8
sudo mv hdsentinel-armv8 /usr/local/bin/hdsentinel-armv8
```
### Set up SMTP Server for email alerts

1. `sudo apt install msmtp`
2. `sudo nano /etc/msmtprc`

```
# Set default values for all following accounts.
defaults
port 587
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account gmail
host smtp.gmail.com
from YOUR_EMAIL_HERE
auth on
user YOUR_EMAIL_HERE
password YOUR_PASSOWRD_HERE
# Set a default account
account default : gmail
```
To use Gmail, you need to enable 2FA and add an application key that you'll use as your password.

## Actual scripts:

Find your Disk’s UUID and USB ID and keep them somewhere:
`sudo nano /etc/fstab`    
`lsusb`

Run:
```
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/chrismin13/SimpleSaferServer-old/main/install.sh -o "$tmp" && sudo bash "$tmp"; rm -f "$tmp"
```
