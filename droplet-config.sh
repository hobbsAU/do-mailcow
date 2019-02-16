#!/bin/bash
set -euo pipefail
#set -x

########################
### SCRIPT VARIABLES ###
########################





########################
### SCRIPT FUNCTIONS ###
########################

function BackupDisk_create() {
local mnt_dir=""
mnt_dir=$(echo "$MAILCOW_BACKUP_DIR" |sed -e "s/^\///; s/\/$//; s/\//-/g;")

# Check environment 
[[ "${MAILCOW_BACKUP_DIR:-}" && "${MAILCOW_BACKUP_FILE:-}" && "${MAILCOW_VOLUME_SIZE:-}" ]] || { echo "Variable not set"; exit 1; }

# Test for backup mount
[[ ! -d "$MAILCOW_BACKUP_DIR" ]] && mkdir -p $MAILCOW_BACKUP_DIR

# Test for backup disk
if [[ ! -f "$MAILCOW_BACKUP_FILE" ]]; then
	# Create disk
	dd if=/dev/zero of=$MAILCOW_BACKUP_FILE bs=1G count=${MAILCOW_VOLUME_SIZE%%[^0-9]*}

	# Format Disk
	mkfs.ext4 $MAILCOW_BACKUP_FILE
	# Create backup disk if there is enough free space
	# [[ "$(du -s /home/ | awk '{ print $1 }')" -lt "$(df |grep sda2 |awk '{ print $2 }')" ]] && echo "true" || echo "false"

	# Mount disk
	#mount -o loop,noexec,nosuid,rw $MAILCOW_BACKUP_FILE $MAILCOW_BACKUP_DIR
else
	echo "Backup disk exists"
fi

#Install mount script
if [[ ! -f "/etc/systemd/system/$mnt_dir.mount" ]]; then
echo "[Unit]
Description=Mount Backup Volume $MAILCOW_BACKUP_FILE

[Mount]
What=$MAILCOW_BACKUP_FILE
Where=$MAILCOW_BACKUP_DIR
Options=defaults,loop,noexec,nosuid,nofail,noatime,rw
Type=ext4

[Install]
WantedBy = multi-user.target" | tee /etc/systemd/system/$mnt_dir.mount
systemctl daemon-reload
systemctl enable $mnt_dir.mount
systemctl start $mnt_dir.mount
else
	echo "Backup volume mount script exists"
fi

}

function Packages_install() {

echo "installing $1"
    apt-get update 
    apt-get install -y ${1}
    apt-get -y autoremove
}

function Docker_install() {
local packages="apt-transport-https ca-certificates curl gnupg2 software-properties-common"

# Install package dependencies
Packages_install "$packages"

# Install Docker
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
apt-get update
apt-cache policy docker-ce
apt-get install -y docker-ce
systemctl status docker
docker info

# Install Compose
curl -L "https://github.com/docker/compose/releases/download/$(curl -Ls https://www.servercow.de/docker-compose/latest.php)/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && \
chmod +x /usr/local/bin/docker-compose

}

function Volume_mount() {
local mnt_dir=""
mnt_dir=$(echo "$MAILCOW_VOLUME" | sed -e 's/-/_/g')

if [[ ! -f "/etc/systemd/system/mnt-$mnt_dir.mount" ]]; then
echo "[Unit]
Description=Mount DO Volume $MAILCOW_VOLUME

[Mount]
What=/dev/disk/by-id/scsi-0DO_Volume_$MAILCOW_VOLUME
Where=/mnt/$mnt_dir
Options=defaults,nofail,discard,noatime
Type=ext4

[Install]
WantedBy = multi-user.target" | tee /etc/systemd/system/mnt-$mnt_dir.mount
systemctl daemon-reload
systemctl enable mnt-$mnt_dir.mount
systemctl start mnt-$mnt_dir.mount
fi

}



function Mailcow_install() {
local mnt_dir=$(echo "$MAILCOW_VOLUME" | sed -e 's/-/_/g')

# Set umask
umask 0022

# Remove any previous installation
rm -rf /opt/mailcow-dockerized

# Clone mailcow repo
git clone https://github.com/mailcow/mailcow-dockerized /opt/mailcow-dockerized
cd /opt/mailcow-dockerized && ./generate_config.sh 

# Check for previous config and restore otherwise backup new config required for DB credentials
if [[ -f /mnt/$mnt_dir/mailcow.conf ]]; then 
	mv ./mailcow.conf ./mailcow.bak; 
	cp /mnt/$mnt_dir/mailcow.conf .; 
else 
	cp mailcow.conf /mnt/$mnt_dir/; 
fi

# Update Docker storage location
echo -e "{  \"data-root\": \"/mnt/$mnt_dir/docker\" }" | tee /etc/docker/daemon.json
systemctl restart docker
exit 0

}


function SSH_config() {
usermod -p "*" $DROPLET_SSH_USER
echo -e "Port $DROPLET_SSH_PORT
Protocol 2
KexAlgorithms curve25519-sha256@libssh.org
HostKey /etc/ssh/ssh_host_ed25519_key
Ciphers chacha20-poly1305@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
PubkeyAuthentication yes
AuthorizedKeysFile	.ssh/authorized_keys
HostbasedAuthentication no
X11Forwarding no
IgnoreRhosts yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePrivilegeSeparation sandbox
LogLevel VERBOSE
AllowUsers $DROPLET_SSH_USER" | tee /etc/ssh/sshd_config
systemctl restart sshd
}


function Backup_install() {
## systemd, pre_hook for mailcow backup

# Load variable
local mnt_dir=$(echo "$MAILCOW_VOLUME" | sed -e 's/-/_/g')
source /mnt/$mnt_dir/mailcow.conf
CMPS_PRJ=$(echo $COMPOSE_PROJECT_NAME | tr -cd "[A-Za-z-_]")


# install borgmatic
docker pull hobbsau/borgmatic

# install systemd

# add config directory
[[ ! -d "/etc/borg" ]] && mkdir -p /etc/borg
[[ ! -d "/etc/borgmatic" ]] && mkdir -p /etc/borgmatic
[[ ! -d "~/.ssh" ]] && mkdir -p ~/.ssh


# install borgmatic conf
[[ ! -f "/etc/borgmatic/config.yaml" ]] && echo "Copying borgmatic config" || echo "Overwriting borgmatic config"
echo -e "location:
    source_directories:
        - /backup

    repositories:
        - $BACKUP_REPO

    exclude_patterns:
        - 'dovecot-uidlist.lock'
        - ~/*/.cache

    exclude_caches: true
    exclude_if_present: .nobackup

storage:
    #compression: auto,zstd
    archive_name_format: '{hostname}-{now}'

retention:
    keep_daily: 3
    keep_weekly: 4
    keep_monthly: 12
    keep_yearly: 2
    prefix: '{hostname}-'

consistency:
    checks:
        # uncomment to always do integrity checks. (takes long time for large repos)
        - repository
        #- disabled

    check_last: 3
    prefix: '{hostname}-'
" | tee /etc/borgmatic/config.yaml

# install repo key
[[ ! -f "/etc/borg/repokey" ]] && echo "Copying repo key" || echo "Overwriting repo key"
echo -e "$BACKUP_REPOKEY" | tee /etc/borg/repokey
chmod 600 /etc/borg/repokey

#install ssh key
[[ ! -f "/root/.ssh/id_borg" ]] && echo "Copying ssh id" || echo "Overwriting ssh id"
echo -e "$BACKUP_SSHID" | tee /root/.ssh/id_borg
chmod 600 /root/.ssh/id_borg

# install borg backup host keys and test
local hostname="$(echo $BACKUP_HOSTID | awk '{ print $1 }')"
local pubkey="$(echo $BACKUP_HOSTID | awk '{ print $3 }')"
if [[ ! -f "/root/.ssh/known_hosts" ]]; then
ssh-keyscan -H $hostname | tee /root/.ssh/known_hosts
else
ssh-keyscan -H $hostname | tee -a /root/.ssh/known_hosts
fi
[[ $(ssh-keygen -F "$hostname" |grep "$pubkey") ]] && echo "Backup host authenticated" || { echo "Backup host authentication error"; exit 1; }


# install borgmatic systemd script
[[ ! -f "/etc/systemd/system/borgmatic.service" ]] && echo "Installing systemd borgmatic.service" || echo "Overwriting systemd borgmatic.service"
echo -e " [Unit]
Description=borg backup

[Service]
Type=oneshot
ExecStart=/usr/bin/docker run \
  --rm -t --name hobbsau-borgmatic \
  -e TZ=$MAILCOW_TZ \
  -e BORG_PASSCOMMAND='cat /root/.config/borg/repokey' \
  -e BORG_RSH='ssh -i /root/.ssh/id_borg' \
  -v /etc/borg:/root/.config/borg \
  -v /var/borgcache:/root/.cache/borg \
  -v /etc/borgmatic:/root/.config/borgmatic:ro \
  -v /root/.ssh:/root/.ssh \
  -v $(docker volume ls -qf name=${CMPS_PRJ}_vmail-vol-1):/backup/vmail:ro \
  -v $MAILCOW_BACKUP_DIR:/backup/mailcow:ro \
  hobbsau/borgmatic --stats --verbosity 1

" | tee /etc/systemd/system/borgmatic.service

[[ ! -f "/etc/systemd/system/borgmatic.timer" ]] && echo "Installing systemd borgmatic.timer" || echo "Overwriting systemd borgmatic.timer"
echo -e " [Unit]
Description=Run borg backup

[Timer]
OnCalendar=*-*-* 23:00:00
Persistent=true

[Install]
WantedBy=timers.target
" | tee /etc/systemd/system/borgmatic.timer



# install mailcow backup systemd script
[[ ! -f "/etc/systemd/system/mcbackup.service" ]] && echo "Installing systemd mcbackup.service" || echo "Overwriting systemd mcbackup.service"
echo -e "[Unit]
Description=mailcow backup

[Service]
Type=oneshot
Environment=MAILCOW_BACKUP_LOCATION=$MAILCOW_BACKUP_DIR
ExecStart=/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup crypt redis rspamd postfix mysql
" | tee /etc/systemd/system/mcbackup.service


[[ ! -f "/etc/systemd/system/mcbackup.timer" ]] && echo "Installing systemd mcbackup.timer" || echo "Overwriting systemd mcbackup.timer"
echo -e " [Unit]
Description=Run mcbackup

[Timer]
OnCalendar=*-*-* 22:50:00
Persistent=true

[Install]
WantedBy=timers.target
" | tee /etc/systemd/system/mcbackup.timer

# enable systemd services
if [[ -f "/etc/systemd/system/borgmatic.service" ]] && [[ -f "/etc/systemd/system/mcbackup.service" ]]; then
systemctl daemon-reload
systemctl enable borgmatic.timer
systemctl enable mcbackup.timer
fi


# execute a backup
#systemctl start mcbackup.service
#sleep 30
#journalctl -u mcbackup.service
#sleep 10
#systemctl start borgmatic.service
#docker run --rm -e BORG_PASSCOMMAND='cat /borgmatic/repokey' -e BORG_RSH='ssh -i /root/.ssh/id_borg' -v $(docker volume ls -qf name=${CMPS_PRJ}_vmail-vol-1):/vmail:ro -v $MAILCOW_BACKUP_DIR:/mailcow -v ~/.ssh:/root/.ssh -v /etc/borgmatic:/borgmatic:ro monachus/borgmatic --verbosity 1 -c /borgmatic/config.yaml

# execute a test restore
#local archive="$(docker run --rm -e 'BORG_PASSCOMMAND=cat /borgmatic/repokey' -e 'BORG_RSH=ssh -i ~/.ssh/id_borg' -v ~/.ssh:/root/.ssh -v /etc/borgmatic:/borgmatic:ro monachus/borgmatic -c /borgmatic/config.yaml --list |tail -n 1 |awk '{ print $1 }')"
#docker run --rm -e 'BORG_PASSCOMMAND=cat /borgmatic/repokey' -e 'BORG_RSH=ssh -i ~/.ssh/id_borg' -v ~/.ssh:/root/.ssh -v /etc/borgmatic:/borgmatic:ro monachus/borgmatic borg extract --dry-run --list $BACKUP_REPO::$archive

exit 0
}



####################
### SCRIPT LOGIC ###
####################

# Check config for borg and enable

# Check config for local backup and enable


