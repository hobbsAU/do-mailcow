# TODO

## Script
* Move mailcow functions to server
* Harden host firewall, sshd, dockerd etc

## MC-Provisioning
* automate mc deployment
* restore mail data from borgbackup

## MC-Backup
* Update Backup and Restore script to ensure services are started prior to restore (otherwise restore fails)
* Use borgbackup for vmail docker volume, use automated script and borgbackup for config; config online daily and offline weekly
* Configure host for automated backups of config and vmail
