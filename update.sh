#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# Don't edit this config
b_source="${BASH_SOURCE[0]}"
while [ -h "$b_source" ]; do
    b_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
    b_source="$(readlink "$b_source")"
    [[ $b_source != /* ]] && b_source="$b_dir/$b_source"
done
cur_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
script_name=$(basename "$0")

# Check command exist function
_command_exists() {
    type "$1" &> /dev/null
}

# Fail, log and exit script function
_fail() {
    local msg=${1}
    echo -e "${red}${msg}${plain}"
    exit 2
}

# check root
[[ $EUID -ne 0 ]] && _fail "FATAL ERROR: Please run this script with root privilege."

if _command_exists curl; then
    curl_bin=$(which curl)
else
    _fail "ERROR: Command 'curl' not found."
fi

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    _fail "Failed to check the system OS, please contact the author!"
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
        *) echo -e "${red}Unsupported CPU architecture!${plain}" && rm -f "${cur_dir}/${script_name}" > /dev/null 2>&1 && exit 2 ;;
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

function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}
function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}
function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
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

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

xui_env_file_path() {
    case "${release}" in
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

load_xui_env() {
    local env_file
    env_file="$(xui_env_file_path)"
    if [[ -r "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

install_base() {
    echo -e "${green}Updating and install dependency packages...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu > /dev/null 2>&1 && pacman -Syu --noconfirm cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y cron curl tar timezone socat openssl > /dev/null 2>&1
            ;;
        alpine)
            apk update > /dev/null 2>&1 && apk add dcron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        *)
            apt-get update > /dev/null 2>&1 && apt install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
    esac
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

    # Set reload command for auto-renewal (add || true so it doesn't fail if service stopped)
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
    read -rp "Would you like to set this certificate for the panel? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "Certificate paths set for the panel"
            LOGI "Certificate File: $webCertFile"
            LOGI "Private Key File: $webKeyFile"
            echo ""
            echo -e "${green}Access URL: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            LOGI "Panel will restart to apply SSL certificate..."
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            LOGE "Error: Certificate or private key file not found for domain: $domain."
        fi
    else
        LOGI "Skipping panel path setting."
    fi

    return 0
}
# Unified interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP
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

config_after_update() {
    echo -e "${yellow}x-ui 设置状态:${plain}"
    ${xui_folder}/x-ui setting -show true
    ${xui_folder}/x-ui migrate

    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true 2> /dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')

    # Get server IP
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

    # Handle missing/short webBasePath
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        echo -e "${yellow}Web 根路径 (WebBasePath) 缺失或太短。正在生成新的路径...${plain}"
        local config_webBasePath=$(gen_random_string 18)
        ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
        existing_webBasePath="${config_webBasePath}"
        echo -e "${green}新的 Web 根路径: ${config_webBasePath}${plain}"
    fi

    # Check and prompt for SSL if missing
    if [[ -z "$existing_cert" ]]; then
        echo ""
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${red}      ⚠ 未检测到 SSL 证书 ⚠               ${plain}"
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}出于安全考虑，强烈建议所有面板都配置 SSL 证书。${plain}"
        echo -e "${yellow}Let's Encrypt 现在同时支持域名和公网 IP 地址证书申请！${plain}"
        echo ""

        # Prompt and setup SSL (domain or IP)
        prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"

        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     面板访问信息                          ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问链接: ${SSL_SCHEME}://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        if [[ "$SSL_SCHEME" == "https" ]]; then
            echo -e "${yellow}⚠ SSL 证书: 已启用并配置${plain}"
        else
            echo -e "${yellow}⚠ SSL 证书: 已跳过 — 当前面板通过纯 HTTP 协议提供服务。建议置于反向代理或通过 SSH 隧道访问。${plain}"
        fi
    else
        echo -e "${green}SSL 证书已配置${plain}"
        # Show access URL with existing certificate
        local cert_domain=$(basename "$(dirname "$existing_cert")")
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     面板访问信息                          ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问链接: https://${cert_domain}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
    fi
}

update_x-ui() {
    cd ${xui_folder%/x-ui}/

    load_xui_env

    if [ -f "${xui_folder}/x-ui" ]; then
        current_xui_version=$(${xui_folder}/x-ui -v)
        echo -e "${green}当前 x-ui 版本: ${current_xui_version}${plain}"
    else
        _fail "错误: 当前 x-ui 版本未知"
    fi

    echo -e "${green}正在下载新版本的 x-ui...${plain}"

    tag_version=$(${curl_bin} -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2> /dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$tag_version" ]]; then
        echo -e "${yellow}尝试使用 IPv4 获取版本信息...${plain}"
        tag_version=$(${curl_bin} -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            _fail "错误: 获取 x-ui 版本失败，可能是由于 GitHub API 限制，请稍后重试"
        fi
    fi
    echo -e "获取到 x-ui 最新版本: ${tag_version}，开始安装..."
    ${curl_bin} -fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2> /dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${yellow}尝试使用 IPv4 获取版本信息...${plain}"
        ${curl_bin} -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2> /dev/null
        if [[ $? -ne 0 ]]; then
            _fail "错误: 下载 x-ui 失败，请确保您的服务器可以正常访问 GitHub"
        fi
    fi

    if [[ -e ${xui_folder}/ ]]; then
        echo -e "${green}正在停止 x-ui...${plain}"
        if [[ $release == "alpine" ]]; then
            if [ -f "/etc/init.d/x-ui" ]; then
                rc-service x-ui stop > /dev/null 2>&1
                rc-update del x-ui > /dev/null 2>&1
                echo -e "${green}正在移除旧版本的服务单元...${plain}"
                rm -f /etc/init.d/x-ui > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "错误: x-ui 服务单元未安装。"
            fi
        else
            if [ -f "${xui_service}/x-ui.service" ]; then
                systemctl stop x-ui > /dev/null 2>&1
                systemctl disable x-ui > /dev/null 2>&1
                echo -e "${green}正在移除旧版本的 systemd 单元...${plain}"
                rm ${xui_service}/x-ui.service -f > /dev/null 2>&1
                systemctl daemon-reload > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "错误: x-ui systemd 单元未安装。"
            fi
        fi
        echo -e "${green}正在移除旧版本的 x-ui...${plain}"
        rm ${xui_folder} -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.debian -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.arch -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.rhel -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.sh -f > /dev/null 2>&1
        echo -e "${green}正在移除旧版本的 xray...${plain}"
        rm ${xui_folder}/bin/xray-linux-amd64 -f > /dev/null 2>&1
        echo -e "${green}正在移除旧的 README 和 LICENSE 文件...${plain}"
        rm ${xui_folder}/bin/README.md -f > /dev/null 2>&1
        rm ${xui_folder}/bin/LICENSE -f > /dev/null 2>&1
    else
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "错误: 未检测到已安装的 x-ui。"
    fi

    echo -e "${green}正在安装新版本的 x-ui...${plain}"
    tar zxvf x-ui-linux-$(arch).tar.gz > /dev/null 2>&1
    rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
    cd x-ui > /dev/null 2>&1
    chmod +x x-ui > /dev/null 2>&1

    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm > /dev/null 2>&1
        chmod +x bin/xray-linux-arm > /dev/null 2>&1
    fi

    chmod +x x-ui bin/xray-linux-$(arch) > /dev/null 2>&1

    echo -e "${green}正在下载并安装 x-ui.sh 脚本...${plain}"
    ${curl_bin} -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${yellow}尝试使用 IPv4 获取 x-ui...${plain}"
        ${curl_bin} -4fLRo /usr/bin/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            _fail "错误: 下载 x-ui.sh 脚本失败，请确保您的服务器可以正常访问 GitHub"
        fi
    fi

    chmod +x ${xui_folder}/x-ui.sh > /dev/null 2>&1
    chmod +x /usr/bin/x-ui > /dev/null 2>&1
    mkdir -p /var/log/x-ui > /dev/null 2>&1

    echo -e "${green}正在变更所有者权限...${plain}"
    chown -R root:root ${xui_folder} > /dev/null 2>&1

    if [ -f "${xui_folder}/bin/config.json" ]; then
        echo -e "${green}正在修改配置文件权限...${plain}"
        chmod 640 ${xui_folder}/bin/config.json > /dev/null 2>&1
    fi

    if [[ $release == "alpine" ]]; then
        echo -e "${green}正在下载并安装启动文件 x-ui.rc...${plain}"
        ${curl_bin} -fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.rc > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            ${curl_bin} -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.rc > /dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                _fail "错误: 下载启动文件 x-ui.rc 失败，请确保您的服务器可以正常访问 GitHub"
            fi
        fi
        chmod +x /etc/init.d/x-ui > /dev/null 2>&1
        chown root:root /etc/init.d/x-ui > /dev/null 2>&1
        rc-update add x-ui > /dev/null 2>&1
        rc-service x-ui start > /dev/null 2>&1
    else
        if [ -f "x-ui.service" ]; then
            echo -e "${green}正在安装 systemd 服务...${plain}"
            cp -f x-ui.service ${xui_service}/ > /dev/null 2>&1
            if [[ $? -ne 0 ]]; then
                echo -e "${red}复制 x-ui.service 失败${plain}"
                exit 1
            fi
        else
            service_installed=false
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}正在安装 Debian 系 systemd 服务...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}正在安装 Arch 系 systemd 服务...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}正在安装 RHEL 系 systemd 服务...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac

            # If service file not found in tar.gz, download from GitHub
            if [ "$service_installed" = false ]; then
                echo -e "${yellow}未在归档包中找到服务文件，正在从 GitHub 下载...${plain}"
                case "${release}" in
                    ubuntu | debian | armbian)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.debian > /dev/null 2>&1
                        ;;
                    arch | manjaro | parch)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.arch > /dev/null 2>&1
                        ;;
                    *)
                        ${curl_bin} -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.service.rhel > /dev/null 2>&1
                        ;;
                esac

                if [[ $? -ne 0 ]]; then
                    echo -e "${red}从 GitHub 下载并安装 x-ui.service 失败${plain}"
                    exit 1
                fi
            fi
        fi
        chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
        chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable x-ui > /dev/null 2>&1
        systemctl start x-ui > /dev/null 2>&1
    fi

    config_after_update

    echo -e "${green}x-ui ${tag_version}${plain} 更新完成，现已启动运行..."
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
update_x-ui $1
