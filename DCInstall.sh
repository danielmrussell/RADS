#!/usr/bin/env bash
# Include common code.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

clear
echo -e "[${GREEN}SUCCESS${TEXTRESET}] Rocky ${CYAN}RADS FOREST${TEXTRESET} Builder ${YELLOW}Installation${TEXTRESET}"

# Checking for user permissions
if [ "$USER" = "root" ]; then
  echo -e "[${GREEN}SUCCESS${TEXTRESET}] Running as root user"
  sleep 2
else
  echo -e "[${RED}ERROR${TEXTRESET}] This program must be run as root."
  echo "Exiting..."
  exit 1
fi

cd /root

# Checking for version information
if [ "$MAJOROS" -ge 9 ]; then
  echo -e "[${GREEN}SUCCESS${TEXTRESET}] Detected compatible OS version: Rocky 9.x or greater"
  sleep 2
else
  echo -e "[${RED}ERROR${TEXTRESET}] Sorry, but this installer only works on Rocky 9.X or greater"
  echo -e "Please upgrade to ${GREEN}Rocky 9.x${TEXTRESET} or later"
  echo "Exiting the installer..."
  exit 1
fi



# ========= REMOVE BRACKETED PASTING =========
sed -i '8i set enable-bracketed-paste off' /etc/inputrc


# ========= INSERT INSTALLER INTO .bash_profile =========
PROFILE="/root/.bash_profile"
BACKUP="/root/.bash_profile.bak.$(date +%Y%m%d%H%M%S)"
INSTALLER="/root/ADDCInstaller/DCInstall.sh"

cat << 'EOF' >> "$PROFILE"

## Run RADS installer on every interactive login ##
if [[ $- == *i* ]]; then
  /root/ADDCInstaller/DCInstall.sh
fi
EOF

if [[ -f "$INSTALLER" ]]; then
  chmod +x "$INSTALLER"
else
  echo "WARNING: Installer not found at $INSTALLER"
fi

# ========= UI SCREENS =========
show_welcome_screen() {
  clear
  echo -e "${GREEN}
                               .*((((((((((((((((*
                         .(((((((((((((((((((((((((((/
                      ,((((((((((((((((((((((((((((((((((.
                    (((((((((((((((((((((((((((((((((((((((/
                  (((((((((((((((((((((((((((((((((((((((((((/
                .(((((((((((((((((((((((((((((((((((((((((((((
               ,((((((((((((((((((((((((((((((((((((((((((((((((.
               ((((((((((((((((((((((((((((((/   ,(((((((((((((((
              /((((((((((((((((((((((((((((.        /((((((((((((*
              ((((((((((((((((((((((((((/              ((((((((((
              ((((((((((((((((((((((((                   *((((((/
              /((((((((((((((((((((*                        (((((*
               ((((((((((((((((((             (((*            ,((
               .((((((((((((((.            /(((((((
                 ((((((((((/             (((((((((((((/
                  *((((((.            /((((((((((((((((((.
                    *(*)            ,(((((((((((((((((((((((,
                                 (((((((((((((((((((((((/
                              /((((((((((((((((((((((.
                                ,((((((((((((((,
${RESET}"
  echo -e "                         ${GREEN}Rocky Linux${RESET} ${CYAN}RADS FOREST${RESET} ${YELLOW}Builder${RESET}"

  sleep 2
}



# ========= SHOW CHECKLIST TO USER =========

show_ad_server_checklist() {
  dialog --backtitle "Welcome to the RADS Domain/Forest Installer" --title "First AD Server Installation Checklist" --msgbox "\
*********************************************

This will Install the FIRST AD Server and build a new Forest/Domain

Checklist:
Before the Installer starts, please make sure you have the following information:

  1. An Administrator password that you want to use for the new DOMAIN
  2. An NTP Subnet for your clients. This server will provide synchronized time
  3. The beginning and ending lease range for DHCP (optional)
  4. The client default gateway IP Address for the DHCP Scope (optional)
  5. A Friendly name as a description to the DHCP scope created (optional)

*********************************************" 20 100
}


# ========= ASK FOR DOMAIN PASSWORD CREATION =========
TMP_FILE=$(mktemp)

show_password_requirements() {
  dialog --backtitle "Domain Administrator Password Setup" --title "Administrator Password Requirements" --msgbox \
"Please create the DOMAIN password for the Administrator Account

Your password must meet the following criteria:

- At least 8 characters
- At least 1 special character (!@#\$%^&)
- At least 1 uppercase letter
- At least 1 lowercase letter
- At least 1 number" 15 90
}

validate_admin_password() {
  local password="$1"

  if [ ${#password} -lt 8 ]; then
    echo "Password is too short (minimum 8 characters)."
    return 1
  fi
  if ! [[ "$password" =~ [0-9] ]]; then
    echo "Password must include at least one number."
    return 1
  fi
  if ! [[ "$password" =~ [\!\@\#\$\%\^\&\*] ]]; then
    echo "Password must include at least one special character (!@#\$%^&*)."
    return 1
  fi
  if ! [[ "$password" =~ [A-Z] && "$password" =~ [a-z] ]]; then
    echo "Password must contain both uppercase and lowercase letters."
    return 1
  fi

  return 0
}

prompt_admin_password() {
  show_password_requirements

  while true; do
    dialog --backtitle "Domain Administrator Password Setup" --insecure --passwordbox "Enter Administrator Password:" 10 60 2> "$TMP_FILE"
    ADMINPASS=$(<"$TMP_FILE")

    if [ -z "$ADMINPASS" ]; then
      dialog --backtitle "Domain Administrator Password Setup" --msgbox "Password cannot be blank. Please try again." 6 50
      continue
    fi

    error=$(validate_admin_password "$ADMINPASS" 2>&1)
    if ! validate_admin_password "$ADMINPASS"; then
      dialog --backtitle "Domain Administrator Password Setup" --msgbox "$error" 8 60
      continue
    fi

    dialog --backtitle "Domain Administrator Password Setup" --insecure --passwordbox "Confirm Administrator Password:" 10 60 2> "$TMP_FILE"
    VERIFYPASS=$(<"$TMP_FILE")

    if [ -z "$VERIFYPASS" ]; then
      dialog --backtitle "Domain Administrator Password Setup" --msgbox "Confirmation cannot be blank. Please try again." 6 50
      continue
    fi

    if [ "$ADMINPASS" = "$VERIFYPASS" ]; then
      dialog --backtitle "Domain Administrator Password Setup" --infobox "Password accepted and saved." 5 40
      sleep 2
      break
    else
      dialog --backtitle "Domain Administrator Password Setup" --msgbox "Passwords do not match. Please try again." 6 50
    fi
  done

  export ADMINPASS
  rm -f "$TMP_FILE"
}

# ========= CONFIGURE CHRONY =========
declare -a ADDR
LOG_NTP="/tmp/chrony_ntp_configure.log"
touch "$LOG_NTP"

log_ntp() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_NTP"
}

validate_cidr() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

prompt_ntp_servers() {
    while true; do
        NTP_SERVERS=$(dialog --title "Chrony NTP Configuration" \
            --backtitle "Configure NTP" --inputbox "Enter up to 3 comma-separated NTP server IPs or FQDNs:" 8 60 \
            3>&1 1>&2 2>&3)
        exit_status=$?
        if [ $exit_status -eq 1 ] || [ $exit_status -eq 255 ]; then
            return 1
        fi

        if [[ -n "$NTP_SERVERS" ]]; then
            IFS=',' read -ra ADDR <<< "$NTP_SERVERS"
            if (( ${#ADDR[@]} > 3 )); then
                dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --msgbox "You may only enter up to 3 servers." 6 50
                continue
            fi
            return 0
        else
            dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --msgbox "The input cannot be blank. Please try again." 6 50
        fi
    done
}

prompt_allow_networks() {
    while true; do
        ALLOW_NET=$(dialog --title "Allow NTP Access" \
            --backtitle "Configure NTP" --inputbox "Enter the CIDR range to allow NTP access (e.g., 192.168.1.0/24):" 8 80 \
            3>&1 1>&2 2>&3)
        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            return 1
        fi

        if validate_cidr "$ALLOW_NET"; then
            return 0
        else
            dialog --backtitle "Configure NTP" --msgbox "Invalid CIDR format. Please try again." 6 40
        fi
    done
}

update_chrony_config() {
    cp /etc/chrony.conf /etc/chrony.conf.bak
    sed -i '/^\(server\|pool\|allow\)[[:space:]]/d' /etc/chrony.conf

    for srv in "${ADDR[@]}"; do
        echo "server ${srv} iburst" >> /etc/chrony.conf
        log_ntp "Added server ${srv} to chrony.conf"
    done

    if [[ -n "$ALLOW_NET" ]]; then
        echo "allow $ALLOW_NET" >> /etc/chrony.conf
        log_ntp "Added allow $ALLOW_NET to chrony.conf"
    fi

    systemctl restart chronyd
    sleep 2
}

validate_time_sync() {
    local attempt=1
    local success=0

    while (( attempt <= 3 )); do
        dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --infobox "Validating time sync... Attempt $attempt/3" 4 50
        sleep 5

        TRACKING=$(chronyc tracking 2>&1)
        echo "$TRACKING" >> "$LOG_NTP"

        if echo "$TRACKING" | grep -q "Leap status[[:space:]]*:[[:space:]]*Normal"; then
            success=1
            break
        fi
        ((attempt++))
    done

    if [[ "$success" -eq 1 ]]; then
        dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --infobox "Time synchronized successfully:\n\n$TRACKING" 15 100
        sleep 3
    else
        dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --yesno "Time sync failed after 3 attempts.\nDo you want to proceed anyway?" 8 100
        [[ $? -eq 0 ]] || return 1
    fi
    return 0
}


#===========PROVISION SAMBA WITH MOCK=============
configure_samba_provisioning() {
  OSVER=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release)
  MAJOROS=$(cut -d. -f1 <<< "$OSVER")
  MINOROS=$(cut -d. -f2 <<< "$OSVER")

  DOMAIN=$(hostname | sed 's/^[^.:]*[.:]//' | sed -e 's/\(.*\)/\U\1/')
  ADDOMAIN=$(hostname | sed 's/^[^.:]*[.:]//' | cut -d. -f1 | sed -e 's/\(.*\)/\U\1/')

  dialog --backtitle "Samba Build --dc with Mock" --title "Samba Source Build" --infobox \
  "Downloading and compiling Samba from source using 'mock'\n\nThis may take up to 30 minutes\n\nThe Installer will Continue Shortly " 10 80
  sleep 4
  
  dnf download samba --source --destdir "$SAMBA_SRCDIR"
  # if ! ls /root/samba-*.rpm 1>/dev/null 2>&1; then
  if [[ ! $(find "$SAMBA_SRCDIR" -maxdepth 1 -type f -name "samba*.src.rpm" | wc -l) ]]; then # count to make sure its not zero (should be 1)
    dialog --backtitle "Samba Build --dc with Mock" --msgbox "Samba source RPM failed to download. Check your network." 8 50
    return 1
  fi

  # MOCKSMBVER=$(dnf provides samba | grep samba | sed '2,4d' | cut -d: -f1 | cut -dx -f1)
  MOCK_RESULTDIR=$(mktemp -d)
  trap 'rm -rf "$MOCK_RESULTDIR"' EXIT
  MOCKCMD="mock -r rocky-${MAJOROS}-x86_64 --enablerepo=devel --define 'dist .el${MAJOROS}_${MINOROS}.dc' --with dc --resultdir=\"$MOCK_RESULTDIR\" \"$SAMBA_SRCDIR/samba*.src.rpm\""

  TMPLOG=$(mktemp)
  PIPE=$(mktemp -u)
  mkfifo "$PIPE"

  # Launch mock inside a pseudo-terminal using `script`
  script -q -c "$MOCKCMD" /dev/null > "$PIPE" 2>&1 &
  MOCKPID=$!

  dialog --backtitle "Samba Build --dc with Mock" --title "Building Samba with Mock (Live)" --programbox 25 150 < "$PIPE"

  wait $MOCKPID
  rm -f "$PIPE"

  # if ! ls /var/lib/mock/rocky-${MAJOROS}-x86_64/result/*.rpm &>/dev/null; then
  if [[ ! $(find "$MOCK_RESULTDIR" -maxdepth 1 -type f -name "*.rpm" | wc -l) ]]; then # count to make sure there are not zero
    dialog --backtitle "Samba Build --dc with Mock" --title "Mock Build Failed" --msgbox "Build failed. Check logs manually." 8 60
    return 1
  fi

  mkdir -p /root/.samba
  cp "$MOCK_RESULTDIR/*.rpm" /root/.samba
  # cp /var/lib/mock/rocky-${MAJOROS}-x86_64/result/*.rpm /root/.samba
  
  createrepo /root/.samba
  # dnf config-manager --add-repo /root/.samba
  dnf -y install --nogpgcheck samba-dc samba-client krb5-workstation samba \
    --repofrompath=samba,/root/.samba \
    --enablerepo=samba >/dev/null

  mv -f /etc/samba/smb.conf /etc/samba/smb.bak.orig

  output=$(samba-tool domain provision \
    --realm="$DOMAIN" \
    --domain="$ADDOMAIN" \
    --adminpass="$ADMINPASS" 2>&1)

  echo "$output"

  if echo "$output" | grep -q "ERROR"; then
    dialog --backtitle "Samba Build --dc with Mock" --msgbox "Provisioning failed. Check output." 8 60
    return 1
  fi

  dialog --backtitle "Samba Build --dc with Mock" --msgbox "Samba AD Domain provisioned successfully." 7 50
  return 0
}

#===========CREATE KDC=============
create_kdc_conf() {
  KRB5_SRC="/var/lib/samba/private/krb5.conf"
  KRB5_DEST="/etc/krb5.conf"

  if [[ ! -f "$KRB5_SRC" ]]; then
    dialog --backtitle "Configure Kerberos (KDC)" --title "KDC Error" --msgbox "Kerberos configuration file not found at $KRB5_SRC.\nProvisioning may have failed. Exiting..." 8 60
    exit 1
  fi

  dialog --backtitle "Configure Kerberos (KDC)" --title "Creating KDC" --infobox "Copying Kerberos configuration to $KRB5_DEST..." 5 60
  sleep 2
  \cp -rf "$KRB5_SRC" "$KRB5_DEST"

  if [[ $? -eq 0 ]]; then
    dialog --backtitle "Configure Kerberos (KDC)" --infobox "Kerberos configuration successfully copied." 6 50
    sleep 2
  else
    dialog --backtitle "Configure Kerberos (KDC)" --msgbox "Failed to copy Kerberos configuration. Please check permissions." 6 60
    sleep 2
  fi
}

#===========SET DNS to ITSELF=============
set_local_dns_resolver() {
  IP=$(hostname -I | awk '{print $1}')  # Get first IP address
  INTERFACE=$(nmcli -t -f DEVICE,STATE dev | awk -F: '$2=="connected" {print $1}' | head -n1)

  if [[ -z "$IP" || -z "$INTERFACE" ]]; then
    dialog --backtitle "Configure Local Resolver" --msgbox "Failed to detect IP or active interface. Cannot set DNS." 8 50
    return 1
  fi

  dialog --backtitle "Configure Local Resolver" --title "Setting DNS Resolver" --infobox \
  "Configuring ${INTERFACE} to use ${IP} as its primary DNS resolver..." 5 80
  sleep 2

  nmcli con mod "$INTERFACE" ipv4.dns "$IP"
  systemctl restart NetworkManager

  if [[ $? -eq 0 ]]; then
    dialog --backtitle "Configure Local Resolver" --infobox "DNS resolver successfully set to ${IP} on ${INTERFACE}." 6 80
    sleep 2
  else
    dialog --backtitle "Configure Local Resolver" --msgbox "Failed to apply DNS resolver configuration." 6 50
    return 1
  fi
}

#===========ADD FREERADIUS SUPPORT=============
add_freeradius_support() {
  SMB_CONF="/etc/samba/smb.conf"

  if [[ ! -f "$SMB_CONF" ]]; then
    dialog --title "FreeRADIUS Error" --msgbox "$SMB_CONF not found. Please verify Samba is installed." 7 60
    exit 1
  fi

  dialog --backtitle "Configuring smb.conf" --title "FreeRADIUS Integration" --infobox "Adding default FreeRADIUS support to smb.conf..." 5 60
  sleep 2

  sed -i '8i \       \ #Added for FreeRADIUS Support' "$SMB_CONF"
  sed -i '9i \       \ ntlm auth = mschapv2-and-ntlmv2-only' "$SMB_CONF"
  sed -i '10i \       \\#ldap server require strong auth = no #UNCOMMENT THIS IF YOU NEED PLAIN LDAP BIND (non-TLS)' "$SMB_CONF"

  dialog --backtitle "Configuring smb.conf" --infobox "FreeRADIUS options successfully added to smb.conf." 6 60
  sleep 2
}

#===========ENABLE AND CHECK SAMBA DC SERVICE=============
enable_and_check_samba_service() {
  SERVICE_NAME="samba"

  # Check if the service exists
  if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    dialog --title "Service Error" --msgbox "The service '${SERVICE_NAME}' was not found on this system.\nPlease ensure Samba is installed." 8 60
    exit 1
  fi

  # Enable and start the service
  dialog --backtitle "Validating Samba Service" --title "Samba Service" --infobox "Enabling and starting the Samba service..." 5 60
  sleep 2
  systemctl enable "$SERVICE_NAME" --now

  # Check service status
  samba_status=$(systemctl is-active "$SERVICE_NAME")
  if [[ "$samba_status" = "active" ]]; then
    dialog --backtitle "Validating Samba Service" --title "Samba Service" --infobox "Samba service is running." 5 40
  else
    dialog --backtitle "Validating Samba Service" --title "Samba Error" --msgbox "Samba service is NOT running.\nStatus: $samba_status" 7 50
    exit 1
  fi
  sleep 2
}

#===========REVERSE DNS ZONE CREATION=============
create_reverse_dns_zone() {
  LOG_FILE="/var/log/samba-reverse-zone.log"
  FQDN=$(hostname -f)
  IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }}')

  echo "[INFO] Detected FQDN: $FQDN" >> "$LOG_FILE"
  echo "[INFO] Detected IP: $IP" >> "$LOG_FILE"

  if [[ -z "$IP" ]]; then
    dialog --backtitle "Create Reverse Zone" --title "IP Detection Failed" --msgbox "Could not detect a valid IPv4 address from hostname -I." 6 60
    echo "[ERROR] No valid IPv4 address found." >> "$LOG_FILE"
    return 1
  fi

  REVERSE=$(echo "$IP" | awk -F. '{print $(NF-1)"."$(NF-2)"."$(NF-3)}')
  DEFAULT_ZONE="$REVERSE.in-addr.arpa"

  TMP_ZONE_FILE=$(mktemp)
  dialog --backtitle "Create Reverse Zone" --title "Reverse DNS Zone Suggestion" --inputbox \
    "A reverse DNS zone should be added to your Samba DNS.\n\nBased on your IP $IP, the recommended reverse zone is:\n\n  $DEFAULT_ZONE\n\nYou may press OK to accept this default or modify it." \
    12 70 "$DEFAULT_ZONE" 2> "$TMP_ZONE_FILE"
  RESPONSE=$?

  ZONE=$(<"$TMP_ZONE_FILE")
  rm -f "$TMP_ZONE_FILE"

  if [[ $RESPONSE -ne 0 || -z "$ZONE" ]]; then
    dialog --backtitle "Create Reverse Zone" --title "Operation Cancelled" --msgbox "No reverse zone was specified. Operation cancelled." 6 60
    echo "[WARN] Operation cancelled. No zone specified." >> "$LOG_FILE"
    return 1
  fi

  dialog --backtitle "Create Reverse Zone" --title "Creating Reverse DNS Zone" --infobox "Adding reverse DNS zone $ZONE to domain $FQDN..." 6 80
  echo "[INFO] Creating reverse zone: $ZONE on $FQDN" >> "$LOG_FILE"
  sleep 2

  samba-tool dns zonecreate "$FQDN" "$ZONE" -U "Administrator%$ADMINPASS" >> "$LOG_FILE" 2>&1
  if [[ $? -eq 0 ]]; then
    dialog --backtitle "Create Reverse Zone" --title "Reverse Zone Added" --infobox "Reverse DNS zone $ZONE successfully added to $FQDN." 7 80
    echo "[SUCCESS] Reverse zone $ZONE added to $FQDN" >> "$LOG_FILE"
    sleep 3
  else
    dialog --backtitle "Create Reverse Zone" --title "Zone Creation Failed" --msgbox "Failed to add reverse DNS zone.\n\nCheck $LOG_FILE for details." 10 70
    echo "[ERROR] Failed to create reverse zone $ZONE" >> "$LOG_FILE"
  fi
}
#===========RELAX PASSWORD SETTINGS FOR LAB=============
relax_lab_password_policy() {
  TMP_SELECTION=$(mktemp)
  TMP_LOG="/var/log/samba-password-policy.log"

  dialog --backtitle "Password Policy" --title "Relax Password Settings (Lab Use)" --checklist "\
Select which password policy changes you want to apply:\n\n\
Use SPACE to select/deselect options. Press ENTER to confirm, or Cancel to skip" 15 90 6 \
    1 "Disable complexity requirements" off \
    2 "Set history-length to 0" off \
    3 "Set min password age to 0" off \
    4 "Set max password age to 0" off 2> "$TMP_SELECTION"

  RESPONSE=$?
  CHOICES=$(<"$TMP_SELECTION")
  rm -f "$TMP_SELECTION"

  if [[ $RESPONSE -ne 0 || -z "$CHOICES" ]]; then
    dialog --backtitle "Password Policy" --title "Cancelled" --infobox "No changes were made to password policy." 5 50
    sleep 2
    return 1
  fi

  dialog --backtitle "Password Policy" --title "Applying Settings" --infobox "Applying selected password policy settings..." 5 50
  sleep 2

  for choice in $CHOICES; do
    case $choice in
      1)
        samba-tool domain passwordsettings set --complexity=off >> "$TMP_LOG" 2>&1
        ;;
      2)
        samba-tool domain passwordsettings set --history-length=0 >> "$TMP_LOG" 2>&1
        ;;
      3)
        samba-tool domain passwordsettings set --min-pwd-age=0 >> "$TMP_LOG" 2>&1
        ;;
      4)
        samba-tool domain passwordsettings set --max-pwd-age=0 >> "$TMP_LOG" 2>&1
        ;;
    esac
  done

  dialog --backtitle "Password Policy" --title "Password Policy Updated" --infobox "Selected settings have been applied.\nLog saved to $TMP_LOG." 6 60
  sleep 2
}



# ========= MAIN =========
check_samba_running
show_welcome_screen
detect_active_interface
prompt_static_ip_if_dhcp
check_root_and_os
check_and_enable_selinux
check_internet_connectivity
validate_and_set_hostname
show_ad_server_checklist
prompt_admin_password
configure_dhcp_server
# === Set Time ===
if ! prompt_ntp_servers; then
    dialog --title "Chrony NTP Configuration" --msgbox "NTP configuration was cancelled." 6 40
    exit 1
fi

if ! prompt_allow_networks; then
    dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --msgbox "No network was allowed. Configuration cancelled." 6 50
    exit 1
fi

update_chrony_config

if ! validate_time_sync; then
    dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --msgbox "Chrony configuration aborted." 6 40
    exit 1
fi

dialog --backtitle "Configure NTP" --title "Chrony NTP Configuration" --infobox "NTP configuration completed successfully." 4 60
sleep 3
#=== End Set time ===
update_and_install_packages
vm_detection
configure_selinux
configure_firewall
configure_samba_provisioning
create_kdc_conf
set_local_dns_resolver
add_freeradius_support
add_dnf_smb_mon_cron
copy_samba_dnf_pkg_update
enable_and_check_samba_service
update_issue_file
setup_samba_ldaps_cert
cleanup_strong_auth_line
test_ldap_secure_connection
check_kerberos_ticket
check_dns_srv_records
check_smbclient_login
test_anonymous_login
create_reverse_dns_zone
relax_lab_password_policy
configure_fail2ban
configure_dnf_automatic
install_server_management
check_and_enable_services
cleanup_installer_files
prompt_reboot_now
