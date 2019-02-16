#!/usr/bin/env bash
# A menu driven shell script to provision mailcow on DigitalOcean

#Set Bash sctrict modes
set -o errexit 
set -o nounset
set -o pipefail
IFS=$'\n\t'
trap '' SIGINT SIGQUIT SIGTSTP

########################
### SCRIPT VARIABLES ###
########################

# Set debug
DEBUG=1
#set -x

# Define command locations
DO_BIN=/usr/bin/doctl

# Define constants
BRED='\033[0;41;30m'
STD='\033[0;0;39m'
RED="\033[0;31m"          # Red
BLUE="\033[0;34m"         # Blue
PURPLE="\033[0;35m"       # Purple

# Configure Global variables
ENV_CONF=${1:-env.conf}
WAN_IP=$(dig -4 @resolver1.opendns.com ANY myip.opendns.com +short)


########################
### SCRIPT FUNCTIONS ###
########################

function read_env_conf() {
if [[ -f "${ENV_CONF}" ]]; then
    log "Reading user config...." >&2
    # check if the file contains something we don't want
    CONFIG_SYNTAX="(^\s*#|^\s*$|^\s*[a-z_][^[:space:]]*=[^;&\(\`]*$)"
    if egrep -q -iv "$CONFIG_SYNTAX" "$ENV_CONF"; then
      log "Config file is unclean, please check it..." >&2
      exit 1
    fi
    # now source it, either the original or the filtered variant
    # export $(cat $ENV_CONF | grep -v ^\# | xargs)
    source "$ENV_CONF"
else
    log "There is no configuration file call ${ENV_CONF}"
    pause
fi

#Must have access token and hostname    
if [[ ! ${#DIGITALOCEAN_ACCESS_TOKEN} == 64 ]]; then
  while [[ ! ${#DIGITALOCEAN_ACCESS_TOKEN} == 64 ]]; do
    read -ep "DigitalOcean API Token (must be generated via DigitalOcean control panel): " DIGITALOCEAN_ACCESS_TOKEN
  done
fi

#Export Access Token for doctl authentication
export DIGITALOCEAN_ACCESS_TOKEN=$DIGITALOCEAN_ACCESS_TOKEN

if [ -z "$DROPLET_HOSTNAME" ]; then
	while [ -z "$DROPLET_HOSTNAME" ]; do
        	list_droplet 
        	read -ep "Name: " DIGITALOCEAN_HOSTNAME
        done
fi

}

function pause() {
  read -p "Press [Enter] key to continue..." fackEnterKey
}


function log() {
	local now=$(date +'%Y-%m-%d %H:%M:%S')
	echo -e "${BLUE}[$now] $1${STD}"
}

function debug() {
	local now=$(date +'%Y-%m-%d %H:%M:%S')
	echo -e "${PURPLE}\n[$now] DEBUG: $1${STD}"
}


function generate_userdata() {
#Set Authorized SSH Key
if [[ -f "${DROPLET_SSH_PUBLIC_KEY_FILE}" ]]; then
local authorized_ssh_key=$(< $DROPLET_SSH_PUBLIC_KEY_FILE)
else
    log "There is no ssh key file ${DROPLET_SSH_PUBLIC_KEY_FILE}"
    pause
fi

cat <<EOF > $DROPLET_USERDATAFILE
#cloud-config

# Upgrade the instance on first boot (ie run apt-get upgrade)
# Default: false
# Aliases: apt_upgrade
package_update: true
package_upgrade: true

# Install the following packages
packages:
#  - ufw
  - haveged

# Setup user
users:
  - name: $DROPLET_SSH_USER
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh-authorized-keys:
      - $authorized_ssh_key

runcmd:
#  - echo "y" | ufw enable
#  - ufw rule allow proto tcp to 0.0.0.0/0 port $DROPLET_SSH_PORT 
#  - ufw default deny incoming
#  - ufw default allow outgoing
  - sed -i -e '/^#alias ll/s/^#//' /home/$DROPLET_SSH_USER/.bashrc
  - sed -i -e '/^#Port/s/^.*$/Port $DROPLET_SSH_PORT/' /etc/ssh/sshd_config
  - export HOSTNAME=\$(curl -s http://169.254.169.254/metadata/v1/hostname)
  - echo \$HOSTNAME
  - export PUBLIC_IPV4=\$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
  - echo \$PUBLIC_IPV4

power_state:
# delay: "+1"
 mode: reboot
 message: Bye Bye
 timeout: 30
 condition: True
EOF
}

function droplet_create() {
local   parms=(compute droplet create $DROPLET_HOSTNAME --wait --size $DROPLET_SIZE --image $DROPLET_IMAGE --region $DROPLET_REGION --tag-names $DROPLET_TAG)
local	domain=${DROPLET_HOSTNAME#*.}
local   host=${DROPLET_HOSTNAME%%.*}

# Generate userdata file
generate_userdata

#Check if droplet exists with same tag
if [[ ! -z $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }') ]]; then
	log "ERROR: Droplet already exists";
else

	#Create Droplet
	log "Creating Droplet: $DROPLET_HOSTNAME in $DROPLET_REGION tagged with $DROPLET_TAG";
	if [ ! -z "$DROPLET_MONITORING" ] && [ $DROPLET_MONITORING = "true" ] ; then
		parms+=(--enable-monitoring)
	fi

	if [ ! -z "$DROPLET_USERDATAFILE" ]; then
		parms+=(--user-data-file $DROPLET_USERDATAFILE)
	fi

	if [ $DEBUG -eq "1" ]; then
		debug "$(printenv |grep DIGITAL)";
	fi

	$DO_BIN "${parms[@]}" && log "Droplet created." || { log "Error creating droplet!"; return 0; }
fi

#Update DNS records
if [ $DEBUG -eq "1" ]; then
        debug "Updating DNS for Domain: $domain and Host: $host";
fi

$DO_BIN compute domain records update $domain --record-ttl 60 --record-name $host --record-id $($DO_BIN compute domain records list $domain |grep "$host " |awk '{ print $1 }') --record-data $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $3 }') && log "DNS updated." || { log "Error updating DNS!"; return 0; };


# Wait for cloud-init to complete.
if [[ ! -z $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }') ]]; then
	until droplet_ssh 'last';  do
	clear && log "Waiting for Droplet SSH daemon.."
	sleep 10
	done
else
	log "Error creating Droplet!"; 
	return 0; 
fi

}

function droplet_delete() {
local droplet_id=""

# Find and delete all Droplets with our tag
for droplet_id in $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }'); do
	[[ -z $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk -F $'[[:space:]][[:space:]][[:space:]]+' '{ print $12 }') ]] || { log "Detatching volumes first.."; volume_detach; }
	log "Deleting Droplet $droplet_id";
	$DO_BIN compute droplet-action power-off --wait "$droplet_id"
	$DO_BIN compute droplet delete --force "$droplet_id"
done;
}

function droplet_get() {
$DO_BIN compute droplet get "$1"
}

function droplet_list() {
log "Listing all Droplets.."
$DO_BIN compute droplet list || { log "Error listing Droplets"; return 0; }
log "Listing all Volumes.."
$DO_BIN compute volume list || { log "Error listing Volumes"; return 0; }
}

function droplet_on() {
log "Turning on Droplet.."
$DO_BIN compute droplet-action power-on --wait ${1:-} && { log "Droplet successfully started"; return 0; } || { log "Problem powering on Droplet!"; return 0; }
}

function droplet_off() {
log "Turning off Droplet.."
$DO_BIN compute droplet-action power-off --wait ${1:-} && { log "Droplet successfully shutdown"; return 0; } || { log "Problem powering off Droplet!"; return 0; }
}

function droplet_reboot() {
log "Rebooting Droplet.."
$DO_BIN compute droplet-action reboot --wait ${1:-} && { log "Droplet successfully rebooted"; return 0; } || { log "Problem rebooting Droplet!"; return 0; }
}

function droplet_rebuild() {
# Check for mounted volumes
[[ -z $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk -F $'[[:space:]][[:space:]][[:space:]]+' '{ print $12 }') ]] || { log "Detatching volumes first.."; volume_detach; }

# Rebuild droplet
log "Rebuilding Droplet.."
$DO_BIN compute droplet-action rebuild --wait ${1:-} --image ${DROPLET_IMAGE} && { log "Droplet successfully rebuilt"; return 0; } || { log "Problem rebuilding Droplet!"; return 0; }
}

function droplet_update() {
log "Updating Droplet.."
droplet_ssh "sudo apt-get update && sudo apt-get -y upgrade && sudo apt-get -y dist-upgrade && sudo apt-get clean && sudo apt-get -y autoremove" && { log "Droplet successfully updated"; return 0; } || { log "Problem updating Droplet!"; return 0; }
}


function droplet_configure() {

log "Creating Backup Disk"
droplet_sshBatch "$SCRIPT_CONFIG" "MAILCOW_BACKUP_DIR=$MAILCOW_BACKUP_DIR MAILCOW_BACKUP_FILE=$MAILCOW_BACKUP_FILE MAILCOW_VOLUME_SIZE=$MAILCOW_VOLUME_SIZE" "BackupDisk_create" && { log "Backup Disk created successfully."; } || { log "Error creating backup disk!"; return 0; } 

log "Attaching Volume"
volume_attach && { log "Volume attached successfully."; } || { log "Error attaching volume!"; return 0; }; 

log "Installing Docker"
droplet_sshBatch "$SCRIPT_CONFIG" "" "Docker_install"  && { log "Docker installed successfully."; } || { log "Error installing Docker!"; return 0; }          

log "Attaching Firewall"
firewall_attach && { log "Firewall installed successfully."; } || { log "Error installing Firewall!"; return 0; }; 

log "Configuring SSH"
droplet_sshBatch "$SCRIPT_CONFIG" "DROPLET_SSH_PORT=$DROPLET_SSH_PORT DROPLET_SSH_USER=$DROPLET_SSH_USER" "SSH_config"  && { log "SSH configured successfully."; } || { log "Error configuring SSH!"; return 0; }
ssh-keygen -R "[$(dig -4 @resolver1.opendns.com ANY $DROPLET_HOSTNAME +short)]:$DROPLET_SSH_PORT"
}


function droplet_backup() {
#set -x

backup_repokey="$(cat $BACKUP_REPOKEY)"
backup_sshid="$(cat $BACKUP_SSHID)"

log "Configuring Borgbackup"
droplet_sshBatch "$SCRIPT_CONFIG" "MAILCOW_TZ=$MAILCOW_TZ MAILCOW_VOLUME=$MAILCOW_VOLUME MAILCOW_BACKUP_DIR=$MAILCOW_BACKUP_DIR BACKUP_REPO=$BACKUP_REPO BACKUP_REPOKEY=\"$backup_repokey\" BACKUP_HOSTID=\"$BACKUP_HOSTID\" BACKUP_SSHID=\"$backup_sshid\"" "Backup_install"  && { log "Borgbackup configured successfully."; } || { log "Error configuring Borgbackup!"; return 0; }


}

function volume_attach() {
local droplet_id=""
local volume_id=""

# Check for droplet and volume
droplet_id=$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }') || { log "Droplet must exist"; return 1; }
volume_id=$($DO_BIN compute volume list | grep "$MAILCOW_VOLUME" | awk '{ print $1 }') || { 
	log "Volume doesn't exist"; 
	# Create new volume if necessary
	if [ -z $volume_id ]; then
		log "Creating new volume..";
		volume_create;
		volume_id=$($DO_BIN compute volume list | grep "$MAILCOW_VOLUME" | awk '{ print $1 }');
	fi }

# Check droplet is on
[[ $($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $11 }') == "active" ]] || { log "Droplet must be powered on"; return 1; }

# Attach volume	
if [ ! -z $droplet_id ] && [ ! -z $volume_id ]; then
	
	if [ "$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $14 }')" != "$volume_id" ]; then
		log "Attaching Volume: $volume_id to Droplet: $droplet_id"
		$DO_BIN compute volume-action attach $volume_id $droplet_id && log "Volume successfully attached" || { log "Problem attaching volume!"; return 1; }
	fi	
	# Workaround DO Bug in automount on Debian 9.6
	droplet_sshBatch "$SCRIPT_CONFIG" "MAILCOW_VOLUME=$MAILCOW_VOLUME" "Volume_mount" && log "Volume successfully mounted" ||  { log "Problem creating mount!"; return 1; };
else
	log "Droplet and Volume must exist!"; 
	return 1;
fi

}


function volume_detach() {
local droplet_id=""
local volume_id=""

droplet_id=$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }');
volume_id=$($DO_BIN compute volume list | grep "$MAILCOW_VOLUME" | awk '{ print $1 }');

# If Droplet and Volume exists then Detach volume
        if [ ! -z $droplet_id ] && [ ! -z $volume_id ]; then
		log "Detaching Volume: $volume_id from Droplet: $droplet_id"
        	$DO_BIN compute droplet-action power-off --wait $droplet_id;
        	$DO_BIN compute volume-action detach $volume_id $droplet_id;
        	$DO_BIN compute droplet-action power-on --wait $droplet_id;
	else
		log "Droplet and Volume must exist!"
	fi
}

function volume_create {

# Create volume
log "Creating volume.."
$DO_BIN compute volume create $MAILCOW_VOLUME --fs-type ext4 --region $DROPLET_REGION --size $MAILCOW_VOLUME_SIZE || { log "Problem creating volume!"; return 0; }

}


# droplet_ssh "[command to execute]"
function droplet_ssh() {
local args=(compute ssh $DROPLET_HOSTNAME --ssh-port $DROPLET_SSH_PORT --ssh-user $DROPLET_SSH_USER --ssh-key-path $DROPLET_SSH_PRIVATE_KEY_FILE)

# Check for parameters to determine whether SSH or execute remote SSH command
if [[ $# -eq 0 ]]; then
	log "Connecting to $DROPLET_HOSTNAME"
	trap - SIGINT
	$DO_BIN "${args[@]}" || { log "Error in SSH to $DROPLET_HOSTNAME"; trap ' ' SIGINT; return 1; }
	trap ' ' SIGINT; 
elif [[ $# -eq 1 && ${1:-} ]]; then
	log "Executing \""$1"\" on $DROPLET_HOSTNAME"
	args+=(--ssh-command $1)
	trap - SIGINT
	$DO_BIN "${args[@]}" || { log "Error $? in SSH command: $1"; trap ' ' SIGINT; return 1; }
	trap ' ' SIGINT; 
fi
}


# Usage: droplet_sshBatch "<file>" "[environment]"
function droplet_sshBatch() {
local args=(compute ssh $DROPLET_HOSTNAME --ssh-port $DROPLET_SSH_PORT --ssh-user $DROPLET_SSH_USER --ssh-key-path $DROPLET_SSH_PRIVATE_KEY_FILE --ssh-command "sudo bash -s" -- )

# Check for parameters and execute script
trap - SIGINT
[[ ! -f ${1:-} ]] && log "Error: SSH batch file doesn't exist"
[[ $# -eq 1 ]] && { $DO_BIN "${args[@]}" < $1 || { log "Error in SSH: $?"; trap ' ' SIGINT; return 0; } }
[[ $# -eq 2 && ! -z ${2:-} ]] && { $DO_BIN "${args[@]}" < <(echo "${2:-}"; cat $1) || { log "Error in SSH: $?"; trap ' ' SIGINT; return 0; } }
[[ $# -eq 3 && ! -z ${3:-} ]] && { $DO_BIN "${args[@]}" < <(echo "${2:-}"; cat $1; echo $3) || { log "Error in SSH: $?"; trap ' ' SIGINT; return 0; } }
trap ' ' SIGINT; 

}


function show_help {
echo "Usage: "

}


function firewall_attach() {
local droplet_id=""
local firewall_id=""

	#Check for firewall
	droplet_id=$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }') || { log "Droplet must exist"; return 0; }
	firewall_id=$($DO_BIN compute firewall list | grep "$NETWORK_FIREWALL" | awk '{ print $1 }') || { log "Firewall must exist"; return 0; }
	log "Creating Firewall.."
	$DO_BIN compute firewall update $firewall_id --inbound-rules "protocol:tcp,ports:25,address:0.0.0.0/0 protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:110,address:0.0.0.0/0 protocol:tcp,ports:143,address:0.0.0.0/0 protocol:tcp,ports:443,address:0.0.0.0/0 protocol:tcp,ports:465,address:0.0.0.0/0 protocol:tcp,ports:587,address:0.0.0.0/0 protocol:tcp,ports:993,address:0.0.0.0/0 protocol:tcp,ports:995,address:0.0.0.0/0 protocol:tcp,ports:2222,address:0.0.0.0/0 protocol:tcp,ports:4190,address:0.0.0.0/0" --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0" --name $NETWORK_FIREWALL || { log "Error configuring firewall!"; return 0; }
	#$DO_BIN compute firewall update $firewall_id --inbound-rules "protocol:tcp,ports:25,address:0.0.0.0/0 protocol:tcp,ports:80,address:$WAN_IP/32 protocol:tcp,ports:110,address:0.0.0.0/0 protocol:tcp,ports:143,address:0.0.0.0/0 protocol:tcp,ports:443,address:$WAN_IP/32 protocol:tcp,ports:465,address:0.0.0.0/0 protocol:tcp,ports:587,address:0.0.0.0/0 protocol:tcp,ports:993,address:0.0.0.0/0 protocol:tcp,ports:995,address:0.0.0.0/0 protocol:tcp,ports:2222,address:0.0.0.0/0 protocol:tcp,ports:4190,address:0.0.0.0/0" --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0" --name $NETWORK_FIREWALL || { log "Error configuring firewall!"; return 0; }
	log "Attaching Firewall.."
	$DO_BIN compute firewall add-droplets $firewall_id --droplet-ids $droplet_id || { log "Error attaching firewall!"; return 0; }
}

# Install Mailcow
function mailcow_install() {

# Remotely execute install script
droplet_sshBatch "$SCRIPT_CONFIG" "export MAILCOW_HOSTNAME=$DROPLET_HOSTNAME MAILCOW_TZ=$MAILCOW_TZ MAILCOW_VOLUME=$MAILCOW_VOLUME" "Mailcow_install" ||  { log "Error installing mailcow!"; return 0; };

}

function mailcow_start() {
log "Starting Mailcow.."
droplet_ssh "cd /opt/mailcow-dockerized/ && sudo docker-compose pull && sudo docker-compose up -d" ||  { log "Error starting mailcow!"; return 0; };
droplet_ssh "cd /opt/mailcow-dockerized/ && sudo docker-compose logs -f --tail=100" ||  { log "Error viewing mailcow logs!"; return 0; };
}


function mailcow_stop() {
log "Stopping Mailcow.."
droplet_ssh "cd /opt/mailcow-dockerized/ && sudo docker-compose down" ||  { log "Error stopping mailcow!"; return 0; };
}

function mailcow_update() {
log "Updating Mailcow.."
droplet_ssh "cd /opt/mailcow-dockerized/ && sudo ./update.sh --check" ||  { log "Error checking for mailcow updates!"; return 0; };
confirm "Are you sure you would like to update mailcow? [y/N] " && { droplet_ssh "cd /opt/mailcow-dockerized/ && sudo ./update.sh --ours" ||  { log "Error updating mailcow!"; return 0; }; };
}

function mailcow_logs() {
log "Viewing Mailcow logs.."
droplet_ssh "cd /opt/mailcow-dockerized/ && sudo docker-compose logs -f --tail=100" ||  { log "Error viewing mailcow logs!"; return 0; };
}

function mailcow_backup() {
log "Backing up mailcow config"
#droplet_ssh "sudo MAILCOW_BACKUP_LOCATION=$MAILCOW_BACKUP_DIR /opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup all"
droplet_ssh "sudo MAILCOW_BACKUP_LOCATION=$MAILCOW_BACKUP_DIR /opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup crypt redis rspamd postfix mysql"
}

function docker_prune() {
log "Pruning unused containers.."
droplet_ssh "sudo docker system prune -f"
}

function confirm() {
local response=""

# Call with a prompt string or use a default
read -r -p "${1:-Are you sure? [y/N]} " response

# Check response is yes and return true
if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]
then
	true
else
	false
fi
}

function menu_manageDroplet() {
local choice=""
local droplet_id=""
local volume_id=""

while [ "$choice" != x ]; do 
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"        
        echo " D R O P L E T - M E N U"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "1.  List Droplets		- List Droplets"
        echo "2.  Destroy Droplet 		- Destroy mailcow Droplet"
        echo "3.  Attach Volume		- Attach Volume to Droplet, create if it does not exist"
        echo "4.  Detach Volume		- Remove Volume from Droplet"
        echo "5.  Start/Stop Droplet 		- Power On or Off Droplet"
        echo "6.  Reboot Droplet 		- Reboot Droplet"
        echo "7.  Rebuild Droplet 		- Rebuild Droplet"
        echo "8.  Update Droplet		- Update Droplet"
        echo "9.  SSH to Droplet   		- SSH to Droplet"
        echo "x.  Exit"
        echo ""
        read -p "Enter choice [ 0 - 11 ] " choice
        case $choice in
                1) droplet_list; pause ;;
                2) droplet_delete "$DROPLET_TAG"; pause ;;
                3) volume_attach; pause ;;
                4) volume_detach; pause ;;
		5) droplet_power "$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }')"; pause ;;
		6) droplet_reboot "$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }')"; pause ;;
		7) droplet_rebuild "$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }')"; pause ;;
		8) droplet_update "$($DO_BIN compute droplet list | grep "$DROPLET_TAG" | awk '{ print $1 }')"; pause ;;
                9) droplet_ssh || { log "Droplet unavailble"; };  pause ;;
                x) return 0;;
                *) echo -e "${RED}Error...${STD}" && sleep 1
        esac
done
}



function menu_manageMailcow() {
local choice=""

while [ "$choice" != x ]; do 
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"        
        echo " M A I L C O W - M E N U"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "1.  Mailcow Install 		- Create and configure mailcow Droplet"
        echo "2.  Mailcow Start 		- Start Mailcow"
        echo "3.  Mailcow Stop		- Stop Mailcow"
        echo "4.  Mailcow Backup Config		- Mailcow config backup"
        echo "5.  Mailcow Backup Data		- Mailcow maildir backup"
        echo "6.  Mailcow Update			- Update Mailcow"
        echo "7.  Docker Prune			- Prune unused Docker containers"
        echo "x.  Exit"
        read -p "Enter choice [ 0 - 5 ] " choice
        case $choice in
                1) mailcow_install; pause ;;
                2) mailcow_start; pause ;;
                3) mailcow_stop; pause ;;
                4) mailcow_backup; pause ;;
                5) pause ;;
                6) mailcow_update; pause ;;
                7) docker_prune; pause ;;
                x) return 0;;
                *) echo -e "${RED}Error...${STD}" && sleep 1
        esac
done

}


function menu_monitor() {
local choice=""

while [ "$choice" != x ]; do 
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"        
        echo " M O N I T O R - M E N U"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "1.  Mailcow Logs 		- Create and configure mailcow Droplet"
        echo "2.  Cloud-init Logs 		- Destroy mailcow Droplet"
        echo "x.  Exit"
        read -p "Enter choice [ 0 - 5 ] " choice
        case $choice in
                1) mailcow_logs; pause ;;
                2) droplet_ssh "sudo less /var/log/cloud-init-output*"; pause ;;
                x) return 0;;
                *) echo -e "${RED}Error...${STD}" && sleep 1
        esac
done

}


# Function to display Deploy menu
function menu_deploy() {
local choice=""

while [ "$choice" != x ]; do 
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"        
        echo " D E P L O Y - M E N U"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
        echo "1.  Create Droplet 		- Create and configure mailcow Droplet"
        echo "2.  Configure Droplet		- Configure and Secure Droplet"
        echo "3.  Install Mailcow 		- Create and configure mailcow Droplet"
        echo "4.  Configure Backup 		- Configure mailcow backup"
        echo "x.  Exit"
        read -p "Enter choice [ 0 - 5 ] " choice
        case $choice in
		1) droplet_create; pause ;;
                2) droplet_configure; pause ;;
                3) mailcow_install; pause ;;
                4) droplet_backup; pause ;;
                5) pause ;;
                x) return 0;;
                *) echo -e "${RED}Error...${STD}" && sleep 1
        esac
done


}



# Function to display main menu
function menu_main() {
local choice=""

while [ 1 ]; do 
        clear
        echo "~~~~~~~~~~~~~~~~~~~~~"    
        echo " M A I N - M E N U"
        echo "~~~~~~~~~~~~~~~~~~~~~"
        echo "1. Deploy"
        echo "2. Manage Droplet"
        echo "3. Manage Mailcow"
        echo "4. Monitor"
        echo "x. Exit"
        read -p "Enter choice [ 0 - 5 ] " choice
        case $choice in
                1) menu_deploy ;;
                2) menu_manageDroplet ;;
                3) menu_manageMailcow ;;
                4) menu_monitor ;;
                6) droplet_sshBatch "t1"; pause ;;
                7) show_help; pause ;;
                x) exit 0;;
                *) echo -e "${RED}Error...${STD}" && sleep 1
        esac
done
}




########################
### SCRIPT MAIN LOOP ###
########################

# Read command line parameters
while getopts "hd" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  DEBUG=1
        ;;
        esac
done

# Load global variables
read_env_conf

# Load main menu
menu_main

exit 0
