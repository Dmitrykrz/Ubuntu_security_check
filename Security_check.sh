ORANGE='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'  # Reset color


if ! command -v netstat &> /dev/null; then
  echo "Installing netstat..."
  echo "Please wait a little, this will run only once"
  sudo apt update -qq && sudo apt install net-tools -qq -y
fi

echo ""
echo ""
echo -e "${ORANGE}=====================================${NC}"
echo -e "${ORANGE}==== Basic security check script ====${NC}"
echo -e "${ORANGE}=====================================${NC}"

echo -e "\e[31m$(grep PRETTY /etc/os-release | cut -d= -f2 | tr -d '"')\e[0m"
echo -e "IP  \e[31m$(hostname -I | awk '{print $1}')\e[0m"



# Root login check
root_login=$(grep -E '^PermitRootLogin (yes|no|Yes|No|YES|NO)' /etc/ssh/sshd_config | awk '{print $2}')
if [[ "$root_login" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${RED}WARNING:${NC} Root login is enabled!${NC} ${RED}✗${NC}"
else
    echo -e "${GREEN}OK:${NC} Root login is disabled ${GREEN}✓${NC}"
fi

# Password authentication check
pass_login=$(grep -E '^PasswordAuthentication (yes|no|Yes|No|YES|NO)' /etc/ssh/sshd_config | awk '{print $2}')
if [[ "$pass_login" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo -e "${RED}WARNING:${NC} Password authentication is enabled! ${RED}✗${NC}"
else
    echo -e "${GREEN}OK:${NC} Password authentication is disabled ${GREEN}✓${NC}"
fi

DIR="/etc/ssh/sshd_config.d"

if [ -n "$(find "$DIR" -type f 2>/dev/null)" ]; then
    echo -e "${RED}WARNING:${NC} Additional SSH config found  ${RED}✗${NC}"
    echo -e "Verify folder /etc/ssh/sshd_config.d/"

fi



if sudo ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}OK:${NC} UFW running ${GREEN}✓${NC}"

else
 echo -e "${RED}WARNING:${NC} UFW is not running ${RED}✗${NC}"

fi

count=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)

if [ "$count" -eq 0 ]; then
    echo -e "${GREEN}OK:${NC} All packages are up to date ${GREEN}✓${NC}"
else
    echo -e "${RED}WARNING:${NC} $count packages can be upgraded ${RED}✗${NC}"

fi





# Port check
ssh_port_line=$(grep -E '^Port [0-9]+|^#Port [0-9]+' /etc/ssh/sshd_config | grep -v '^#' | awk '{print $2}')
if [[ -z "$ssh_port_line" ]]; then
    echo -e "${RED}WARNING:${NC} SSH is running on the default port 22 ${RED}✗${NC}"
    ssh_port="22"
elif [[ "$ssh_port_line" == "22" ]]; then
    echo -e "${RED}WARNING:${NC} SSH is running on the default port 22 ${RED}✗${NC}"
else
    ssh_port="$ssh_port_line"
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

    # Check for authorized_keys
    home_dir=$(eval echo "~$user")
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
grep -E '^sudo|^admin' /etc/group | awk -F':' '{print "\033[35m" $4 "\033[0m"}' | tr ',' '\n'
echo -e "${ORANGE}=======================================${NC}"
echo -e "${ORANGE}======== List of opened ports =========${NC}"
echo -e "${ORANGE}=======================================${NC}"
#netstat -tulnp | grep '^tcp' | awk '{print $4, $7}' | cut -d':' -f2- | awk '{split($2, a, "/"); printf "\033[31m%s\033[0m %s\n", $1, a[2]}'
netstat -tulpn |grep tcp | awk '{print  $4, $7}'| grep '0.0.0.0'| awk '/0.0.0.0|:::/ {sub(/^.*:/, "", $1); print "\033[31m" $1 "\033[0m", $2}'


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
