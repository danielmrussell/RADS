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
INSTALLER="/root/ADDCInstaller/DC1-Install.sh"

cat << 'EOF' >> "$PROFILE"

## Run RADS installer on every interactive login ##
if [[ $- == *i* ]]; then
  /root/ADDCInstaller/DC1-Install.sh
fi
EOF
if [[ -f "$INSTALLER" ]]; then
  chmod +x "$INSTALLER"
else
  echo "WARNING: Installer not found at $INSTALLER"
fi



# Include the common code file
# Get the directory of the current script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common file using an absolute path reference
source "$SCRIPT_DIR/common.sh"




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
  echo -e "                    ${GREEN}Rocky Linux${RESET} ${CYAN}RADS SECONDARY/TERTIARY${RESET} ${YELLOW}Builder${RESET}"

  sleep 2
}



# ========= SHOW CHECKLIST TO USER =========

show_ad_server_checklist() {
  dialog --backtitle "Welcome to the RADS Domain/Forest Installer" --title "First AD Server Installation Checklist" --msgbox "\
*********************************************
This will Install another AD Server to a pre-existing Forest/Domain

Checklist:
Before the Installer starts, please make sure you have the following information

    1. THE FQDN of the Pre-existing DC
    2. An Administrator password that you will use to join the domain
    3. An NTP Subnet for your clients. This server will provide syncronized time
    4. The beginning and ending lease range for DHCP (optional)
    5. The client default gateway IP Address for the DHCP Scope (optional)
    6. A Friendly name as a description to the DHCP scope created (optional


*********************************************" 20 100
}

#===========INSTALL PACKAGE REQUIREMENTS=============
install_requirements() {
    local LOG_FILE="/tmp/install_openldap_clients.log"
    : > "$LOG_FILE"

    local PACKAGES=("openldap-clients" "expect" "bind-utils")

    dialog --backtitle "Installing Requirement" --title "Installing..." \
        --infobox "Installing required packages...\nPlease wait." 5 50

    {
        echo "Starting installation of: ${PACKAGES[*]}"
        dnf -y install "${PACKAGES[@]}" &>> "$LOG_FILE"
        echo $? > /tmp/ldap_install_status
    } &

    for i in {1..10}; do
        sleep 0.3
        echo $((i * 10))
    done | dialog --backtitle "Installing Requirement" --gauge "Installing required packages..." 6 50

    INSTALL_EXIT=$(cat /tmp/ldap_install_status)
    rm -f /tmp/ldap_install_status

    if [[ "$INSTALL_EXIT" -eq 0 ]]; then
        dialog --backtitle "Installing Requirement" --infobox "Packages installed successfully." 6 50
        return 0
    else
        dialog --backtitle "Installing Requirement" --title "Error" \
            --msgbox "Failed to install required packages.\nCheck log: $LOG_FILE" 8 60
        return 1
    fi
}


#===========VALIDATE AD SERVER AND EXPORT=============

validate_ad_server() {
  while true; do
    ADDC=$(dialog --clear --backtitle "AD Server Validation" --inputbox "Enter the FQDN of the pre-existing AD Server:" 10 60 3>&1 1>&2 2>&3 3>&-)
    [ $? -ne 0 ] && clear && return 1

    if [ -z "$ADDC" ]; then
      dialog --backtitle "AD Server Validation" --msgbox "The response cannot be blank. Please try again." 6 50
      continue
    fi

    DNS_RESULT="DNS resolution failed"
    PING_RESULT="Ping failed"
    LDAP_RESULT="LDAP SRV record not found"
    KRB_RESULT="Kerberos SRV record not found"
    ALL_OK=true

    IP_ADDRESS=$(dig +short "$ADDC" | head -n 1)
    if [ -n "$IP_ADDRESS" ]; then
      DNS_RESULT="DNS resolved to $IP_ADDRESS"
    else
      ALL_OK=false
    fi

    if [ -n "$IP_ADDRESS" ] && ping -c 1 "$IP_ADDRESS" &> /dev/null; then
      PING_RESULT="Ping successful to $IP_ADDRESS"
    else
      ALL_OK=false
    fi

    DOMAIN="${ADDC#*.}"

    LDAP_SRV=$(host -t SRV _ldap._tcp."${DOMAIN}")
    if echo "$LDAP_SRV" | grep -q "$ADDC"; then
      LDAP_RESULT="LDAP SRV record found for $ADDC"
    else
      ALL_OK=false
    fi

    KRB_SRV=$(host -t SRV _kerberos._udp."${DOMAIN}")
    if echo "$KRB_SRV" | grep -q "$ADDC"; then
      KRB_RESULT="Kerberos SRV record found for $ADDC"
    else
      ALL_OK=false
    fi

    # Correct vertical formatting using literal newlines
    RESULT_MSG=$(cat <<EOF
AD Server: $ADDC

$DNS_RESULT
$PING_RESULT
$LDAP_RESULT
$KRB_RESULT
EOF
)

  if $ALL_OK; then
  dialog --backtitle "AD Server Validation" --msgbox "$RESULT_MSG

All checks passed." 15 60
  export ADDC
  export DC_IP_ADDRESS="$IP_ADDRESS"
  export DOMAIN
  clear
  return 0

    else
      dialog --backtitle "AD Server Validation" --yesno "$RESULT_MSG

One or more checks failed. Would you like to try again?" 18 60
      [ $? -ne 0 ] && clear && return 1
    fi
  done
}

#===========VALIDATE ADMIN PASSWORD AND EXPORT=============
validate_ad_admin_password() {
  while true; do
    ADMINPASS=$(dialog --clear --backtitle "Validate Administrator Password" \
      --insecure --passwordbox "Enter the password for 'Administrator@$DOMAIN'" 10 60 3>&1 1>&2 2>&3 3>&-)

    [ $? -ne 0 ] && clear && return 1

    if [ -z "$ADMINPASS" ]; then
      dialog --backtitle "Validate Administrator Password" \
        --msgbox "Password cannot be blank. Please try again." 6 50
      continue
    fi

    # Try secure bind using LDAPS with relaxed cert validation
    LDAPTLS_REQCERT=never ldapwhoami -x -H "ldaps://$DC_IP_ADDRESS" \
      -D "Administrator@$DOMAIN" -w "$ADMINPASS" >/tmp/ldap_test.out 2>&1

    if [ $? -eq 0 ]; then
      dialog --backtitle "Validate Administrator Password" \
        --infobox "Administrator credentials validated successfully." 5 60
      sleep 2
      export ADMINPASS
      clear
      return 0
    else
      ERROR_MSG=$(cat /tmp/ldap_test.out | tail -n 1)
      dialog --backtitle "Validate Administrator Password" \
        --msgbox "Authentication failed:\n\n$ERROR_MSG" 10 60
      dialog --backtitle "Validate Administrator Password" \
        --yesno "Would you like to try again?" 7 50
      [ $? -ne 0 ] && clear && return 1
    fi
  done
}
#===========CONFIGURE NTP=============
configure_chrony_from_addc() {
    local LOG_NTP="/tmp/chrony_ntp_configure.log"
    local ALLOW_NET=""
    touch "$LOG_NTP"

    log_ntp() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_NTP"
    }

    validate_cidr() {
        [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
    }

    prompt_allow_networks() {
        while true; do
            ALLOW_NET=$(dialog --title "Allow NTP Access" \
                --backtitle "Configure NTP" --inputbox "Enter the CIDR range to allow NTP access (e.g., 192.168.1.0/24):" 8 80 \
                3>&1 1>&2 2>&3 3>&-)
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

    check_ntp_operational_on_addc() {
        dialog --backtitle "Configure NTP" --title "NTP Check" \
            --infobox "Checking NTP availability on $ADDC..." 4 60
        sleep 1

        local was_active=0
        if systemctl is-active --quiet chronyd; then
            systemctl stop chronyd
            was_active=1
            log_ntp "Stopped chronyd temporarily for NTP test"
        fi

        chronyd -q "server $ADDC iburst" &> /tmp/chrony_test_ntp.out
        local result=$?

        if (( was_active == 1 )); then
            systemctl start chronyd
            log_ntp "Restarted chronyd after NTP test"
        fi

        if grep -qE "System clock wrong|Leap status" /tmp/chrony_test_ntp.out && [ $result -eq 0 ]; then
            log_ntp "ADDC $ADDC is responding to NTP"
            return 0
        else
            dialog --backtitle "Configure NTP" --title "Chrony NTP Check Failed" \
                --yesno "The ADDC ($ADDC) does not appear to be serving NTP.\n\nDo you want to proceed anyway?" 10 60
            return $?
        fi
    }

    update_chrony_config() {
        cp /etc/chrony.conf /etc/chrony.conf.bak
        sed -i '/^\(server\|pool\|allow\)[[:space:]]/d' /etc/chrony.conf

        echo "server $ADDC iburst" >> /etc/chrony.conf
        log_ntp "Set server $ADDC as NTP source in chrony.conf"

        if [[ -n "$ALLOW_NET" ]]; then
            echo "allow $ALLOW_NET" >> /etc/chrony.conf
            log_ntp "Allowed subnet $ALLOW_NET in chrony.conf"
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
            dialog --backtitle "Configure NTP" --title "NTP Configuration" --infobox "Time synchronized successfully:\n\n$TRACKING" 15 100
            sleep 3
        else
            dialog --backtitle "Configure NTP" --title "NTP Configuration" --yesno "Time sync failed after 3 attempts.\nDo you want to proceed anyway?" 8 100
            [[ $? -eq 0 ]] || return 1
        fi
        return 0
    }

    # Ensure ADDC is defined
    if [[ -z "$ADDC" ]]; then
        dialog --backtitle "Configure NTP" --title "NTP Configuration" \
            --msgbox "ADDC variable not set. Please run domain controller validation first." 6 60
        return 1
    fi

    # Prompt for allowed network
    if ! prompt_allow_networks; then
        dialog --backtitle "Configure NTP" --title "NTP Configuration" \
            --msgbox "No network was allowed. Configuration cancelled." 6 50
        return 1
    fi

    # Check that ADDC responds to NTP
    if ! check_ntp_operational_on_addc; then
        return 1
    fi

    update_chrony_config

    if ! validate_time_sync; then
        dialog --backtitle "Configure NTP" --title "NTP Configuration" --msgbox "NTP configuration aborted." 6 40
        return 1
    fi

    dialog --backtitle "Configure NTP" --title "NTP Configuration" \
        --infobox "NTP configuration completed successfully." 4 60
    sleep 3
    return 0
}


#===========PROVISION SAMBA WITH MOCK=============
configure_samba_provisioning() {
  DOMAIN=$(hostname | sed 's/^[^.:]*[.:]//' | sed -e 's/\(.*\)/\U\1/')
  ADDOMAIN=$(hostname | sed 's/^[^.:]*[.:]//' | cut -d. -f1 | sed -e 's/\(.*\)/\U\1/')

  dialog --backtitle "Samba Build --dc with Mock" --title "Samba Source Build" --infobox \
  "Downloading and compiling Samba from source using 'mock'\n\nThis may take up to 30 minutes\n\nThe Installer will Continue Shortly " 10 80
  sleep 4

  SAMBA_SRCDIR=$(mktemp -d)
  trap 'rm -rf "$SAMBA_SRCDIR"' EXIT

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

    # Attempt domain join
  output=$(samba-tool domain join "$DOMAIN" DC -U "administrator%$ADMINPASS" 2>&1)

  # Bail early if join failed
  if echo "$output" | grep -q "ERROR"; then
    dialog --backtitle "Samba Build --DC Join" --msgbox "Domain join failed. Check output:\n\n$output" 10 70
    return 1
  fi

  # Confirm smb.conf exists before continuing
  if [[ -f /etc/samba/smb.conf ]]; then
    # Set DNS resolver
    # Get the primary IP address (first non-loopback IP)
    IP=$(hostname -I | awk '{print $1}')
    nmcli con mod "$INTERFACE" ipv4.dns "$IP"
    systemctl restart NetworkManager

    # Configure KDC
    \cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

    # Modify smb.conf
    sed -i '7i \       \ #Added for FreeRADIUS Support' /etc/samba/smb.conf
    sed -i '8i \       \ ntlm auth = mschapv2-and-ntlmv2-only' /etc/samba/smb.conf
    sed -i '9i \       \#ldap server require strong auth = no #UNCOMMENT THIS IF YOU NEED PLAIN LDAP BIND (non-TLS)' /etc/samba/smb.conf
    sed -i '10i \       \dns forwarder = 208.67.222.222' /etc/samba/smb.conf

    # Start Samba
    systemctl enable samba --now
  else
    dialog --backtitle "Samba Build --DC Join" --msgbox "Domain join reported success, but smb.conf is missing. Aborting." 8 60
    return 1
  fi

  # Verify join
  if ! verify_samba_join; then
    dialog --backtitle "Samba Build --DC Join" --msgbox "Join completed, but verification failed." 7 60
    return 1
  fi

  # Success
  dialog --backtitle "Samba Build --DC Join" --msgbox "Successfully joined as additional DC." 7 60
  return 0
}


verify_samba_join() {
    local ERRORS=()
    local LOG="/tmp/samba_join_verify.log"
    : > "$LOG"

    # --- Delay before verification ---
    local seconds=10
    for ((i=seconds; i>=0; i--)); do
        dialog --backtitle "Samba Join Verification" --title "Waiting for Domain Join to Settle" \
            --infobox "Allowing time for replication and service initialization...\n\nStarting verification in ${i} seconds." 8 80
        sleep 1
    done

    echo "Verifying Samba domain join status..." | tee -a "$LOG"

    # 1. Check smb.conf exists and is valid
    if [[ ! -f /etc/samba/smb.conf ]]; then
        ERRORS+=("Missing /etc/samba/smb.conf")
    else
        if ! grep -q "server role[[:space:]]*=[[:space:]]*active directory domain controller" /etc/samba/smb.conf; then
            ERRORS+=("smb.conf exists but does not show 'active directory domain controller'")
        fi
    fi

    # 2. Check Samba AD database files
    for file in secrets.ldb sam.ldb krb5.conf; do
        if [[ ! -f /var/lib/samba/private/$file ]]; then
            ERRORS+=("Missing $file in /var/lib/samba/private/")
        fi
    done

    # 3. Check DRS replication info
    DRS_OUTPUT=$(samba-tool drs showrepl 2>&1)
    echo "$DRS_OUTPUT" >> "$LOG"

    HOSTNAME_UPPER=$(hostname -s | tr '[:lower:]' '[:upper:]')

    if ! echo "$DRS_OUTPUT" | grep -q "Default-First-Site-Name\\\\${HOSTNAME_UPPER}"; then
        ERRORS+=("drs showrepl output missing expected hostname: $HOSTNAME_UPPER")
    fi

    if ! echo "$DRS_OUTPUT" | grep -q "Last success"; then
        ERRORS+=("No successful inbound replication events detected")
    fi

    if echo "$DRS_OUTPUT" | grep -i "consecutive failure(s): [^0]" | grep -vq "0 consecutive failure(s)"; then
        ERRORS+=("There are replication failures in the DRS output")
    fi

    # 4. Check for local DC presence in computer list
    DC_COMPUTER_NAME="${HOSTNAME_UPPER}\$"
    if ! samba-tool computer list | grep -q "^${DC_COMPUTER_NAME}$"; then
        ERRORS+=("This DC (${DC_COMPUTER_NAME}) not found in samba-tool computer list")
    fi

    # 5. Check Samba service
    if ! systemctl is-active --quiet samba; then
        ERRORS+=("Samba service is not active")
    fi

    # 6. Optional: LDAP bind check (non-fatal)
    if ! LDAPTLS_REQCERT=never ldapwhoami -x -H "ldap://localhost" \
        -D "Administrator@$DOMAIN" -w "$ADMINPASS" &>/dev/null; then
        echo "⚠️  Warning: LDAP bind failed. Samba may not be fully ready." >> "$LOG"
    fi

    # Final decision
    if (( ${#ERRORS[@]} > 0 )); then
        printf "%s\n" "${ERRORS[@]}" >> "$LOG"
        dialog --backtitle "Samba Join Verification" --title "Verification Failed" \
            --msgbox "Samba does not appear to be fully joined as a DC.\n\nSee log: $LOG\n\nFirst error: ${ERRORS[0]}" 12 70
        return 1
    else
        dialog --backtitle "Samba Join Verification" --msgbox "Samba AD join verified successfully.\nThis server is an active DC." 7 60
        return 0
    fi
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
install_requirements
validate_ad_server
validate_ad_admin_password
configure_chrony_from_addc
configure_dhcp_server
update_and_install_packages
vm_detection
configure_selinux
configure_firewall
configure_samba_provisioning
add_dnf_smb_mon_cron
copy_samba_dnf_pkg_update
update_issue_file
setup_samba_ldaps_cert
test_ldap_secure_connection
check_kerberos_ticket
check_smbclient_login
check_dns_srv_records
test_anonymous_login
cleanup_strong_auth_line
configure_fail2ban
configure_dnf_automatic
check_and_enable_services
install_server_management
cleanup_installer_files
prompt_reboot_now
