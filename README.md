# Mailcow Behind Linode VPS + OpenVPN + pfSense

Securely host [Mailcow](https://mailcow.github.io/mailcow-dockerized-docs/) behind a cheap Linode VPS using OpenVPN and pfSense.  
The VPS acts as a public entry point and port-forwarder, while your real mail server stays completely behind pfSense with no public IP.

This repository contains the helper scripts used in the accompanying blog series:

- **Part 1** – Prepare Debian + OpenVPN Server + UFW rules  
- **Part 2** – pfSense OpenVPN client, gateway, NAT and firewall rules

---

## Architecture

```text
Internet
   │
   ▼
┌──────────────────────────────┐
│  Linode VPS (Debian 12)      │
│  • OpenVPN Server (UDP 1100) │
│  • UFW + DNAT rules          │
│  • Forwards almost all       │
│    traffic to VPN client     │
└──────────────┬───────────────┘
               │ OpenVPN tunnel
               ▼
┌──────────────────────────────┐
│  pfSense (OpenVPN Client)    │
│  • Receives all forwarded    │
│    ports via the tunnel      │
│  • Protects Mailcow          │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│  Mailcow (internal network)  │
└──────────────────────────────┘
```

---

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `prepare-debian.sh` | Updates system, installs OpenVPN + Easy-RSA, disables IPv6, enables IP forwarding |
| `setup-openvpn-server.sh` | Creates modern OpenVPN server on **UDP 1100**, generates PKI and a pfSense-compatible client `.ovpn` |
| `setup-ufw-rules.sh` | Resets UFW, reads client IP from `/var/log/openvpn/ipp.txt`, applies DNAT rules for almost all ports to the OpenVPN client |

---

## Requirements

- Fresh **Debian 12** VPS (Linode recommended)
- Root access
- Public IPv4 address
- At least one OpenVPN client connected before running the UFW script

---

## Quick Start

### 1. Prepare the VPS

```bash
curl -O https://raw.githubusercontent.com/tleadley/mailcow-openvpn-pfsense/main/prepare-debian.sh
chmod +x 01-prepare-debian12.sh
sudo ./01-prepare-debian12.sh
```

### 2. Install OpenVPN Server (Port 1100)

```bash
curl -O https://raw.githubusercontent.com/tleadley/mailcow-openvpn-pfsense/main/setup-openvpn-server.sh
chmod +x 02-setup-openvpn-server.sh
sudo ./02-setup-openvpn-server.sh
```

After completion you will find the client configuration at:

```bash
/root/openvpn-clients/pfsense-client.ovpn
```

Download this file — you will import it into pfSense in Part 2.

### 3. Configure UFW + Port Forwarding

> **Important:** Run this script **only after** the pfSense OpenVPN client has connected at least once.

```bash
curl -O https://raw.githubusercontent.com/tleadley/mailcow-openvpn-pfsense/main/setup-ufw-rules.sh
chmod +x 03-setup-ufw-rules.sh
sudo ./03-setup-ufw-rules.sh
```

The script will:

- Reset UFW to defaults
- Detect the OpenVPN client IP from `/var/log/openvpn/ipp.txt`
- Detect the external network interface
- Write advanced `before.rules` with DNAT for ports 1-21, 23-1099 and 1101-65535
- Allow OpenVPN port 1100
- Block direct SSH (port 22) from the internet
- Apply MASQUERADE for the VPN subnet

---

## What the UFW Rules Do

- **Port 1100/UDP + TCP** → Accepted on the VPS (OpenVPN)
- **Port 22** → Dropped on the public interface
- **Almost all other ports** → DNATed to the connected OpenVPN client (pfSense)
- Traffic from the VPN tunnel is masqueraded so return traffic works correctly

---

## Linode Cloud Firewall Recommendation

For defense in depth, only allow the following in the Linode Cloud Firewall:

| Protocol | Port | Action |
|----------|------|--------|
| UDP      | 1100 | Allow  |
| TCP      | 1100 | Allow  |
| Everything else | - | Drop |

---

## Security Notes

- The VPS becomes a pure port-forwarder / jump host
- Mailcow never has a public IP
- IPv6 is disabled on the VPS (recommended for this design)
- Keep the generated `.ovpn` file private — it contains certificates
- Consider adding certificate revocation (CRL) and monitoring later

---

## Related Blog Posts

- [Part 1 – VPS & OpenVPN Setup](#) *(replace with your actual link)*
- [Part 2 – pfSense Configuration](#) *(replace with your actual link)*

---

## License

MIT License – feel free to use, modify and share.

---

## Contributing

Pull requests and improvements are welcome.  
If you find issues or have suggestions for better defaults (ciphers, ports, etc.), please open an issue.

---
