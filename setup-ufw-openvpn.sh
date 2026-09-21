#!/bin/bash
# OpenVPN + UFW Firewall Setup Script
# Dynamically uses client IP from /var/log/openvpn/ipp.txt
# Resets rules to default first, then applies your configuration

set -euo pipefail

# ====================== CONFIG ======================
IPP_FILE="/var/log/openvpn/ipp.txt"
BEFORE_RULES="/etc/ufw/before.rules"
UFW_DEFAULTS="/etc/default/ufw"
CLIENT_NAME="pfsense-client"          # Change if your client has a different name
VPN_SUBNET="10.8.0.0/24"              # Recommended (your original had /8 which is too wide)
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== OpenVPN + UFW Firewall Setup ===${NC}"

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

# 1. Detect external interface
EXT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "$EXT_IF" ]]; then
    echo -e "${RED}Could not detect external interface${NC}"
    exit 1
fi
echo -e "External interface: ${GREEN}${EXT_IF}${NC}"

# 2. Read client IP from OpenVPN ipp.txt
if [[ ! -f "$IPP_FILE" ]]; then
    echo -e "${RED}Error: $IPP_FILE not found${NC}"
    echo "Make sure OpenVPN is running and has assigned an IP to a client."
    exit 1
fi

# Try to find the specific client first, otherwise take the first IP
CLIENT_IP=$(grep -i "$CLIENT_NAME" "$IPP_FILE" | awk -F',' '{print $2}' | tr -d '[:space:]' || true)

if [[ -z "$CLIENT_IP" ]]; then
    # Fallback: take the first IP in the file
    CLIENT_IP=$(awk -F',' 'NF>=2 {print $2; exit}' "$IPP_FILE" | tr -d '[:space:]')
fi

if [[ -z "$CLIENT_IP" || ! "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}Could not determine a valid client IP from $IPP_FILE${NC}"
    echo "Content of $IPP_FILE:"
    cat "$IPP_FILE"
    exit 1
fi

echo -e "OpenVPN Client IP: ${GREEN}${CLIENT_IP}${NC}"

# 3. Reset UFW to defaults
echo -e "\n${YELLOW}[1/5] Resetting UFW to defaults...${NC}"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# 4. Write before.rules (DNAT + OpenVPN rules)
echo -e "\n${YELLOW}[2/5] Writing before.rules with DNAT to ${CLIENT_IP}...${NC}"

# Backup existing before.rules
cp "$BEFORE_RULES" "${BEFORE_RULES}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat > "$BEFORE_RULES" << EOF
#
# rules.before
#
# Rules that should be run before the ufw command line added rules. Custom
# rules should be added to one of these chains:
#   ufw-before-input
#   ufw-before-output
#   ufw-before-forward
#

# Don't delete these required lines, otherwise there will be errors
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]
# End required lines


# allow all on loopback
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-output -o lo -j ACCEPT

# quickly process packets for which we already have a connection
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# drop INVALID packets (logs these in loglevel medium and higher)
-A ufw-before-input -m conntrack --ctstate INVALID -j ufw-logging-deny
-A ufw-before-input -m conntrack --ctstate INVALID -j DROP

# ok icmp codes for INPUT
-A ufw-before-input -p icmp --icmp-type destination-unreachable -j ACCEPT
-A ufw-before-input -p icmp --icmp-type time-exceeded -j ACCEPT
-A ufw-before-input -p icmp --icmp-type parameter-problem -j ACCEPT
-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT

# ok icmp code for FORWARD
-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j ACCEPT
-A ufw-before-forward -p icmp --icmp-type time-exceeded -j ACCEPT
-A ufw-before-forward -p icmp --icmp-type parameter-problem -j ACCEPT
-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT

# allow dhcp client to work
-A ufw-before-input -p udp --sport 67 --dport 68 -j ACCEPT

#
# ufw-not-local
#
-A ufw-before-input -j ufw-not-local

# if LOCAL, RETURN
-A ufw-not-local -m addrtype --dst-type LOCAL -j RETURN

# if MULTICAST, RETURN
-A ufw-not-local -m addrtype --dst-type MULTICAST -j RETURN

# if BROADCAST, RETURN
-A ufw-not-local -m addrtype --dst-type BROADCAST -j RETURN

# all other non-local packets are dropped
-A ufw-not-local -m limit --limit 3/min --limit-burst 10 -j ufw-logging-deny
-A ufw-not-local -j DROP

# allow MULTICAST mDNS for service discovery (be aware that the MULTICAST and
# LOCAL address related rules above mean that these will not match on non
# local / non multicast packets)
-A ufw-before-input -p udp -d 224.0.0.251 --dport 5353 -j ACCEPT

# allow MULTICAST UPnP for service discovery (be aware that the MULTICAST and
# LOCAL address related rules above mean that these will not match on non
# local / non multicast packets)
-A ufw-before-input -p udp -d 239.255.255.250 --dport 1900 -j ACCEPT

# don't delete the 'COMMIT' line or these rules won't be processed
COMMIT

########################
### START OPENVPN RULES ###
########################

*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

### Before rules - DNAT almost everything to OpenVPN client ###
-A PREROUTING -i ${EXT_IF} -p tcp -m tcp --dport 1:21 -j DNAT --to-destination ${CLIENT_IP}:1-21
-A PREROUTING -i ${EXT_IF} -p tcp -m tcp --dport 23:1099 -j DNAT --to-destination ${CLIENT_IP}:23-1099
-A PREROUTING -i ${EXT_IF} -p tcp -m tcp --dport 1101:65535 -j DNAT --to-destination ${CLIENT_IP}:1101-65535
-A PREROUTING -i ${EXT_IF} -p udp -m udp --dport 1:21 -j DNAT --to-destination ${CLIENT_IP}:1-21
-A PREROUTING -i ${EXT_IF} -p udp -m udp --dport 23:1099 -j DNAT --to-destination ${CLIENT_IP}:23-1099
-A PREROUTING -i ${EXT_IF} -p udp -m udp --dport 1101:65535 -j DNAT --to-destination ${CLIENT_IP}:1101-65535

# MASQUERADE for OpenVPN clients
-A POSTROUTING -s ${VPN_SUBNET} -o ${EXT_IF} -j MASQUERADE

COMMIT

*filter

# Allow traffic from OpenVPN client (tun0) to external interface
-A ufw-before-forward -i tun0 -o ${EXT_IF} -j ACCEPT
-A ufw-before-forward -i ${EXT_IF} -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow forwarded traffic to the specific client IP on the ports we DNAT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p tcp -m tcp --dport 1:21 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p tcp -m tcp --dport 23:1099 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p tcp -m tcp --dport 1101:65535 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p udp -m udp --dport 1:21 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p udp -m udp --dport 23:1099 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -d ${CLIENT_IP}/32 -p udp -m udp --dport 1101:65535 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT

COMMIT

########################
### END OPENVPN RULES ###
########################
EOF

# 5. Apply User Rules via ufw commands
echo -e "\n${YELLOW}[3/5] Applying user rules...${NC}"

# Drop SSH (as in your rules)
ufw deny 22/tcp comment 'Deny SSH'

# Allow common services
ufw allow 80/tcp comment 'HTTP'
ufw allow 80/udp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTPS'
ufw allow 25/tcp comment 'SMTP'
ufw allow 25/udp comment 'SMTP'
ufw allow 587/tcp comment 'Submission'
ufw allow 587/udp comment 'Submission'
ufw allow 465/tcp comment 'SMTPS'
ufw allow 465/udp comment 'SMTPS'
ufw allow 110/tcp comment 'POP3'
ufw allow 110/udp comment 'POP3'
ufw allow 995/tcp comment 'POP3S'
ufw allow 995/udp comment 'POP3S'
ufw allow 993/tcp comment 'IMAPS'
ufw allow 993/udp comment 'IMAPS'

# Broad multiport (as in your original rules)
ufw allow 25:65535/tcp comment 'Broad TCP range'

# Allow OpenVPN port
ufw allow 1100/tcp comment 'OpenVPN'
ufw allow 1100/udp comment 'OpenVPN'

# 6. Enable UFW and reload
echo -e "\n${YELLOW}[4/5] Enabling and reloading UFW...${NC}"
ufw --force enable
ufw reload

# 7. Show summary
echo -e "\n${YELLOW}[5/5] Final status${NC}"
echo -e "Client IP used for DNAT : ${GREEN}${CLIENT_IP}${NC}"
echo -e "External interface      : ${GREEN}${EXT_IF}${NC}"
echo -e "OpenVPN port            : ${GREEN}1100/udp + 1100/tcp${NC}"
echo
ufw status verbose

echo -e "\n${GREEN}=== Firewall rules applied successfully ===${NC}"
echo -e "Before rules written to: ${BEFORE_RULES}"
echo -e "A backup of the previous before.rules was created."
