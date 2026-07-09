#!/bin/bash
ORANGE='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'  # Reset color

echo ""
echo ""
echo -e "${ORANGE}=====================================${NC}"
echo -e "${ORANGE}==== Basic security check script ====${NC}"
echo -e "${ORANGE}=====================================${NC}"

echo -e "\e[31m$(grep PRETTY /etc/os-release | cut -d= -f2 | tr -d '"')\e[0m"
echo -e "IP  \e[31m$(hostname -I | awk '{print $1}')\e[0m"

# Effective SSH settings (sshd -T resolves sshd_config.d/ drop-ins and Include)
sshd_effective=$(sudo sshd -T 2>/dev/null)

# Root login check
root_login=$(echo "$sshd_effective" | awk '/^permitrootlogin/ {print $2}')
if [[ "$root_login" == "yes" ]]; then
    echo -e "${RED}WARNING:${NC} Root login is enabled! ${RED}✗${NC}"
elif [[ "$root_login" == "prohibit-password" || "$root_login" == "without-password" ]]; then
    echo -e "${GREEN}OK:${NC} Root login is key-only (prohibit-password) ${GREEN}✓${NC}"
else
    echo -e "${GREEN}OK:${NC} Root login is disabled ${GREEN}✓${NC}"
fi

# Password authentication check
pass_login=$(echo "$sshd_effective" | awk '/^passwordauthentication/ {print $2}')
if [[ "$pass_login" == "yes" ]]; then
    echo -e "${RED}WARNING:${NC} Password authentication is enabled! ${RED}✗${NC}"
else
    echo -e "${GREEN}OK:${NC} Password authentication is disabled ${GREEN}✓${NC}"
fi

# UFW check
if sudo ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}OK:${NC} UFW running ${GREEN}✓${NC}"
else
 echo -e "${RED}WARNING:${NC} UFW is not running ${RED}✗${NC}"
fi

# fail2ban check
if command -v fail2ban-client >/dev/null 2>&1 && sudo fail2ban-client status >/dev/null 2>&1; then
    jail_count=$(sudo fail2ban-client status | awk -F':' '/Number of jail/ {gsub(/[ \t]/,"",$2); print $2}')
    echo -e "${GREEN}OK:${NC} fail2ban running with ${jail_count} jails ${GREEN}✓${NC}"
else
    echo -e "${RED}WARNING:${NC} fail2ban is not running ${RED}✗${NC}"
fi

# Pending upgrades check
count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
if [ "$count" -eq 0 ]; then
    echo -e "${GREEN}OK:${NC} All packages are up to date ${GREEN}✓${NC}"
else
    echo -e "${RED}WARNING:${NC} $count packages can be upgraded ${RED}✗${NC}"
fi

# Unattended-upgrades configured check
if grep -qs '^APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
    echo -e "${GREEN}OK:${NC} Unattended-upgrades is configured ${GREEN}✓${NC}"
else
    echo -e "${RED}WARNING:${NC} Unattended-upgrades is NOT configured (auto-updates off) ${RED}✗${NC}"
fi

# Reboot required check
if [ -f /var/run/reboot-required ]; then
    echo -e "${RED}WARNING:${NC} Reboot required ($(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')) ${RED}✗${NC}"
else
    echo -e "${GREEN}OK:${NC} No reboot required ${GREEN}✓${NC}"
fi

# SSH port check (effective config)
ssh_port=$(echo "$sshd_effective" | awk '/^port / {print $2; exit}')
if [[ -z "$ssh_port" || "$ssh_port" == "22" ]]; then
    echo -e "${RED}WARNING:${NC} SSH is running on the default port 22 ${RED}✗${NC}"
    ssh_port="22"
else
    echo -e "${GREEN}OK:${NC} SSH is running on port ${ssh_port} ${GREEN}✓${NC}"
fi

echo -e "${ORANGE}=====================================${NC}"
echo -e "${ORANGE}========= User Access Table =========${NC}"
echo -e "${ORANGE}=====================================${NC}"
# Header
printf "%-20s %-15s %-10s\n" "User" "Has Pass" "Has Key"
echo "--------------------------------------------"
# Users with login shells
users=$(getent passwd | awk -F: '$7 ~ /(bash|sh|zsh)/ { print $1 }')

for user in $users; do
    # Check if user has password (from shadow)
    shadow_line=$(sudo getent shadow "$user")
    pass_field=$(echo "$shadow_line" | cut -d: -f2)
    if [[ "$pass_field" == "!"* || "$pass_field" == "*" || -z "$pass_field" ]]; then
        has_pass="✗"
    else
        has_pass="✓"
    fi

    # Check for authorized_keys (home dir from passwd, no eval)
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    key_file="$home_dir/.ssh/authorized_keys"

    if [[ -f "$key_file" && -s "$key_file" ]]; then
        has_keys="✓"
    else
        has_keys="✗"
    fi

    # Print result
    printf "%-20s %-15s %-10s\n" "$user" "$has_pass" "$has_keys"

done
echo -e "${ORANGE}========================================${NC}"
echo -e "${ORANGE}== List of users with root priveleges ==${NC}"
echo -e "${ORANGE}========================================${NC}"
awk -F: '$3 == 0 {printf "\033[0;35m%s\033[0m\n", $1}' /etc/passwd
grep -E '^sudo|^admin' /etc/group | awk -F':' '$4 != "" {print "\033[35m" $4 "\033[0m"}' | tr ',' '\n'
echo -e "${ORANGE}=======================================${NC}"
echo -e "${ORANGE}==== Internet-facing listeners ========${NC}"
echo -e "${ORANGE}=======================================${NC}"
# ss instead of netstat (no net-tools needed); catches BOTH 0.0.0.0 and IPv6 [::]
# wildcard listeners — the old grep '0.0.0.0' missed dual-stack services like Apache.
# Sort/dedupe on PLAIN text first, colorize last (ANSI codes break numeric sort).
sudo ss -tulnp | awk '
    $5 ~ /^(0\.0\.0\.0|\[::\]|\*):[0-9]+$/ {
        split($5, a, ":"); port = a[length(a)]
        proc = "-"
        if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART+9, RLENGTH-9) }
        printf "%s %s %s\n", port, $1, proc
    }' | sort -n -u | awk '{printf "\033[31m%s\033[0m %s %s\n", $1, $2, $3}'

if sudo ufw status | grep -q "Status: active"; then
  echo -e "${ORANGE}=======================================${NC}"
  echo -e "${ORANGE}======== Allowed ports in ufw =========${NC}"
  echo -e "${ORANGE}=======================================${NC}"
  sudo ufw status | grep 'ALLOW' | grep -v 'v6' | awk '{print $1}' | sed 's/\/tcp//' | awk '{print "\033[32m" $0 "\033[0m"}'
fi

if command -v docker >/dev/null 2>&1; then
 echo -e "${ORANGE}=======================================${NC}"
 echo -e "${ORANGE}=========== Running dockers ===========${NC}"
 echo -e "${ORANGE}=======================================${NC}"
 docker ps --format "{{.Names}}\t{{.Image}}\t{{.Ports}}" | awk '{print "\033[32m" $1 "\033[0m", "\033[33m" $2 "\033[0m", $3}'
fi

echo ""
echo ""
