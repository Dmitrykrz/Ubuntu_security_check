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

# UFW check - read the status once, it is needed again for the rules table
ufw_status=$(sudo ufw status 2>/dev/null)
if echo "$ufw_status" | grep -q "Status: active"; then
  echo -e "${GREEN}OK:${NC} UFW running ${GREEN}✓${NC}"
else
 echo -e "${RED}WARNING:${NC} UFW is not running ${RED}✗${NC}"
fi

# fail2ban check
if command -v fail2ban-client >/dev/null 2>&1 && sudo fail2ban-client status >/dev/null 2>&1; then
    f2b_status=$(sudo fail2ban-client status)
    jail_count=$(echo "$f2b_status" | awk -F':' '/Number of jail/ {gsub(/[ \t]/,"",$2); print $2}')

    # Per-jail counters have to be summed - the overall status has no totals.
    # "Total banned" is cumulative since the fail2ban service last started.
    jails=$(echo "$f2b_status" | awk -F':' '/Jail list/ {gsub(/[ \t]/,"",$2); print $2}' | tr ',' ' ')
    banned_now=0
    banned_total=0
    for jail in $jails; do
        jail_status=$(sudo fail2ban-client status "$jail" 2>/dev/null)
        n=$(echo "$jail_status" | awk -F':' '/Currently banned/ {gsub(/[ \t]/,"",$2); print $2}')
        t=$(echo "$jail_status" | awk -F':' '/Total banned/     {gsub(/[ \t]/,"",$2); print $2}')
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [[ "$t" =~ ^[0-9]+$ ]] || t=0
        banned_now=$(( banned_now + n ))
        banned_total=$(( banned_total + t ))
    done

    echo -e "${GREEN}OK:${NC} fail2ban running with ${jail_count} jails - ${banned_now} IPs banned now, ${banned_total} total ${GREEN}✓${NC}"
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

# SSH port check. With socket activation (Ubuntu 22.10+) the port is set by
# ssh.socket and sshd_config is ignored - `sshd -T` still reports 22 there,
# so ask the socket unit first and only fall back to sshd's own config.
ssh_ports=""
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    # Listen=[::]:2222 (Stream) - several entries may share one line
    ssh_ports=$(systemctl show ssh.socket -p Listen --value 2>/dev/null \
                | grep -oE '[^ ]+ \(Stream\)' | sed 's/ (Stream)//' | awk -F: '{print $NF}')
fi
if [[ -z "$ssh_ports" ]]; then
    ssh_ports=$(echo "$sshd_effective" | awk '/^port / {print $2}')
fi
ssh_ports=$(echo "$ssh_ports" | sort -nu | tr '\n' ' ' | sed 's/ *$//')

if [[ -z "$ssh_ports" ]]; then
    echo -e "${RED}WARNING:${NC} Could not determine the SSH port ${RED}✗${NC}"
elif [[ " $ssh_ports " == *" 22 "* ]]; then
    echo -e "${RED}WARNING:${NC} SSH is running on the default port 22 ${RED}✗${NC}"
else
    echo -e "${GREEN}OK:${NC} SSH is running on port ${ssh_ports} ${GREEN}✓${NC}"
fi

echo -e "${ORANGE}=====================================${NC}"
echo -e "${ORANGE}========= User Access Table =========${NC}"
echo -e "${ORANGE}=====================================${NC}"
# Header
printf "%-20s %-15s %-10s\n" "User" "Has Pass" "Keys"
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

    # Count authorized keys (home dir from passwd, no eval).
    # Read with sudo - other users' ~/.ssh is 0700, so a plain test would
    # report "no key" for everyone but the user running the script.
    home_dir=$(getent passwd "$user" | cut -d: -f6)
    key_file="$home_dir/.ssh/authorized_keys"

    # one key per line, skipping blanks and comments
    key_count=$(sudo grep -cvE '^[[:space:]]*(#|$)' "$key_file" 2>/dev/null)
    [[ "$key_count" =~ ^[0-9]+$ ]] || key_count=0

    if [[ "$key_count" -gt 0 ]]; then
        has_keys="$key_count"
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
        # match spans users:(("name" - skip the 9-char prefix, drop the closing quote
        if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART+9, RLENGTH-10) }
        printf "%s %s %s\n", port, $1, proc
    }' | sort -n -u | awk '{printf "\033[31m%s\033[0m %s %s\n", $1, $2, $3}'

if echo "$ufw_status" | grep -q "Status: active"; then
  echo -e "${ORANGE}=======================================${NC}"
  echo -e "${ORANGE}============== ufw rules ==============${NC}"
  echo -e "${ORANGE}=======================================${NC}"
  # Grepping only ALLOW hid the other actions - notably LIMIT, which is how
  # `ufw limit 22/tcp` (the usual SSH rule) shows up. Skip the (v6) duplicates.
  # Lines are "<to> <ACTION> IN <from>", where <to> may be several words
  # ("Anywhere on docker0") and is just "Anywhere" for source-based rules -
  # for those the From column is the only part that carries any meaning.
  printf "%-16s %-7s %s\n" "To" "Action" "From"
  echo "--------------------------------------------"
  echo "$ufw_status" | awk '
      /\(v6\)/ { next }
      # fail2ban writes one REJECT rule per banned IP - dozens of them, all
      # transient. The jail counts above already summarise them.
      /by Fail2Ban/ { next }
      {
          ai = 0
          for (i = 1; i <= NF; i++) if ($i ~ /^(ALLOW|DENY|REJECT|LIMIT)$/) { ai = i; break }
          if (ai == 0) next

          to = ""
          for (i = 1; i < ai; i++) to = to (to == "" ? "" : " ") $i
          if (to !~ / /) sub(/\/(tcp|udp)$/, "", to)

          from = ""
          start = ($(ai+1) ~ /^(IN|OUT)$/) ? ai + 2 : ai + 1
          for (i = start; i <= NF; i++) from = from (from == "" ? "" : " ") $i

          printf "%s|%s|%s\n", to, $ai, from
      }' | awk -F'|' '!seen[$0]++ {
          col = ($2 == "DENY" || $2 == "REJECT") ? "33" : "32"
          printf "\033[0;32m%-16s\033[0m \033[0;%sm%-7s\033[0m %s\n", $1, col, $2, $3
      }'

  f2b_rules=$(echo "$ufw_status" | grep -c 'by Fail2Ban')
  if [[ "$f2b_rules" -gt 0 ]]; then
      echo -e "${ORANGE}(+ ${f2b_rules} transient fail2ban ban rules, hidden)${NC}"
  fi
fi

if command -v docker >/dev/null 2>&1; then
 echo -e "${ORANGE}=======================================${NC}"
 echo -e "${ORANGE}=========== Running dockers ===========${NC}"
 echo -e "${ORANGE}=======================================${NC}"
 # -F'\t' matters: the ports string contains ", " separators, so splitting on
 # plain whitespace truncates multi-port containers (mysql loses 33060/tcp).
 docker_out=$(docker ps --format "{{.Names}}\t{{.Image}}\t{{.Ports}}")
 echo "$docker_out" | awk -F'\t' '{
     # A publish on 0.0.0.0 / [::] is reachable from the internet even when ufw
     # denies the port - Dockers chain is evaluated before ufws INPUT rules.
     exposed = ($3 ~ /(0\.0\.0\.0|\[::\]):[0-9]+->/)
     printf "\033[0;32m%-26s\033[0m \033[0;33m%-24s\033[0m %s%s\033[0m\n", \
            $1, $2, (exposed ? "\033[0;31m" : ""), $3
 }'

 if echo "$docker_out" | grep -qE '(0\.0\.0\.0|\[::\]):[0-9]+->'; then
     echo -e "${RED}WARNING:${NC} ports above in ${RED}red${NC} are published on all interfaces."
     echo -e "         Docker writes its own iptables rules ahead of ufw, so these are"
     echo -e "         reachable from the internet ${RED}even if ufw denies them${NC}."
     echo -e "         Bind to localhost instead (127.0.0.1:8080:80) if fronted by a proxy. ${RED}✗${NC}"
 fi

 if [[ -n "$docker_out" ]]; then
  echo -e "${ORANGE}=======================================${NC}"
  echo -e "${ORANGE}========== Docker resources ===========${NC}"
  echo -e "${ORANGE}=======================================${NC}"
  # Usage comes from docker stats, limits from docker inspect, ports from
  # docker ps. Each line is tagged with its source and all go through one awk
  # (mawk, Ubuntu's default awk, has no ARGIND to tell several files apart).
  # Stats come last, so limits and ports are already known when a row prints.
  host_cpus=$(nproc)
  host_mem=$(free -h | awk '/^Mem:/ {print $2}')
  printf "%-26s %-18s %-30s %s\n" "Container" "CPU" "Memory" "Host ports"
  echo "--------------------------------------------------------------------------------"
  {
   docker inspect --format 'L|{{.Name}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.Memory}}' $(docker ps -q)
   docker ps --format 'P|{{.Names}}|{{.Ports}}'
   docker stats --no-stream --format 'S|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}'
  } 2>/dev/null | awk -F'|' -v ncpu="$host_cpus" '
      # green -> yellow at 50% -> orange at 75% -> red at 90% (256-color codes)
      function shade(p) {
          if (p >= 90)   return 196
          if (p >= 82.5) return 208
          if (p >= 75)   return 214
          if (p >= 62.5) return 220
          if (p >= 50)   return 226
          if (p >= 37.5) return 190
          if (p >= 25)   return 154
          if (p >= 12.5) return 118
          return 46
      }
      function pct(p) { return sprintf("\033[38;5;%sm%4s\033[0m", shade(p), int(p + 0.5) "%") }
      # Host side of each publish: red bare port = all interfaces, green = bound to one IP
      function host_ports(s,   n, a, i, b, out, seen) {
          n = split(s, a, ", ")
          out = ""
          for (i = 1; i <= n; i++) {
              if (a[i] !~ /->/) continue
              b = a[i]; sub(/->.*/, "", b)
              if (b ~ /^(0\.0\.0\.0|\[::\]):/) { sub(/.*:/, "", b); b = "\033[0;31m" b "\033[0m" }
              else b = "\033[0;32m" b "\033[0m"
              if (b in seen) continue
              seen[b] = 1
              out = out (out == "" ? "" : " ") b
          }
          return out == "" ? "-" : out
      }
      $1 == "L" {
          name = $2; sub(/^\//, "", name)
          # --cpus sets NanoCpus; the older --cpu-quota/--cpu-period pair is the same limit
          if ($3 > 0)      cpu_lim[name] = $3 / 1e9
          else if ($4 > 0) cpu_lim[name] = $4 / ($5 > 0 ? $5 : 100000)
          mem_lim[name] = $6
          next
      }
      $1 == "P" { ports[$2] = $3; next }
      $1 == "S" {
          name = $2
          # CPUPerc is relative to ONE core (200% = 2 CPUs busy)
          cpu = $3; gsub(/%/, "", cpu); cpu += 0
          if (cpu_lim[name] > 0) { cpu_p = cpu / cpu_lim[name]; cpu_note = sprintf("of %g CPU", cpu_lim[name]) }
          else                   { cpu_p = cpu / ncpu;          cpu_note = "no limit" }
          # MemPerc is already used/limit, or used/host RAM when there is no limit
          mem = $5; gsub(/%/, "", mem); mem += 0
          split($4, mu, " / ")
          mem_note = (mem_lim[name] > 0) ? mu[1] " / " mu[2] : mu[1] " no limit"
          printf "\033[0;32m%-26s\033[0m %s %-13s %s %-25s %s\n", \
                 name, pct(cpu_p), cpu_note, pct(mem), mem_note, host_ports(ports[name])
      }'
  echo -e "${ORANGE}(no limit = share of the whole host: ${host_cpus} CPUs, ${host_mem} RAM)${NC}"
 fi
fi

# Turns "host<TAB>path<TAB>target" lines into the routing recap
print_routes() {
    sort -u | awk -F'\t' '{
        printf "\033[0;32m%-40s\033[0m → \033[0;33m%s\033[0m\n", $1 ($2 == "/" ? "" : $2), $3
    }'
}

web_found=0
if systemctl is-active --quiet nginx 2>/dev/null; then
 web_found=1
 echo -e "${ORANGE}=======================================${NC}"
 echo -e "${ORANGE}============ Hosts (nginx) ============${NC}"
 echo -e "${ORANGE}=======================================${NC}"
 # Flatten the config into one statement per line - each ends in "{", "}" or
 # ";" - so the block structure can be tracked whatever the formatting.
 # Only locations directly inside a server block are looked at. Servers with a
 # server-level return (http->https redirects, 444 catch-alls) serve nothing.
 # Tabs are flattened too, so a tab can safely separate the output fields.
 nginx_routes=$(sudo cat /etc/nginx/sites-enabled/* 2>/dev/null \
   | sed 's/#.*//' | tr '\n\t\r' '   ' | sed 's/[{};]/&\n/g' \
   | awk '
       function strip(u) {   # http://127.0.0.1:3000/x -> 127.0.0.1:3000
           sub(/^[a-z]+:\/\//, "", u)
           if (u !~ /^unix:/) sub(/\/.*/, "", u)
           return u
       }
       function close_location() {
           if (path ~ /^@/) return
           if (path == "/") slash = 1
           if (proxy != "")    t = "proxy:" proxy
           else if (regex)     return   # e.g. the \.php$ -> fastcgi handler
           else if (lroot != "") t = lroot
           else if (ret)       return
           else if (path == "/") t = "@root"
           else return                  # same root as the server, nothing new
           lp[++nloc] = regex ? " ~ " path : path
           lt[nloc] = t
       }
       function close_server(   n, a, i, host, t) {
           if (redirect) return
           n = split(names, a, " ")
           host = (n == 0) ? "(no server_name)" : (a[1] == "_" ? "_ (default)" : a[1])
           if (!slash && sroot != "") { lp[++nloc] = "/"; lt[nloc] = "@root" }
           for (i = 1; i <= nloc; i++) {
               t = lt[i]
               if (t == "@root") { if (sroot == "") continue; t = sroot }
               rows[++nrows] = host "\t" lp[i] "\t" t
           }
       }
       {
           sub(/^ +/, ""); sub(/ +$/, "")
           if ($0 == "") next
           end = substr($0, length($0))
           if (end == "{") {
               sub(/ *\{$/, "")
               kind[++depth] = $1
               if ($1 == "server") { names = ""; sroot = ""; redirect = 0; slash = 0; nloc = 0 }
               else if ($1 == "location" && kind[depth-1] == "server") {
                   regex = ($2 ~ /^~/)
                   path = ($2 ~ /^(=|\^~|~|~\*)$/) ? $3 : $2
                   if (regex && path == $2) sub(/^~\*?/, "", path)   # "~\.php$" without a space
                   proxy = ""; lroot = ""; ret = 0
               }
               else if ($1 == "upstream") up = $2
               next
           }
           if (end == "}") {
               if (kind[depth] == "location" && kind[depth-1] == "server") close_location()
               else if (kind[depth] == "server") close_server()
               depth--
               next
           }
           sub(/ *;$/, "")
           if (kind[depth] == "upstream" && $1 == "server") {
               if (up in upstream) upcount[up]++
               else upstream[up] = $2
           }
           else if (kind[depth] == "server") {
               if ($1 == "server_name") for (i = 2; i <= NF; i++) names = names " " $i
               else if ($1 == "root") sroot = $2
               else if ($1 == "return") redirect = 1
           }
           else if (kind[depth] == "location" && kind[depth-1] == "server") {
               if ($1 == "proxy_pass") proxy = $2
               else if ($1 == "root" || $1 == "alias") lroot = $2
               else if ($1 == "return") ret = 1
           }
       }
       END {
           # upstream blocks may come after the servers that use them
           for (i = 1; i <= nrows; i++) {
               split(rows[i], r, "\t")
               t = r[3]
               if (t ~ /^proxy:/) {
                   t = strip(substr(t, 7))
                   if (t in upstream) t = upstream[t] ((t in upcount) ? " +" upcount[t] : "")
               }
               print r[1] "\t" r[2] "\t" t
           }
       }')
 if [[ -n "$nginx_routes" ]]; then
     echo "$nginx_routes" | print_routes
 else
     echo "No sites found in /etc/nginx/sites-enabled"
 fi
fi

if systemctl is-active --quiet apache2 2>/dev/null; then
 web_found=1
 echo -e "${ORANGE}=======================================${NC}"
 echo -e "${ORANGE}=========== Hosts (apache2) ===========${NC}"
 echo -e "${ORANGE}=======================================${NC}"
 # One block per <VirtualHost>. A vhost that redirects (the certbot :80 one)
 # has its DocumentRoot skipped - the :443 twin already reports it.
 apache_routes=$(sudo cat /etc/apache2/sites-enabled/* 2>/dev/null \
   | sed 's/#.*//' | tr -d '\r' \
   | awk '
       function strip(u) {
           gsub(/"/, "", u)
           sub(/^[a-z]+:\/\//, "", u)
           if (u !~ /^unix:/) sub(/\/.*/, "", u)
           return u
       }
       function unquote(s) { gsub(/"/, "", s); if (s != "/") sub(/\/$/, "", s); return s }
       # "^", "^/(.*)$", "(.*)" and the like match every URL of the site
       function whole_site(re) { return re ~ /^\^?\/?\??(\(\.\*\))?\$?$/ }
       { d = tolower($1) }
       d ~ /^<virtualhost/ { inv = 1; host = ""; droot = ""; redirect = 0; slash = 0; n = 0; lpath = ""; next }
       # Alias / ProxyPass outside any <VirtualHost> (e.g. nextcloud.conf) apply to every vhost
       !inv {
           if (d == "alias") print "* (all vhosts)\t" unquote($2) "\t" unquote($3)
           else if (d == "proxypass" && $3 != "!") print "* (all vhosts)\t" $2 "\t" strip($3)
           next
       }
       d == "</virtualhost>" {
           inv = 0
           if (host == "") host = "(no ServerName)"
           if (!slash && droot != "" && !redirect) { p[++n] = "/"; t[n] = droot }
           for (i = 1; i <= n; i++) print host "\t" p[i] "\t" t[i]
           next
       }
       d ~ /^<location/  { lpath = $2; sub(/>$/, "", lpath); gsub(/"/, "", lpath); next }
       d == "</location>" { lpath = ""; next }
       d == "servername"   { host = $2; next }
       d == "documentroot" { droot = $2; gsub(/"/, "", droot); next }
       # Only a redirect of the whole site hides the DocumentRoot - not partial
       # ones like Redirect 301 /.well-known/caldav ... (status is optional, first)
       d == "redirect" || d == "redirectmatch" {
           rp = ($2 ~ /^([0-9]+|permanent|temp|seeother|gone)$/) ? $3 : $2
           if (d == "redirect" ? rp == "/" : whole_site(rp)) redirect = 1
           next
       }
       d == "rewriterule" && tolower($NF) ~ /(\[|,)r(=[^],]*)?(,|\])/ { if (whole_site($2)) redirect = 1; next }
       d == "proxypass" {
           # inside <Location /x> the path is implied: ProxyPass http://...
           if (lpath != "") { path = lpath; url = $2 } else { path = $2; url = $3 }
           if (url == "!") next
           if (path == "/") slash = 1
           p[++n] = path; t[n] = strip(url)
           next
       }
       d == "alias" { p[++n] = unquote($2); t[n] = unquote($3); next }
   ')
 if [[ -n "$apache_routes" ]]; then
     echo "$apache_routes" | print_routes
 else
     echo "No sites found in /etc/apache2/sites-enabled"
 fi
fi

if [[ "$web_found" -eq 0 ]]; then
 echo -e "${ORANGE}=======================================${NC}"
 echo -e "${ORANGE}================ Hosts ================${NC}"
 echo -e "${ORANGE}=======================================${NC}"
 echo "Neither nginx nor apache2 is active"
fi

echo ""
echo ""
