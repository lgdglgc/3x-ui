#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}
function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}
function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

get_public_ip() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done
    echo "$server_ip"
}

resolve_domain() {
    local dom="$1"
    local resolved_ip=""
    if command -v getent >/dev/null 2>&1; then
        resolved_ip=$(getent ahosts "$dom" 2>/dev/null | head -n 1 | awk '{print $1}')
    fi
    if [[ -z "$resolved_ip" ]] && command -v dig >/dev/null 2>&1; then
        resolved_ip=$(dig +short "$dom" 2>/dev/null | tail -n1)
    fi
    if [[ -z "$resolved_ip" ]] && command -v nslookup >/dev/null 2>&1; then
        resolved_ip=$(nslookup "$dom" 2>/dev/null | tail -n2 | grep Address | awk '{print $2}')
    fi
    if [[ -z "$resolved_ip" ]] && command -v host >/dev/null 2>&1; then
        resolved_ip=$(host "$dom" 2>/dev/null | awk '/has address/ {print $4}' | head -n1)
    fi
    if [[ -z "$resolved_ip" ]] && command -v python3 >/dev/null 2>&1; then
        resolved_ip=$(python3 -c "import socket; print(socket.gethostbyname('$dom'))" 2>/dev/null)
    elif [[ -z "$resolved_ip" ]] && command -v python >/dev/null 2>&1; then
        resolved_ip=$(python -c "import socket; print(socket.gethostbyname('$dom'))" 2>/dev/null)
    fi
    if [[ -z "$resolved_ip" ]] && command -v ping >/dev/null 2>&1; then
        resolved_ip=$(ping -c 1 -W 2 "$dom" 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    fi
    echo "$resolved_ip"
}

manage_firewall_port() {
    local action="$1"
    local port="$2"
    if [[ "$action" == "open" ]]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            ufw allow ${port}/tcp >/dev/null 2>&1
            echo "ufw"
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --add-port=${port}/tcp >/dev/null 2>&1
            echo "firewalld"
        elif command -v iptables >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1
            echo "iptables"
        fi
    elif [[ "$action" == "close" ]]; then
        local fw_type="$3"
        if [[ "$fw_type" == "ufw" ]]; then
            ufw delete allow ${port}/tcp >/dev/null 2>&1
        elif [[ "$fw_type" == "firewalld" ]]; then
            firewall-cmd --remove-port=${port}/tcp >/dev/null 2>&1
        elif [[ "$fw_type" == "iptables" ]]; then
            iptables -D INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1
        fi
    fi
}

stop_occupying_services() {
    local port="$1"
    local stopped_services=""
    if is_port_in_use "${port}"; then
        for svc in nginx apache2 caddy; do
            if systemctl is-active --quiet ${svc} 2>/dev/null; then
                LOGI "Stopping ${svc} temporarily to free port ${port}..."
                systemctl stop ${svc} >/dev/null 2>&1
                stopped_services="${stopped_services} ${svc}"
            fi
        done
    fi
    echo "${stopped_services}"
}

start_occupying_services() {
    local svcs="$1"
    for svc in ${svcs}; do
        LOGI "Restarting ${svc}..."
        systemctl start ${svc} >/dev/null 2>&1
    done
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y cronie curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q cronie curl tar tzdata socat ca-certificates openssl
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm cronie curl tar tzdata socat ca-certificates openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y cron curl tar timezone socat ca-certificates openssl
            ;;
        alpine)
            apk update && apk add dcron curl tar tzdata socat ca-certificates openssl
            ;;
        *)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
            ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

install_postgres_local() {
    local pg_user pg_pass
    pg_pass=$(gen_random_string 24)
    local pg_db="xui"
    local pg_host="127.0.0.1"
    local pg_port="5432"

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}Unsupported distro for automatic PostgreSQL install: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    # Wait briefly for the server to accept connections.
    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    local existing_owner=""
    existing_owner=$(sudo -u postgres psql -tAc \
        "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | tr -d '[:space:]')
    if [[ -n "${existing_owner}" && "${existing_owner}" != "postgres" ]]; then
        pg_user="${existing_owner}"
    else
        pg_user=$(gen_random_string 8)
    fi

    # Idempotent role/db creation. Identifiers are double-quoted because a
    # random username may start with a digit, which Postgres rejects unquoted.
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    if [[ -n "${PG_CRED_FILE:-}" ]]; then
        local prev_umask
        prev_umask=$(umask)
        umask 077
        if ! cat > "${PG_CRED_FILE}" << EOF; then
PG_USER=${pg_user}
PG_PASS=${pg_pass}
PG_HOST=${pg_host}
PG_PORT=${pg_port}
PG_DB=${pg_db}
EOF
            umask "${prev_umask}"
            echo -e "${red}Failed to write PostgreSQL credentials to ${PG_CRED_FILE}${plain}" >&2
            return 1
        fi
        umask "${prev_umask}"
    fi

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

ensure_pg_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}Installing PostgreSQL client tools (pg_dump/pg_restore) for in-panel backup...${plain}" >&2
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql-client >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql >&2 || return 1
            else
                dnf install -y -q postgresql >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql >&2 || return 1
            ;;
        alpine)
            apk add --no-cache postgresql-client >&2 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1
}

install_acme() {
    echo -e "${green}Installing acme.sh for SSL certificate management...${plain}"
    if command -v ~/.acme.sh/acme.sh &> /dev/null || [ -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${green}acme.sh is already installed.${plain}"
        return 0
    fi
    cd ~ || return 1
    curl -sL https://get.acme.sh | sh > /dev/null 2>&1
    if [ $? -ne 0 ] || ! [ -f "$HOME/.acme.sh/acme.sh" ]; then
        echo -e "${yellow}Official get.acme.sh download failed. Trying GitHub mirror...${plain}"
        curl -sL https://mirror.ghproxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh > /dev/null 2>&1
    fi
    if [ -f "$HOME/.acme.sh/acme.sh" ] || command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo -e "${green}acme.sh installed successfully${plain}"
        return 0
    else
        echo -e "${red}Failed to install acme.sh${plain}"
        return 1
    fi
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}Setting up SSL certificate...${plain}"

    # Check if acme.sh is installed
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}Failed to install acme.sh, skipping SSL setup${plain}"
            return 1
        fi
    fi

    # Create certificate directory
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # Issue certificate
    echo -e "${green}Issuing SSL certificate for ${domain}...${plain}"
    echo -e "${yellow}Note: Port 80 must be open and accessible from the internet${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to issue certificate for ${domain}${plain}"
        echo -e "${yellow}Please ensure port 80 is open and try again later with: x-ui${plain}"
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # Install certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to install certificate${plain}"
        return 1
    fi

    # Enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    # Secure permissions: private key readable only by owner
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Set certificate for panel
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL certificate installed and configured successfully!${plain}"
        return 0
    else
        echo -e "${yellow}Certificate files not found${plain}"
        return 1
    fi
}

# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2" # optional

    echo -e "${green}正在配置 Let's Encrypt 公网 IP 证书 (短效证书)...${plain}"
    echo -e "${yellow}注意: 公网 IP 证书有效期约为 6 天，到期会自动续签。${plain}"
    echo -e "${yellow}默认监听端口为 80。如果选择其他端口，请确保外网 80 端口已被转发至该端口。${plain}"

    # Check for acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}安装 acme.sh 失败${plain}"
            return 1
        fi
    fi

    # Validate IP address
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}必须提供 IPv4 地址${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}无效的 IPv4 地址: $ipv4${plain}"
        return 1
    fi

    # Create certificate directory
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # Build domain arguments
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}包含 IPv6 地址: ${ipv6}${plain}"
    fi

    # Set reload command for auto-renewal (add || true so it doesn't fail during first install)
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Choose port for HTTP-01 listener (default 80, prompt override)
    local WebPort=""
    read -rp "请输入用于 ACME HTTP-01 验证的端口 (默认 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}输入端口无效，回退使用端口 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}使用端口 ${WebPort} 进行独立式验证 (standalone)。${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}提示: Let's Encrypt 仍会尝试连接 80 端口；请确保外网 80 端口已转发至 ${WebPort}。${plain}"
    fi

    # Ensure chosen port is available
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}端口 ${WebPort} 已被占用。${plain}"

            local alt_port=""
            read -rp "请输入另一个端口用于 acme.sh 监听 (留空则终止): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}端口 ${WebPort} 繁忙，无法继续。${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}输入的端口无效。${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}端口 ${WebPort} 空闲，可用于独立式验证。${plain}"
            break
        fi
    done

    # Issue certificate with shortlived profile
    echo -e "${green}正在为 IP ${ipv4} 申请公网证书...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1

    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}申请 IP 证书失败${plain}"
        echo -e "${yellow}请确保端口 ${WebPort} 能够从外网访问 (或已从外网 80 端口进行转发)${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书申请成功，正在安装...${plain}"

    # Install certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}安装后未找到证书文件${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书文件安装成功${plain}"

    # Enable auto-upgrade for acme.sh (ensures cron job runs)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    # Secure permissions: private key readable only by owner
    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    # Configure panel to use the certificate
    echo -e "${green}正在配置面板的证书路径...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"

    if [ $? -ne 0 ]; then
        echo -e "${yellow}警告: 无法自动设置证书路径${plain}"
        echo -e "${yellow}您可能需要手动在面板设置中指定它们。证书文件位于:${plain}"
        echo -e "  证书路径: ${certDir}/fullchain.pem"
        echo -e "  私钥路径: ${certDir}/privkey.pem"
    else
        echo -e "${green}证书路径配置成功${plain}"
    fi

    echo -e "${green}IP 证书已成功安装和配置！${plain}"
    echo -e "${green}证书有效期约为 6 天，将通过 acme.sh 定时任务自动续签。${plain}"
    echo -e "${yellow}acme.sh 会在到期前自动续签并重新载入面板。${plain}"
    return 0
}

# Comprehensive manual SSL certificate issuance via acme.sh
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未找到 acme.sh。正在安装..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme.sh 失败，请检查日志。"
            return 1
        fi
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "请输入您的域名: " domain
        domain="${domain// /}" # Trim whitespace

        if [[ -z "$domain" ]]; then
            LOGE "域名不能为空，请重新输入。"
            continue
        fi

        if ! is_domain "$domain"; then
            LOGE "无效的域名格式: ${domain}。请输入有效的域名。"
            continue
        fi

        break
    done
    LOGD "您的域名为: ${domain}，正在检查 DNS 解析记录..."
    SSL_ISSUED_DOMAIN="${domain}"

    # DNS check
    local public_ip=$(get_public_ip)
    local resolved_ip=$(resolve_domain "${domain}")
    if [[ -n "${public_ip}" && -n "${resolved_ip}" ]]; then
        if [[ "${public_ip}" != "${resolved_ip}" ]]; then
            LOGW "警告: 您的域名解析到的 IP 是 ${resolved_ip}，但您当前服务器的公网 IP 是 ${public_ip}。"
            LOGW "请确保您的域名 DNS A 记录正确指向您服务器的公网 IP。"
            confirm "您确定仍要继续申请证书吗？" "n"
            if [[ $? -ne 0 ]]; then
                return 1
            fi
        else
            LOGI "域名 DNS 解析验证通过 (已解析至 ${resolved_ip})。"
        fi
    elif [[ -z "${resolved_ip}" ]]; then
        LOGW "警告: 无法将域名 ${domain} 解析为任何 IP 地址。"
        LOGW "请检查域名的 DNS 设置是否正确，以及是否已经全球生效。"
        confirm "您确定仍要继续申请证书吗？" "n"
        if [[ $? -ne 0 ]]; then
            return 1
        fi
    fi

    # detect existing certificate and reuse it if present
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        LOGI "已找到域名 ${domain} 的现有证书，将直接重用。"
        [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
    else
        LOGI "您的域名已准备就绪，开始申请证书..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -rp "请选择用于验证的端口 (默认 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "输入端口 ${WebPort} 无效，将使用默认的 80 端口。"
        WebPort=80
    fi
    LOGI "将使用端口 ${WebPort} 申请证书。请确保此端口未被占用且已向外网开放。"

    # Environment states for restore on exit/failure
    local stopped_svcs=""
    local fw_type=""
    restore_env() {
        if [[ -n "$stopped_svcs" ]]; then
            start_occupying_services "$stopped_svcs"
        fi
        if [[ -n "$fw_type" ]]; then
            manage_firewall_port "close" "$WebPort" "$fw_type"
        fi
    }
    # Register trap to ensure cleanup on script interruption or exit
    trap restore_env INT TERM EXIT

    # Stop occupying services
    stopped_svcs=$(stop_occupying_services "${WebPort}")

    # Temporarily open firewall port
    fw_type=$(manage_firewall_port "open" "${WebPort}")

    # Stop panel temporarily
    LOGI "正在临时停止面板服务..."
    systemctl stop x-ui 2> /dev/null || rc-service x-ui stop 2> /dev/null

    local issue_status=1

    if [[ ${cert_exists} -eq 0 ]]; then
        # Ask for email to register account
        local email="admin@${domain}"
        read -rp "请输入用于注册 ACME 账户的邮箱 (默认: admin@${domain}): " user_email
        email="${user_email:-$email}"

        # Check if the server has IPv6 interface
        local use_ipv6=""
        if ip -6 addr show | grep -q "inet6" | grep -qv "lo"; then
            use_ipv6="--listen-v6"
            LOGI "检测到本地支持 IPv6，已开启 IPv6 独立监听器..."
        fi

        # Issue the certificate - try Let's Encrypt first
        LOGI "正在使用邮箱 ${email} 注册 Let's Encrypt ACME 账户..."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --register-account -m "${email}" --server letsencrypt
        
        LOGI "正在通过 Let's Encrypt 申请证书..."
        ~/.acme.sh/acme.sh --issue -d ${domain} ${use_ipv6} --standalone --httpport ${WebPort} --force
        
        if [ $? -eq 0 ]; then
            LOGI "通过 Let's Encrypt 申请证书成功！"
            issue_status=0
        else
            LOGE "通过 Let's Encrypt 申请证书失败。"
            confirm "是否尝试改用 ZeroSSL 申请证书？" "y"
            if [ $? -eq 0 ]; then
                LOGI "正在使用邮箱 ${email} 注册 ZeroSSL ACME 账户..."
                ~/.acme.sh/acme.sh --set-default-ca --server zerossl --force
                ~/.acme.sh/acme.sh --register-account -m "${email}" --server zerossl
                
                LOGI "正在通过 ZeroSSL 申请证书..."
                ~/.acme.sh/acme.sh --issue -d ${domain} ${use_ipv6} --standalone --httpport ${WebPort} --force
                if [ $? -eq 0 ]; then
                    LOGI "通过 ZeroSSL 申请证书成功！"
                    issue_status=0
                else
                    LOGE "通过 ZeroSSL 申请证书也失败了。"
                fi
            fi
        fi

        if [[ ${issue_status} -ne 0 ]]; then
            LOGE "所有证书申请尝试均已失败。请检查上方日志。"
            rm -rf ~/.acme.sh/${domain}
            restore_env
            systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
            trap - INT TERM EXIT
            return 1
        else
            LOGI "申请证书成功，正在安装证书..."
        fi
    else
        LOGI "正直接使用现有证书进行安装..."
        issue_status=0
    fi

    # Restore port/firewall environment before panel restart to avoid port conflicts
    restore_env
    trap - INT TERM EXIT

    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"

    LOGI "ACME 默认的重载命令 (--reloadcmd) 为: ${yellow}systemctl restart x-ui || rc-service x-ui restart"
    LOGI "每次证书申请或自动续签成功后，都会执行该重载命令。"
    read -rp "您需要修改 ACME 的重载命令吗？(y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; systemctl restart x-ui (适用于 Nginx 反代)"
        echo -e "${green}\t2.${plain} 自定义输入命令"
        echo -e "${green}\t0.${plain} 保持默认重载命令"
        read -rp "请选择一个选项: " choice
        case "$choice" in
            1)
                LOGI "重载命令设置为: systemctl reload nginx ; systemctl restart x-ui"
                reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
                ;;
            2)
                LOGD "建议将重启 x-ui 的命令放在最后"
                read -rp "请输入您自定义的重载命令: " reloadCmd
                LOGI "您设定的重载命令是: ${reloadCmd}"
                ;;
            *)
                LOGI "保持使用默认的重载命令"
                ;;
        esac
    fi

    # install the certificate
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        LOGI "安装证书成功，正在启用自动续签..."
    else
        LOGE "安装证书失败，即将退出。"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "启用自动续签失败，当前证书详情如下:"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    else
        LOGI "启用自动续签成功，证书详情如下:"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem 2> /dev/null
        chmod 644 $certPath/fullchain.pem 2> /dev/null
    fi

    # start panel
    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    # Prompt user to set panel paths after successful certificate installation
    read -rp "是否将此证书应用于面板配置？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "已成功为面板配置证书路径"
            LOGI "证书文件: $webCertFile"
            LOGI "私钥文件: $webKeyFile"
            echo ""
            echo -e "${green}访问 URL: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            LOGI "正在重启面板以应用 SSL 证书..."
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            LOGE "错误: 未找到域名 $domain 的证书或私钥文件。"
        fi
    else
        LOGI "已跳过面板证书配置。"
    fi

    return 0
}

# Reusable interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP for Access URL usage
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"
    local server_ip="$3"

    local ssl_choice=""
    SSL_SCHEME="https"

    echo -e "${yellow}请选择 SSL 证书配置方式:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt 域名证书 (90天有效期，自动续签)"
    echo -e "${green}2.${plain} Let's Encrypt 公网 IP 证书 (6天有效期，自动续签)"
    echo -e "${green}3.${plain} 自定义 SSL 证书 (提供您已有的证书文件路径)"
    echo -e "${green}4.${plain} 跳过 SSL 配置 (高级模式 — 仅适用于反代或 SSH 隧道模式)"
    echo -e "${blue}注:${plain} 选项 1 和 2 需要公网放行 80 端口。选项 3 需要手动指定证书路径。"
    echo -e "${blue}注:${plain} 选项 4 将使用纯 HTTP 协议，仅当您在前端部署了 Nginx/Caddy 或使用 SSH 隧道时才推荐。"
    read -rp "请选择一个选项 [默认 2]: " ssl_choice
    ssl_choice="${ssl_choice// /}" # Trim whitespace

    # Default to 2 (IP cert) if input is empty or invalid (not 1, 3 or 4)
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
        1)
            # User chose Let's Encrypt domain option
            echo -e "${green}正在使用 Let's Encrypt 申请域名证书...${plain}"
            if ssl_cert_issue; then
                local cert_domain="${SSL_ISSUED_DOMAIN}"
                if [[ -z "${cert_domain}" ]]; then
                    cert_domain=$(~/.acme.sh/acme.sh --list 2> /dev/null | tail -1 | awk '{print $1}')
                fi

                if [[ -n "${cert_domain}" ]]; then
                    SSL_HOST="${cert_domain}"
                    echo -e "${green}✓ 域名 SSL 证书配置成功: ${cert_domain}${plain}"
                else
                    echo -e "${yellow}SSL 证书已成功申请，但提取域名信息失败${plain}"
                    SSL_HOST="${server_ip}"
                fi
            else
                echo -e "${red}域名模式下 SSL 证书申请失败。${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        2)
            # User chose Let's Encrypt IP certificate option
            echo -e "${green}正在使用 Let's Encrypt 申请 IP 地址证书...${plain}"

            # Ask for optional IPv6
            local ipv6_addr=""
            read -rp "是否包含 IPv6 地址？(留空则跳过): " ipv6_addr
            ipv6_addr="${ipv6_addr// /}" # Trim whitespace

            # Stop panel if running (port 80 needed)
            if [[ $release == "alpine" ]]; then
                rc-service x-ui stop > /dev/null 2>&1
            else
                systemctl stop x-ui > /dev/null 2>&1
            fi

            setup_ip_certificate "${server_ip}" "${ipv6_addr}"
            if [ $? -eq 0 ]; then
                SSL_HOST="${server_ip}"
                echo -e "${green}✓ IP 地址 SSL 证书配置成功${plain}"
            else
                echo -e "${red}✗ IP 证书配置失败。请确认 80 端口已向外网开放。${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        3)
            # User chose Custom Paths (User Provided) option
            echo -e "${green}使用自定义已有的证书...${plain}"
            local custom_cert=""
            local custom_key=""
            local custom_domain=""

            # 3.1 Request Domain to compose Panel URL later
            read -rp "请输入该证书所绑定的域名/IP: " custom_domain
            custom_domain="${custom_domain// /}" # Remove spaces

            # 3.2 Loop for Certificate Path
            while true; do
                read -rp "请输入证书文件路径 (包含 .crt 或 fullchain.pem): " custom_cert
                # Strip quotes if present
                custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                    break
                elif [[ ! -f "$custom_cert" ]]; then
                    echo -e "${red}错误: 文件不存在！请重新输入。${plain}"
                elif [[ ! -r "$custom_cert" ]]; then
                    echo -e "${red}错误: 文件存在但不可读 (请检查文件权限)！${plain}"
                else
                    echo -e "${red}错误: 文件为空！${plain}"
                fi
            done

            # 3.3 Loop for Private Key Path
            while true; do
                read -rp "请输入私钥文件路径 (包含 .key 或 privkey.pem): " custom_key
                # Strip quotes if present
                custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                    break
                elif [[ ! -f "$custom_key" ]]; then
                    echo -e "${red}错误: 文件不存在！请重新输入。${plain}"
                elif [[ ! -r "$custom_key" ]]; then
                    echo -e "${red}错误: 文件存在但不可读 (请检查文件权限)！${plain}"
                else
                    echo -e "${red}错误: 文件为空！${plain}"
                fi
            done

            # 3.4 Apply Settings via x-ui binary
            ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" > /dev/null 2>&1

            # Set SSL_HOST for composing Panel URL
            if [[ -n "$custom_domain" ]]; then
                SSL_HOST="$custom_domain"
            else
                SSL_HOST="${server_ip}"
            fi

            echo -e "${green}✓ 自定义证书路径已成功应用。${plain}"
            echo -e "${yellow}注意: 您需要自行负责该证书文件的后续更新。${plain}"

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            ;;
        4)
            echo ""
            echo -e "${red}⚠ 面板将在没有开启 SSL/TLS 的情况下运行。${plain}"
            echo -e "${yellow}登录凭证和 Cookie 将以明文 HTTP 协议传输。${plain}"
            echo -e "${yellow}这仅在以下情况下是安全的:${plain}"
            echo -e "${yellow}  • 有反向代理 (如 Nginx、Caddy、Traefik) 帮您处理 TLS 证书，或${plain}"
            echo -e "${yellow}  • 您仅通过本地 SSH 隧道访问面板${plain}"
            echo ""

            SSL_SCHEME="http"
            SSL_HOST="${server_ip}"

            local bind_local=""
            read -rp "是否仅将面板绑定至 127.0.0.1？(推荐 — 强制通过反代或 SSH 隧道访问) [y/N]: " bind_local
            if [[ "$bind_local" == "y" || "$bind_local" == "Y" ]]; then
                ${xui_folder}/x-ui setting -listenIP "127.0.0.1" > /dev/null 2>&1
                SSL_HOST="127.0.0.1"
                echo -e "${green}✓ 面板已成功绑定至 127.0.0.1，无法从公网直接访问。${plain}"
                echo ""
                echo -e "${green}SSH 端口转发 —— 您可以通过本地运行以下命令访问面板:${plain}"
                echo -e "  标准 SSH 连接命令:"
                echo -e "  ${yellow}ssh -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  如果使用 SSH 密钥连接:"
                echo -e "  ${yellow}ssh -i <秘钥路径> -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  接着在您的本地浏览器中打开:${plain}"
                echo -e "  ${yellow}http://localhost:2222/${web_base_path}${plain}"
                echo ""
                echo -e "${yellow}或者：配置反向代理将流量转发至 127.0.0.1:${panel_port} 并由其处理 TLS 证书。${plain}"
            else
                echo -e "${yellow}面板将通过纯 HTTP 协议监听所有网卡接口。请确保有其他服务在前端处理 TLS。${plain}"
            fi

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            echo -e "${green}✓ 已跳过 SSL 配置。${plain}"
            ;;
        *)
            echo -e "${red}选择无效，已跳过 SSL 配置。${plain}"
            SSL_HOST="${server_ip}"
            ;;
    esac
}

config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}无法从任何接口服务自动检测服务器的公网 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入您服务器的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}无效的 IPv4 地址，请重新输入。${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 18)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            local db_label="SQLite (/etc/x-ui/x-ui.db)"
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     选择数据库类型                        ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "  1) SQLite     (默认 — 推荐客户端小于 500 个的用户使用)"
            echo -e "  2) PostgreSQL (推荐高并发客户端 / 多节点部署的用户使用)"
            read -rp "请选择 [默认 1]: " db_choice
            db_choice="${db_choice:-1}"
            if [[ "$db_choice" == "2" ]]; then
                local xui_env_file
                case "${release}" in
                    ubuntu | debian | armbian)
                        xui_env_file="/etc/default/x-ui"
                        ;;
                    arch | manjaro | parch | alpine)
                        xui_env_file="/etc/conf.d/x-ui"
                        ;;
                    *)
                        xui_env_file="/etc/sysconfig/x-ui"
                        ;;
                esac

                local xui_dsn=""
                local pg_mode=""
                local pg_local_installed=0
                while [[ -z "$xui_dsn" ]]; do
                    echo ""
                    echo -e "  1) 在本地安装 PostgreSQL 并创建专用用户和数据库 (推荐)"
                    echo -e "  2) 使用已有的外部 PostgreSQL 服务器 (输入 DSN)"
                    read -rp "请选择 [默认 1]: " pg_mode
                    pg_mode="${pg_mode:-1}"
                    if [[ "$pg_mode" == "2" ]]; then
                        while [[ -z "$xui_dsn" ]]; do
                            read -rp "请输入 PostgreSQL DSN 连接串 (例如 postgres://user:pass@host:port/dbname?sslmode=disable): " xui_dsn
                            xui_dsn="${xui_dsn// /}"
                        done
                        db_label="PostgreSQL (外部服务器)"
                    else
                        echo -e "${yellow}正在安装 PostgreSQL — 这可能需要一点时间...${plain}"
                        local pg_cred_file
                        pg_cred_file=$(mktemp 2> /dev/null) || pg_cred_file=$(mktemp -t x-ui-pg-creds.XXXXXXXX)
                        if [[ -z "${pg_cred_file}" ]]; then
                            echo -e "${red}无法创建临时凭证文件。${plain}"
                            xui_dsn=""
                            continue
                        fi
                        if xui_dsn=$(PG_CRED_FILE="${pg_cred_file}" install_postgres_local); then
                            pg_local_installed=1
                            if [[ -r "${pg_cred_file}" ]]; then
                                # shellcheck disable=SC1090
                                source "${pg_cred_file}"
                            fi
                            rm -f "${pg_cred_file}"
                            db_label="PostgreSQL (${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB})"
                        else
                            rm -f "${pg_cred_file}"
                            echo ""
                            echo -e "${red}PostgreSQL 安装失败。${plain}"
                            echo -e "  1) 重试本地安装"
                            echo -e "  2) 输入外部数据库 DSN"
                            echo -e "  3) 中断安装"
                            echo -e "  4) 回退并使用 SQLite"
                            read -rp "请选择 [默认 1]: " pg_fail
                            pg_fail="${pg_fail:-1}"
                            case "$pg_fail" in
                                2) pg_mode="2" ;;
                                3)
                                    echo -e "${red}安装已中止。${plain}"
                                    exit 1
                                    ;;
                                4)
                                    db_choice="1"
                                    xui_dsn=""
                                    break
                                    ;;
                                *) xui_dsn="" ;;
                            esac
                        fi
                    fi
                done
                if [[ -n "$xui_dsn" ]]; then
                    install -d -m 755 "$(dirname "$xui_env_file")"
                    umask 077
                    cat > "$xui_env_file" << EOF
XUI_DB_TYPE=postgres
XUI_DB_DSN=${xui_dsn}
EOF
                    chmod 600 "$xui_env_file"
                    umask 022
                    export XUI_DB_TYPE=postgres
                    export XUI_DB_DSN="${xui_dsn}"
                    ensure_pg_client || echo -e "${yellow}⚠ 无法安装 pg_dump/pg_restore。在您手动安装 postgresql-client 软件包前，面板内的数据库备份/恢复功能将不可用。${plain}"
                fi
            fi

            read -rp "您想自定义面板端口吗？(如果不自定义，将随机生成一个端口) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "请设置您的面板端口: " config_port
                echo -e "${yellow}您的面板端口已设置为: ${config_port}${plain}"
            else
                local config_port=$(shuf -i 1024-62000 -n 1)
                echo -e "${yellow}已生成随机面板端口: ${config_port}${plain}"
            fi

            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"

            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL 证书申请与配置 (强烈推荐)         ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}为了安全，强烈建议您配置 SSL。只有当您打算使用反向代理${plain}"
            echo -e "${yellow}或 SSH 隧道来处理 TLS 时，才选择跳过 SSL 配置。${plain}"
            echo -e "${yellow}Let's Encrypt 目前已同时支持域名和公网 IP 地址证书的申请！${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"

            # Retrieve the API token for display
            local config_apiToken=$(${xui_folder}/x-ui setting -getApiToken true | grep -Eo 'apiToken: .+' | awk '{print $2}')

            # Display final credentials and access information
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     面板安装成功！                       ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}用户名:      ${config_username}${plain}"
            echo -e "${green}密码:        ${config_password}${plain}"
            echo -e "${green}面板监听端口:${config_port}${plain}"
            echo -e "${green}网页根路径:  /${config_webBasePath}${plain}"
            echo -e "${green}面板数据库:  ${db_label}${plain}"
            echo -e "${green}访问链接:    ${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}API Token:   ${config_apiToken}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ 重要提示: 请妥善保管好您的以上登录凭证！${plain}"
            if [[ "$SSL_SCHEME" == "https" ]]; then
                echo -e "${yellow}⚠ SSL 证书已启用并成功配置！${plain}"
            else
                echo -e "${yellow}⚠ SSL 证书已跳过 — 当前面板通过纯 HTTP 协议提供服务。建议置于反向代理或通过 SSH 隧道访问。${plain}"
            fi

            if [[ "$db_choice" == "2" ]]; then
                echo ""
                echo -e "${green}PostgreSQL 备份与恢复已集成至面板中:${plain}"
                echo -e "  访问面板导航 ${blue}${SSL_SCHEME}://${SSL_HOST}:${config_port}/${config_webBasePath}${plain} → 备份与恢复"
                echo -e "${yellow}  “备份”将下载由 pg_dump 生成的 .dump 数据库文件；“恢复”则调用 pg_restore 导入该文件。${plain}"
            fi

            if [[ "$db_choice" == "2" && "$pg_local_installed" == "1" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     PostgreSQL 数据库凭证                ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}数据库名:   ${PG_DB}${plain}"
                echo -e "${green}用户名:     ${PG_USER}${plain}"
                echo -e "${green}密码:       ${PG_PASS}${plain}"
                echo -e "${green}主机:       ${PG_HOST}${plain}"
                echo -e "${green}端口:       ${PG_PORT}${plain}"
                echo -e "${green}DSN 连接串: ${xui_dsn}${plain}"
                echo -e "${green}环境变量文件:${xui_env_file}${plain}"
                echo -e "${green}-------------------------------------------${plain}"
                echo -e "${green}在服务器命令行中连接方式:${plain}"
                echo -e "  ${blue}sudo -u postgres psql -d ${PG_DB}${plain}      (使用 postgres 超级用户身份登录)"
                echo -e "  ${blue}PGPASSWORD='${PG_PASS}' psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_USER} -d ${PG_DB}${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}⚠ 面板服务将从配置文件 ${xui_env_file} 中读取该数据库凭证。${plain}"
                echo -e "${yellow}⚠ 请妥善记录此密码，它不会在其他任何地方保存为明文。${plain}"
                unset PG_USER PG_PASS PG_HOST PG_PORT PG_DB
            fi
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}网页根路径 (webBasePath) 为空或过短，正在随机生成一个根路径...${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}新生成的网页根路径为: ${config_webBasePath}${plain}"

            # If the panel is already installed but no certificate is configured, prompt for SSL now
            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     SSL 证书申请与配置 (强烈推荐)         ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}Let's Encrypt 目前已同时支持域名和公网 IP 地址证书的申请！${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}访问链接:    ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                # If a cert already exists, just show the access URL
                echo -e "${green}访问链接:    https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)

            echo -e "${yellow}检测到您正在使用默认账号密码。为了安全，必须进行修改...${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "已为您生成新的随机登录凭证:"
            echo -e "###############################################"
            echo -e "${green}用户名:   ${config_username}${plain}"
            echo -e "${green}密码:     ${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}您的用户名、密码和网页根路径配置配置正常。${plain}"
        fi

        # Existing install: if no cert configured, prompt user for SSL setup
        # Properly detect empty cert by checking if cert: line exists and has content after it
        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL 证书申请与配置 (强烈推荐)         ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Let's Encrypt 目前已同时支持域名和公网 IP 地址证书的申请！${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}访问链接:    ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}SSL 证书已成功配置过，无须额外操作。${plain}"
        fi
    fi

    ${xui_folder}/x-ui migrate
}

install_x-ui() {
    cd ${xui_folder%/x-ui}/

    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
                exit 1
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"

        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi

        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    curl -4fLRo /usr/bin/x-ui-temp https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui.sh${plain}"
        exit 1
    fi

    # Stop x-ui service and remove old resources
    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm ${xui_folder}/ -rf
    fi

    # Extract resources and set permissions
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f

    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh

    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)

    # Update x-ui cli and se set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    config_after_install

    # Etckeeper compatibility
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}Added x-ui.db to /etc/.gitignore for etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}Created /etc/.gitignore and added x-ui.db for etckeeper${plain}"
        fi
    fi

    if [[ $release == "alpine" ]]; then
        curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # Install systemd service file
        service_installed=false

        if [ -f "x-ui.service" ]; then
            echo -e "${green}Found x-ui.service in extracted files, installing...${plain}"
            cp -f x-ui.service ${xui_service}/ > /dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi

        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Found x-ui.service.debian in extracted files, installing...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Found x-ui.service.arch in extracted files, installing...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Found x-ui.service.rhel in extracted files, installing...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac
        fi

        # If service file not found in tar.gz, download from GitHub
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}Service files not found in tar.gz, downloading from GitHub...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.debian > /dev/null 2>&1
                    ;;
                arch | manjaro | parch)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.arch > /dev/null 2>&1
                    ;;
                *)
                    curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.rhel > /dev/null 2>&1
                    ;;
            esac

            if [[ $? -ne 0 ]]; then
                echo -e "${red}Failed to install x-ui.service from GitHub${plain}"
                exit 1
            fi
            service_installed=true
        fi

        if [ "$service_installed" = true ]; then
            echo -e "${green}Setting up systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}Failed to install x-ui.service file${plain}"
            exit 1
        fi
    fi

    echo -e "${green}x-ui ${tag_version}${plain} 安装完成，现已启动运行..."
    echo -e ""
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}x-ui 控制菜单使用方法 (命令行子命令):${plain}                 │
│                                                                │
│  ${blue}x-ui${plain}                       - 显示管理菜单 (管理脚本)          │
│  ${blue}x-ui start${plain}                 - 启动 x-ui 面板                   │
│  ${blue}x-ui stop${plain}                  - 停止 x-ui 面板                   │
│  ${blue}x-ui restart${plain}               - 重启 x-ui 面板                   │
│  ${blue}x-ui status${plain}                - 查看当前状态                     │
│  ${blue}x-ui settings${plain}              - 查看当前设置                     │
│  ${blue}x-ui enable${plain}                - 启用面板开机自启                 │
│  ${blue}x-ui disable${plain}               - 禁用面板开机自启                 │
│  ${blue}x-ui log${plain}                   - 查看面板运行日志                 │
│  ${blue}x-ui banlog${plain}                - 查看 Fail2ban 封禁日志           │
│  ${blue}x-ui update${plain}                - 更新 x-ui 面板                   │
│  ${blue}x-ui legacy${plain}                - 切换历史版本                     │
│  ${blue}x-ui install${plain}               - 安装 x-ui 面板                   │
│  ${blue}x-ui uninstall${plain}             - 卸载 x-ui 面板                   │
└────────────────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
install_base
install_x-ui $1
