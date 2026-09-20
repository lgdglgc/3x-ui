#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}
function LOGW() {
    echo -e "${yellow}[WRN] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
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
        for svc in nginx openresty apache2 httpd caddy tengine; do
            if systemctl is-active --quiet ${svc} 2>/dev/null; then
                LOGI "正在临时停止 ${svc} 服务以释放端口 ${port}..." >&2
                systemctl stop ${svc} >/dev/null 2>&1
                stopped_services="${stopped_services} ${svc}"
            elif [ -f "/etc/init.d/${svc}" ]; then
                LOGI "正在临时停止 /etc/init.d/${svc} 服务以释放端口 ${port}..." >&2
                /etc/init.d/${svc} stop >/dev/null 2>&1
                stopped_services="${stopped_services} ${svc}"
            fi
        done
    fi
    echo "${stopped_services}"
}

start_occupying_services() {
    local svcs="$1"
    for svc in ${svcs}; do
        LOGI "正在恢复重启 ${svc} 服务..." >&2
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || systemctl status "${svc}" >/dev/null 2>&1; then
            systemctl start ${svc} >/dev/null 2>&1
        elif [ -f "/etc/init.d/${svc}" ]; then
            /etc/init.d/${svc} start >/dev/null 2>&1
        fi
    done
}


# Simple helpers for domain/IP validation
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

# check root
[[ $EUID -ne 0 ]] && LOGE "错误: 必须使用 root 超级用户权限运行此脚本！\n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "无法检测当前操作系统发行版，请检查系统环境！" >&2
    exit 1
fi
echo "当前操作系统发行版: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# Declare Variables
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "确认重启面板？注意: 重启面板同时会重启 Xray 内核" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此操作将更新所有 x-ui 组件，现有数据不会丢失。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "Cancelled"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成，面板已自动重启"
        before_show_menu
    fi
}

update_menu() {
    echo -e "${yellow}正在更新管理脚本菜单${plain}"
    confirm "此操作将把管理脚本菜单更新至最新。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "Cancelled"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    curl -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh
    cp -f /usr/bin/x-ui ${xui_folder}/x-ui.sh > /dev/null 2>&1 || true
    chmod +x ${xui_folder}/x-ui.sh
    chmod +x /usr/bin/x-ui

    if [[ $? == 0 ]]; then
        echo -e "${green}更新成功，面板已自动重启。${plain}"
        exit 0
    else
        echo -e "${red}更新菜单脚本失败。${plain}"
        return 1
    fi
}

legacy_version() {
    read -rp "请输入要切换的面板版本 [默认 3.8.5]: " tag_version
    [[ -z "$tag_version" ]] && tag_version="3.8.5"
    [[ "$tag_version" =~ ^v ]] || tag_version="v$tag_version"

    read -rp "请输入要搭配的 Xray 核心版本 [默认 v26.6.27]: " xray_version
    [[ -z "$xray_version" ]] && xray_version="v26.6.27"
    [[ "$xray_version" =~ ^v ]] || xray_version="v$xray_version"

    # Use the entered panel version and xray version in the download link
    install_command="bash <(curl -Ls "https://raw.githubusercontent.com/lgdglgc/3x-ui/main/install.sh") $tag_version $xray_version"

    echo "正在下载并安装面板版本 $tag_version (Xray 核心: $xray_version)..."
    eval $install_command
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
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

uninstall() {
    confirm "确定要卸载 x-ui 面板吗？注意: Xray 内核也将被一并卸载！" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf
    rm -f "$(xui_env_file_path)"

    echo ""
    echo -e "卸载成功。\n"
    echo "如需再次安装面板，可执行以下命令:"
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/install.sh)${plain}"
    echo ""
    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "确定要重置面板的登录用户名和密码吗？" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    read -rp "请设置登录用户名 [默认随机生成]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "请设置登录密码 [默认随机生成]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "是否禁用当前已配置的两步验证？(y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor=true > /dev/null 2>&1
        echo -e "两步验证已成功禁用。"
    fi

    echo -e "面板登录用户名已重置为: ${green} ${config_account} ${plain}"
    echo -e "面板登录密码已重置为: ${green} ${config_password} ${plain}"
    echo -e "${green} 请使用新的登录用户名和密码访问面板，务必牢记！${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}重置网页根路径 (webBasePath)${plain}"

    read -rp "确定要重置网页根路径吗？(y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}操作已取消。${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Apply the new web base path setting
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    echo -e "网页根路径已重置为: ${green}${config_webBasePath}${plain}"
    echo -e "${green}请使用新的网页根路径访问面板。${plain}"
    restart
}

reset_config() {
    confirm "确定要重置所有面板设置吗？账号节点数据不会丢失，用户名和密码保持不变" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "所有面板设置已重置为默认值。"
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "获取当前设置失败，请检查运行日志"
        show_menu
        return
    fi
    LOGI "${info}"

    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        local dsn
        dsn="$(grep -E '^XUI_DB_DSN=' "$db_env_file" | head -1 | cut -d= -f2-)"
        local dsn_safe
        dsn_safe="$(echo "$dsn" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|')"
        echo -e "${green}Database: PostgreSQL — ${dsn_safe}${plain}"
    else
        echo -e "${green}Database: SQLite (/etc/x-ui/x-ui.db)${plain}"
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
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
        echo -e "${yellow}无法从任何接口服务自动检测到服务器 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入您服务器的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}无效的 IPv4 地址，请重新输入。${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问链接: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问链接: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${red}⚠ 警告: 当前面板未配置 SSL 证书！${plain}"
        echo -e "${yellow}您可以为 IP 地址申请 Let's Encrypt 短效证书 (约 6 天有效期，支持自动续签)。${plain}"
        read -rp "是否现在为 IP 生成 SSL 证书？[y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop 0 > /dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}访问链接: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                # ssl_cert_issue_for_ip already restarts the panel, but ensure it's running
                start 0 > /dev/null 2>&1
            else
                LOGE "IP 证书申请与配置失败。"
                echo -e "${yellow}您稍后可通过菜单选项 19 (SSL 证书管理) 重新申请。${plain}"
                start 0 > /dev/null 2>&1
            fi
        else
            echo -e "${yellow}访问链接: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}为了安全起见，建议通过选项 19 (SSL 证书管理) 配置安全证书${plain}"
        fi
    fi
}

set_port() {
    echo -n "Enter port number[1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "Cancelled"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "端口已设置，请重启面板，并使用新端口 ${green}${port}${plain} 访问 Web 面板"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板正在运行中，无需重复启动。如需重启请选择重启选项"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui 面板启动成功"
        else
            LOGE "面板启动失败，可能是启动超时，请稍后查看日志确认详情"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已处于停止状态，无需重复停止！"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui 面板与 Xray 内核已成功停止"
        else
            LOGE "面板停止失败，可能是停止超时，请稍后查看日志确认"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui 面板与 Xray 内核已成功重启"
    else
        LOGE "面板重启失败，可能是启动耗时较长，请稍后查看日志确认"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui reload
    else
        systemctl reload x-ui
    fi
    LOGI "Xray 内核重启信号已成功发送，请查看日志确认 Xray 重启状态"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "已成功设置 x-ui 开机自启"
    else
        LOGE "设置 x-ui 开机自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "已成功取消 x-ui 开机自启"
    else
        LOGE "取消 x-ui 开机自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}无效选项，请输入有效序号。${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t2.${plain} 清理所有日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "Choose an option: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "所有日志已清空。"
                restart
                ;;
            *)
                echo -e "${red}无效选项，请输入有效序号。${plain}\n"
                show_log
                ;;
        esac
    fi
}

# ==============================================================================
# BBR 网络加速与内核管理模块 (Enhanced BBR & TCP Network Optimization)
# ==============================================================================

XUI_BBR_SYSCTL="/etc/sysctl.d/99-3x-ui-bbr.conf"
XUI_QDISC_MODULES="/etc/modules-load.d/3x-ui-qdisc.conf"
XUI_SECURITY_MODPROBE="/etc/modprobe.d/99-3x-ui-security.conf"
BBR_GITHUB_API="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"

bbr_detect_virt() {
    local virt="none"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [ -f /.dockerenv ]; then
        virt="docker"
    elif grep -qa container=lxc /proc/1/environ 2>/dev/null; then
        virt="lxc"
    elif [ -d /proc/vz ]; then
        virt="openvz"
    fi
    echo "$virt"
}

before_bbr_menu() {
    echo && echo -n -e "${yellow}按回车键返回 BBR 管理菜单: ${plain}" && read -r temp
    bbr_menu
}

bbr_clean_sysctl() {
    rm -f "/etc/sysctl.d/99-bbr-x-ui.conf"
    rm -f "/etc/sysctl.d/99-joeyblog.conf"
    rm -f "/etc/modules-load.d/joeyblog-qdisc.conf"
    rm -f "/etc/modprobe.d/99-joeyblog-security.conf"
    if [[ -f "$XUI_BBR_SYSCTL" ]]; then
        rm -f "$XUI_BBR_SYSCTL"
    fi
    if [[ -f "/etc/sysctl.conf" ]]; then
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
        sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
    fi
}

bbr_load_qdisc_module() {
    local qdisc="$1"
    local mod="sch_${qdisc}"
    if ! lsmod 2>/dev/null | grep -q "^${mod//-/_}"; then
        modprobe "$mod" >/dev/null 2>&1 || true
    fi
    if sysctl -w net.core.default_qdisc="$qdisc" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

bbr_apply_qdisc_interfaces() {
    local qdisc="$1"
    if ! command -v tc >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 && apt-get install -y iproute2 >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y iproute-tc >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y iproute-tc >/dev/null 2>&1 || true
        fi
    fi
    if command -v tc >/dev/null 2>&1 && command -v ip >/dev/null 2>&1; then
        local ifaces
        ifaces=$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u)
        for iface in $ifaces; do
            [[ -n "$iface" ]] && tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1 || true
        done
    fi
}

bbr_persist_qdisc() {
    local qdisc="$1"
    local mod="sch_${qdisc}"
    if [[ "$qdisc" == "fq" ]]; then
        rm -f "$XUI_QDISC_MODULES"
        return 0
    fi
    if modinfo "$mod" >/dev/null 2>&1 || lsmod 2>/dev/null | grep -q "^${mod//-/_}"; then
        mkdir -p /etc/modules-load.d
        echo "$mod" > "$XUI_QDISC_MODULES"
    fi
}

bbr_enable_native() {
    LOGI "正在启用系统原生 BBR 加速..."
    bbr_load_qdisc_module "fq"
    bbr_apply_qdisc_interfaces "fq"

    sysctl -w net.core.default_qdisc="fq" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control="bbr" >/dev/null 2>&1

    mkdir -p /etc/sysctl.d
    bbr_clean_sysctl
    cat << 'EOF' > "$XUI_BBR_SYSCTL"
# 3X-UI Native BBR Configuration
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1

    local new_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$new_algo" == "bbr" ]]; then
        LOGI "已成功启用 BBR 加速！(拥塞算法: ${new_algo}, 队列调度: ${new_qdisc})"
    else
        LOGE "启用 BBR 失败，当前内核可能缺少 tcp_bbr 模块支持。当前拥塞算法为: ${new_algo}"
    fi
    before_bbr_menu
}

bbr_switch_qdisc_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│           请选择要切换的队列调度算法           │
│────────────────────────────────────────────────│
│   ${green}1.${plain} FQ (Fair Queueing - 推荐默认)              │
│   ${green}2.${plain} FQ_CODEL (抗缓冲膨胀/低延迟)               │
│   ${green}3.${plain} CAKE (Comprehensive Queue Management)     │
│   ${green}4.${plain} FQ_PIE (Proportional Integral controller) │
│   ${green}0.${plain} 返回上一级                                │
╚────────────────────────────────────────────────╝"
    read -rp "请输入选项 [0-4]: " q_choice
    local target_qdisc=""
    case "$q_choice" in
        1) target_qdisc="fq" ;;
        2) target_qdisc="fq_codel" ;;
        3) target_qdisc="cake" ;;
        4) target_qdisc="fq_pie" ;;
        0) bbr_menu; return ;;
        *) LOGE "输入无效序号！"; bbr_switch_qdisc_menu; return ;;
    esac

    LOGI "正在尝试加载并切换队列调度算法至 ${target_qdisc}..."
    if ! bbr_load_qdisc_module "$target_qdisc"; then
        LOGE "当前内核缺少 sch_${target_qdisc} 模块，无法切换至 ${target_qdisc}。"
        before_bbr_menu
        return 1
    fi

    bbr_apply_qdisc_interfaces "$target_qdisc"
    bbr_persist_qdisc "$target_qdisc"

    mkdir -p /etc/sysctl.d
    if [[ ! -f "$XUI_BBR_SYSCTL" ]]; then
        echo "net.ipv4.tcp_congestion_control = bbr" > "$XUI_BBR_SYSCTL"
    fi
    sed -i '/net.core.default_qdisc/d' "$XUI_BBR_SYSCTL"
    echo "net.core.default_qdisc = ${target_qdisc}" >> "$XUI_BBR_SYSCTL"
    sysctl -w net.core.default_qdisc="${target_qdisc}" >/dev/null 2>&1

    LOGI "队列算法已成功切换为: ${target_qdisc}"
    before_bbr_menu
}

bbr_apply_apac_tuning() {
    LOGI "正在应用亚太/跨国线路 TCP 智能调优配置..."
    bbr_load_qdisc_module "fq"
    bbr_apply_qdisc_interfaces "fq"

    sysctl -w net.core.default_qdisc="fq" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control="bbr" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 12582912" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_limit_output_bytes="4194304" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle="0" >/dev/null 2>&1

    mkdir -p /etc/sysctl.d
    bbr_clean_sysctl
    cat << 'EOF' > "$XUI_BBR_SYSCTL"
# 3X-UI Asia-Pacific TCP Tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_wmem = 4096 16384 12582912
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
    LOGI "✔ 亚太/跨国线路 TCP 调优已生效并永久写入: $XUI_BBR_SYSCTL"
    before_bbr_menu
}

bbr_get_ram_cap_mb() {
    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if ! [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
        echo 64
    elif (( mem_kb < 524288 )); then
        echo 16
    elif (( mem_kb < 1048576 )); then
        echo 32
    else
        echo 64
    fi
}

bbr_apply_smart_tuning() {
    echo -e "
╔────────────────────────────────────────────────╗
│           BBR 智能带宽与延迟缓冲优化           │
│────────────────────────────────────────────────│
│ 说明：根据节点真实带宽与跨国 RTT 延迟，结合系统│
│ 内存保护上限，自动计算并配置最优 TCP 缓冲大小。│
╚────────────────────────────────────────────────╝"

    local bandwidth_mbps=""
    read -rp "请输入节点上传带宽 (Mbps，直接回车默认 1000): " bandwidth_mbps
    bandwidth_mbps="${bandwidth_mbps:-1000}"
    if ! [[ "$bandwidth_mbps" =~ ^[0-9]+$ ]] || (( bandwidth_mbps <= 0 )); then
        bandwidth_mbps=1000
    fi

    echo -e "\n请选择网络主要链路模式:"
    echo -e " 1. 亚太区域线路 (通常 RTT < 100ms)"
    echo -e " 2. 欧美/跨大洲线路 (通常 RTT 150-300ms)"
    read -rp "请选择 [1-2，默认 1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    local cap_mb
    cap_mb=$(bbr_get_ram_cap_mb)
    local buffer_mb=16
    if [[ "$mode_choice" == "2" ]]; then
        if (( bandwidth_mbps < 500 )); then
            buffer_mb=16
        elif (( bandwidth_mbps < 1000 )); then
            buffer_mb=48
        else
            buffer_mb=64
        fi
    else
        if (( bandwidth_mbps < 500 )); then
            buffer_mb=8
        elif (( bandwidth_mbps < 1000 )); then
            buffer_mb=12
        elif (( bandwidth_mbps < 2000 )); then
            buffer_mb=16
        elif (( bandwidth_mbps < 5000 )); then
            buffer_mb=24
        else
            buffer_mb=32
        fi
    fi

    if (( buffer_mb > cap_mb )); then
        buffer_mb="$cap_mb"
    fi
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    local output_bytes=4194304

    LOGI "计算得出推荐配置: 缓冲大小 ${buffer_mb}MB (内存保护上限 ${cap_mb}MB)"
    bbr_load_qdisc_module "fq"
    bbr_apply_qdisc_interfaces "fq"

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.core.rmem_max="$buffer_bytes" >/dev/null 2>&1
    sysctl -w net.core.wmem_max="$buffer_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 $buffer_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $buffer_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle="0" >/dev/null 2>&1

    mkdir -p /etc/sysctl.d
    bbr_clean_sysctl
    cat << EOF > "$XUI_BBR_SYSCTL"
# 3X-UI Smart Bandwidth Tuning (${bandwidth_mbps}Mbps, Buffer: ${buffer_mb}MB)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $buffer_bytes
net.core.wmem_max = $buffer_bytes
net.ipv4.tcp_wmem = 4096 65536 $buffer_bytes
net.ipv4.tcp_rmem = 4096 87380 $buffer_bytes
net.ipv4.tcp_limit_output_bytes = $output_bytes
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
    LOGI "✔ 智能带宽优化配置已生效并持久化！"
    before_bbr_menu
}

bbr_apply_extreme_tuning() {
    echo -e "
╔────────────────────────────────────────────────╗
│           BBR 极限测速挑战模式 (疯批模式)      │
│────────────────────────────────────────────────│
│ ${red}警告：该模式专用于自有链路极限测速压榨吞吐！${plain}    │
│ 会显著拉大缓冲区(1GB)及网卡队列长度(100000)，  │
│ 日常多用户生产环境可能增加内存占用与排队抖动。 │
╚────────────────────────────────────────────────╝"
    confirm "是否确认开启极限测速挑战模式？" "n" || { bbr_menu; return 0; }

    LOGI "正在配置极限测速参数..."
    local buffer_bytes="1073741824"
    local output_bytes="268435456"
    local backlog="1000000"
    local txqueuelen="100000"

    bbr_load_qdisc_module "fq"
    bbr_apply_qdisc_interfaces "fq"

    if command -v ip >/dev/null 2>&1; then
        local ifaces
        ifaces=$(ip -o route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | sort -u)
        for iface in $ifaces; do
            [[ -n "$iface" ]] && ip link set dev "$iface" txqueuelen "$txqueuelen" 2>/dev/null || true
        done
    fi

    sysctl -w net.core.default_qdisc="fq" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control="bbr" >/dev/null 2>&1
    sysctl -w net.core.rmem_max="$buffer_bytes" >/dev/null 2>&1
    sysctl -w net.core.wmem_max="$buffer_bytes" >/dev/null 2>&1
    sysctl -w net.core.optmem_max="$buffer_bytes" >/dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog="$backlog" >/dev/null 2>&1
    sysctl -w net.core.somaxconn="65535" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 1048576 $buffer_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 1048576 $buffer_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle="0" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_notsent_lowat="4294967295" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_autocorking="0" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_no_metrics_save="1" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing="1" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen="3" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_window_scaling="1" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_moderate_rcvbuf="1" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_ecn="0" >/dev/null 2>&1

    mkdir -p /etc/sysctl.d
    bbr_clean_sysctl
    cat << EOF > "$XUI_BBR_SYSCTL"
# 3X-UI Extreme Benchmark Tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $buffer_bytes
net.core.wmem_max = $buffer_bytes
net.core.optmem_max = $buffer_bytes
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = 65535
net.ipv4.tcp_wmem = 4096 1048576 $buffer_bytes
net.ipv4.tcp_rmem = 4096 1048576 $buffer_bytes
net.ipv4.tcp_limit_output_bytes = $output_bytes
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_ecn = 0
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
    LOGI "✔ 极限测速挑战模式已配置完成！"
    before_bbr_menu
}

bbr_clear_all_tuning() {
    confirm "确认清空所有 BBR 网络优化参数并恢复系统默认？" "y" || { bbr_menu; return 0; }
    LOGI "正在清空所有网络优化参数..."
    bbr_clean_sysctl
    rm -f "$XUI_QDISC_MODULES"

    sysctl -w net.core.default_qdisc="pfifo_fast" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control="cubic" >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1 || true

    LOGI "✔ 已成功清空优化配置并恢复系统默认设置 (CUBIC + pfifo_fast)。"
    before_bbr_menu
}

bbr_v3_assert_env() {
    local virt
    virt=$(bbr_detect_virt)
    if [[ "$virt" =~ ^(lxc|openvz|docker|podman|container) ]]; then
        LOGE "检测到当前处于容器虚拟化环境 (${virt})，无法更换宿主机内核！"
        LOGW "提示：容器与宿主机共享内核。请使用选项 1-6 启用原生 BBR 加速与网络调优。"
        return 1
    fi

    if [[ "$release" != "ubuntu" && "$release" != "debian" ]]; then
        LOGE "BBR v3 预编译内核仅支持 Ubuntu 24.04+ 及 Debian 12+ 系统。"
        LOGW "您当前的系统为: ${release}。建议直接使用选项 1-6 启用原生 BBR 及 TCP 优化。"
        return 1
    fi

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        LOGE "BBR v3 预编译内核仅支持 x86_64 及 aarch64 (ARM64) 架构，当前架构为: ${arch}"
        return 1
    fi

    if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
        LOGE "当前系统缺少 dpkg 或 apt-get 工具，无法安装内核包。"
        return 1
    fi

    for cmd in curl wget dpkg jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            LOGI "正在安装必要依赖: $cmd..."
            apt-get update >/dev/null 2>&1 && apt-get install -y "$cmd" >/dev/null 2>&1 || true
        fi
    done
    return 0
}

bbr_v3_update_bootloader() {
    LOGI "正在更新系统引导加载程序 (update-grub)..."
    if command -v update-grub >/dev/null 2>&1; then
        if update-grub; then
            LOGI "✔ GRUB 引导配置更新成功！"
            return 0
        else
            LOGE "GRUB 引导更新失败，请检查引导配置！"
            return 1
        fi
    else
        LOGW "未检测到 update-grub 命令，可能使用的是非 GRUB 引导（如 U-Boot），内核安装程序将尝试自动配置引导。"
        return 0
    fi
}

bbr_v3_download_and_install() {
    local release_json="$1"
    local tag_name="$2"

    local asset_urls
    asset_urls=$(echo "$release_json" | jq -r --arg tag "$tag_name" '
        .[] | select(.tag_name == $tag) | .assets[].browser_download_url
        | select(test("(-dbg_|-dbgsym_)"; "i") | not)
    ')

    if [[ -z "$asset_urls" ]]; then
        LOGE "未在 Release ${tag_name} 中找到适用的内核安装包！"
        return 1
    fi

    local tmp_dir="/tmp/bbrv3_debs"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    LOGI "开始下载 BBR v3 内核包 (${tag_name})..."
    for url in $asset_urls; do
        local fname
        fname=$(basename "$url")
        LOGI "正在下载: $fname"
        if ! wget -q --show-progress "$url" -O "${tmp_dir}/${fname}"; then
            LOGW "直接下载失败，尝试使用加速镜像下载..."
            if ! wget -q --show-progress "https://ghproxy.net/${url}" -O "${tmp_dir}/${fname}"; then
                LOGE "下载失败: $url"
                return 1
            fi
        fi
    done

    for deb_file in "$tmp_dir"/*.deb; do
        if ! dpkg-deb -I "$deb_file" >/dev/null 2>&1; then
            LOGE "安装包完整性校验失败: $deb_file"
            return 1
        fi
    done

    LOGI "正在卸载已有旧版 joeyblog 内核包..."
    local old_pkgs
    old_pkgs=$(dpkg -l 2>/dev/null | grep "joeyblog" | awk '{print $2}' | tr '\n' ' ')
    if [[ -n "$old_pkgs" ]]; then
        apt-get remove --purge -y $old_pkgs >/dev/null 2>&1 || true
    fi

    LOGI "正在安装新版 BBR v3 内核..."
    if dpkg -i "$tmp_dir"/*.deb && bbr_v3_update_bootloader; then
        rm -rf "$tmp_dir"
        LOGI "✔ BBR v3 内核安装并配置成功！"
        confirm "新内核必须重启系统后方可生效，是否立即重启系统？" "y"
        if [[ $? == 0 ]]; then
            LOGI "系统正在重启..."
            reboot
        else
            LOGW "操作完成，请稍后手动执行 'reboot' 重启系统以加载 BBR v3 内核。"
            before_bbr_menu
        fi
    else
        LOGE "内核安装或引导配置失败！请检查系统状态，暂勿重启以防引导问题。"
        before_bbr_menu
    fi
}

bbr_v3_install_latest() {
    bbr_v3_assert_env || { before_bbr_menu; return 1; }

    echo -e "
╔────────────────────────────────────────────────╗
│           请选择要安装的 BBR v3 内核版本       │
│────────────────────────────────────────────────│
│   ${green}1.${plain} BBR v3 标准版 (推荐日常稳定使用)          │
│   ${green}2.${plain} BBR v3 Max 激进吞吐版 (极限测速与实验)    │
│   ${green}0.${plain} 取消安装                                  │
╚────────────────────────────────────────────────╝"
    read -rp "请输入选项 [0-2，默认 1]: " profile_choice
    profile_choice="${profile_choice:-1}"
    local profile="standard"
    if [[ "$profile_choice" == "2" ]]; then
        profile="max"
    elif [[ "$profile_choice" == "0" ]]; then
        bbr_menu
        return 0
    fi

    LOGI "正在从 GitHub 获取 BBR v3 最新 Release 信息..."
    local release_json
    release_json=$(curl -fsSL "$BBR_GITHUB_API")
    if [[ -z "$release_json" ]]; then
        LOGW "直接连接 GitHub 失败，尝试备用接口..."
        release_json=$(curl -fsSL "https://ghproxy.net/${BBR_GITHUB_API}")
    fi

    if [[ -z "$release_json" ]]; then
        LOGE "获取 GitHub Releases 信息失败，请检查网络连接。"
        before_bbr_menu
        return 1
    fi

    local arch=$(uname -m)
    local arch_filter="x86_64"
    [[ "$arch" == "aarch64" ]] && arch_filter="arm64"

    local latest_tag
    latest_tag=$(echo "$release_json" | jq -r --arg filter "$arch_filter" --arg prof "$profile" '
        map(
            select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
            | select(if $prof == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
        )
        | sort_by(.published_at)
        | .[-1].tag_name
    ')

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        LOGE "未检索到适用于架构 ${arch} 的 BBR v3 (${profile}) 内核版本！"
        before_bbr_menu
        return 1
    fi

    LOGI "匹配到最新可用版本: ${latest_tag}"
    confirm "是否开始下载并安装此版本？" "y" || { bbr_menu; return 0; }
    bbr_v3_download_and_install "$release_json" "$latest_tag"
}

bbr_v3_install_specific() {
    bbr_v3_assert_env || { before_bbr_menu; return 1; }

    LOGI "正在检索所有可用 BBR v3 版本列表..."
    local release_json
    release_json=$(curl -fsSL "$BBR_GITHUB_API")
    if [[ -z "$release_json" ]]; then
        release_json=$(curl -fsSL "https://ghproxy.net/${BBR_GITHUB_API}")
    fi
    if [[ -z "$release_json" ]]; then
        LOGE "获取版本信息失败，请检查网络连接。"
        before_bbr_menu
        return 1
    fi

    local arch=$(uname -m)
    local arch_filter="x86_64"
    [[ "$arch" == "aarch64" ]] && arch_filter="arm64"

    local tag_list
    tag_list=$(echo "$release_json" | jq -r --arg filter "$arch_filter" '
        .[]
        | select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
        | .tag_name
    ')

    if [[ -z "$tag_list" ]]; then
        LOGE "未找到适用于当前架构 (${arch}) 的版本。"
        before_bbr_menu
        return 1
    fi

    echo -e "
╔────────────────────────────────────────────────╗
│           适用于当前架构的可安装版本           │
│────────────────────────────────────────────────│"
    local tags=()
    local idx=1
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        tags+=("$tag")
        echo -e "   ${green}${idx}.${plain} ${tag}"
        idx=$((idx + 1))
    done <<< "$tag_list"
    echo -e "   ${green}0.${plain} 返回
╚────────────────────────────────────────────────╝"

    read -rp "请输入要安装的版本编号 [0-${#tags[@]}]: " tag_choice
    if [[ "$tag_choice" == "0" || -z "$tag_choice" ]]; then
        bbr_menu
        return 0
    fi
    if ! [[ "$tag_choice" =~ ^[0-9]+$ ]] || (( tag_choice < 1 || tag_choice > ${#tags[@]} )); then
        LOGE "输入编号无效！"
        before_bbr_menu
        return 1
    fi

    local selected_tag="${tags[$((tag_choice - 1))]}"
    LOGI "已选择版本: ${selected_tag}"
    confirm "确认下载并安装 ${selected_tag}？" "y" || { bbr_menu; return 0; }
    bbr_v3_download_and_install "$release_json" "$selected_tag"
}

bbr_v3_uninstall() {
    bbr_v3_assert_env || { before_bbr_menu; return 1; }

    local installed_pkgs
    installed_pkgs=$(dpkg -l 2>/dev/null | grep "joeyblog" | awk '{print $2}' | tr '\n' ' ')
    if [[ -z "$installed_pkgs" ]]; then
        LOGW "系统中未检测到安装过的 BBR v3 (joeyblog) 内核包。"
        before_bbr_menu
        return 0
    fi

    LOGW "检测到以下已安装的内核包:\n${installed_pkgs}"
    confirm "是否确认卸载这些 BBR v3 内核包并恢复系统默认内核？" "n" || { bbr_menu; return 0; }

    LOGI "正在卸载 BBR v3 内核包..."
    apt-get remove --purge -y $installed_pkgs
    bbr_v3_update_bootloader
    LOGI "✔ 内核包卸载完成！"
    confirm "需要重启系统以切换回原有内核，是否立即重启？" "y"
    if [[ $? == 0 ]]; then
        reboot
    else
        LOGW "请记得稍后手动执行 'reboot' 重启系统。"
        before_bbr_menu
    fi
}

bbr_apply_security_mitigations() {
    LOGI "正在应用 Linux 内核漏洞缓解策略 (Dirty Frag 等)..."
    mkdir -p /etc/modprobe.d
    touch "$XUI_SECURITY_MODPROBE"

    local rules=(
        "blacklist esp4"
        "install esp4 /bin/false"
        "blacklist esp6"
        "install esp6 /bin/false"
        "blacklist rxrpc"
        "install rxrpc /bin/false"
    )
    for r in "${rules[@]}"; do
        if ! grep -Fqx "$r" "$XUI_SECURITY_MODPROBE" 2>/dev/null; then
            echo "$r" >> "$XUI_SECURITY_MODPROBE"
        fi
    done

    for mod in esp4 esp6 rxrpc; do
        if lsmod 2>/dev/null | grep -q "^$mod"; then
            modprobe -r "$mod" 2>/dev/null || true
        fi
    done

    LOGI "✔ 安全策略已写入: ${XUI_SECURITY_MODPROBE}，隐患模块已禁用或卸载。"
    before_bbr_menu
}

bbr_menu() {
    local kernel_ver arch virt cur_algo cur_qdisc bbr_status tuning_status
    kernel_ver=$(uname -r)
    arch=$(uname -m)
    virt=$(bbr_detect_virt)
    cur_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

    local mod_ver
    mod_ver=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2}')
    if [[ "$cur_algo" == "bbr" ]]; then
        if [[ "$mod_ver" == "3" ]] || [[ "$kernel_ver" =~ (bbrv3|joeyblog) ]]; then
            bbr_status="${green}BBR v3 (已启用)${plain}"
        else
            bbr_status="${green}原生 BBR (已启用)${plain}"
        fi
    else
        bbr_status="${yellow}未启用 (${cur_algo})${plain}"
    fi

    if [[ -f "$XUI_BBR_SYSCTL" ]]; then
        if grep -q "1073741824" "$XUI_BBR_SYSCTL" 2>/dev/null; then
            tuning_status="${green}极限测速模式${plain}"
        elif grep -q "tcp_limit_output_bytes" "$XUI_BBR_SYSCTL" 2>/dev/null; then
            tuning_status="${green}亚太/跨国 TCP 调优${plain}"
        else
            tuning_status="${green}基础 BBR${plain}"
        fi
    elif [[ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]]; then
        tuning_status="${green}基础 BBR (旧版)${plain}"
    else
        tuning_status="${yellow}系统默认配置${plain}"
    fi

    echo -e "
╔────────────────────────────────────────────────╗
│          ${green}3X-UI BBR 网络加速与内核管理${plain}          │
│────────────────────────────────────────────────│
│  系统架构: ${green}${arch}${plain}       虚拟环境: ${green}${virt}${plain}
│  当前内核: ${green}${kernel_ver}${plain}
│  拥塞算法: ${bbr_status}     队列算法: ${green}${cur_qdisc}${plain}
│  优化状态: ${tuning_status}
│────────────────────────────────────────────────│
│  ${green}【通用调优 (免换内核/支持所有环境)】${plain}          │
│   ${green}1.${plain} 一键开启系统原生 BBR 加速                   │
│   ${green}2.${plain} 切换队列调度算法 (FQ / Cake / CoDel)        │
│   ${green}3.${plain} 应用亚太/跨国线路 TCP 智能调优             │
│   ${green}4.${plain} 智能带宽与延迟缓冲优化 (结合测速/延迟)     │
│   ${green}5.${plain} 启用极限测速挑战模式 (榨干带宽吞吐)         │
│   ${green}6.${plain} 清空网络优化配置 (恢复系统默认参数)         │
│────────────────────────────────────────────────│
│  ${green}【BBR v3 内核管理 (仅限 Debian/Ubuntu KVM)】${plain}   │
│   ${green}7.${plain} 安装 / 更新 BBR v3 最新内核                │
│   ${green}8.${plain} 选择指定版本安装 BBR v3 内核               │
│   ${green}9.${plain} 卸载已安装的 BBR v3 内核                   │
│  ${green}10.${plain} Linux 内核安全加固 (Dirty Frag 缓解)       │
│────────────────────────────────────────────────│
│   ${green}0.${plain} 返回主菜单                                │
╚────────────────────────────────────────────────╝"

    read -rp "请输入选项 [0-10]: " bbr_choice
    case "$bbr_choice" in
        0) show_menu ;;
        1) bbr_enable_native ;;
        2) bbr_switch_qdisc_menu ;;
        3) bbr_apply_apac_tuning ;;
        4) bbr_apply_smart_tuning ;;
        5) bbr_apply_extreme_tuning ;;
        6) bbr_clear_all_tuning ;;
        7) bbr_v3_install_latest ;;
        8) bbr_v3_install_specific ;;
        9) bbr_v3_uninstall ;;
        10) bbr_apply_security_mitigations ;;
        *)
            LOGE "无效选项，请输入 0-10 之间的数字！"
            bbr_menu
            ;;
    esac
}

enable_bbr() {
    bbr_enable_native
}

disable_bbr() {
    bbr_clear_all_tuning
}

update_shell() {
    curl -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh
    cp -f /usr/bin/x-ui ${xui_folder}/x-ui.sh > /dev/null 2>&1 || true
    chmod +x ${xui_folder}/x-ui.sh
    chmod +x /usr/bin/x-ui
    if [[ $? != 0 ]]; then
        echo ""
        LOGE "下载脚本失败，请检查服务器是否能正常访问 GitHub"
        before_show_menu
    else
        LOGI "脚本升级成功，请重新运行脚本"
        before_show_menu
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已安装，请勿重复安装"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "面板状态: ${green}正在运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "面板状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "面板状态: ${red}未安装${plain}"
            ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "开机自启: ${green}已启用${plain}"
    else
        echo -e "开机自启: ${red}未启用${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "Xray 状态: ${green}正在运行${plain}"
    else
        echo -e "Xray 状态: ${red}未运行${plain}"
    fi
}

firewall_menu() {
    echo -e "${green}\t1.${plain} ${green}Install${plain} Firewall"
    echo -e "${green}\t2.${plain} 端口放行列表 (带编号)"
    echo -e "${green}\t3.${plain} ${green}Open${plain} Ports"
    echo -e "${green}\t4.${plain} ${red}删除${plain} 放行端口规则"
    echo -e "${green}\t5.${plain} ${green}Enable${plain} Firewall"
    echo -e "${green}\t6.${plain} ${red}Disable${plain} Firewall"
    echo -e "${green}\t7.${plain} 防火墙运行状态"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "Choose an option: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "检测到未安装 ufw 防火墙，正在安装..."
        apt-get update
        apt-get install -y ufw
    else
        echo "ufw 防火墙已安装"
    fi

    # Check if the firewall is inactive
    if ufw status | grep -q "Status: active"; then
        echo "防火墙已处于激活状态"
    else
        echo "正在激活防火墙..."
        # Open the necessary ports
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort
        ufw allow 2096/tcp #subport

        # Enable the firewall
        ufw --force enable
    fi
}

open_ports() {
    # Prompt the user to enter the ports they want to open
    read -rp "请输入要开放的端口 (例如 80,443,2053 或范围 400-500): " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "错误: 输入无效，请输入以逗号分隔的端口列表或端口范围 (例如 80,443,2053 或 400-500)。" >&2
        exit 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Open the port range
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "已成功开放指定端口:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Display current rules with numbers
    echo "当前 UFW 防火墙规则:"
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "请选择删除规则的方式:"
    echo "1) 按规则编号删除"
    echo "2) Ports"
    read -rp "请输入您的选择 (1 或 2): " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "请输入要删除的规则编号 (例如 1, 2 等): " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "错误: 输入无效，请输入以逗号分隔的规则编号列表。" >&2
            exit 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "Failed to delete rule number $rule_number"
        done

        echo "所选规则已成功删除。"

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "请输入要关闭删除的端口 (例如 80,443,2053 或 400-500): " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "错误: 输入无效，请输入以逗号分隔的端口列表或端口范围 (例如 80,443,2053 或 400-500)。" >&2
            exit 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Delete the port range
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "已成功关闭并删除指定端口规则:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}错误:${plain} 选择无效，请输入 1 或 2。" >&2
        exit 1
    fi
}

update_all_geofiles() {
    update_geofiles "main"
    update_geofiles "IR"
    update_geofiles "RU"
    update_geofiles "MYAI"
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
        "MYAI")
            curl -fLRo ${xui_folder}/bin/geosite_myai.dat \
                https://raw.githubusercontent.com/lgdglgc/3x-ui/main/geosite_myai.dat
            return 0
            ;;
    esac
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        curl -fLRo ${xui_folder}/bin/${dat}.dat -z ${xui_folder}/bin/${dat}.dat \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat
    done
}

update_geo() {
    echo -e "${green}\t1.${plain} 全球常规规则库 Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} 伊朗地区规则库 chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} 俄罗斯地区规则库 runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} AI 专属分流规则库 MyAI (geosite_myai.dat)"
    echo -e "${green}\t5.${plain} 更新全部规则库 (包含 MyAI 及所有规则)"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请输入选项序号 [0-5]: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            update_geofiles "main"
            echo -e "${green}Loyalsoldier 规则库更新成功！${plain}"
            restart
            ;;
        2)
            update_geofiles "IR"
            echo -e "${green}chocolate4u 规则库更新成功！${plain}"
            restart
            ;;
        3)
            update_geofiles "RU"
            echo -e "${green}runetfreedom 规则库更新成功！${plain}"
            restart
            ;;
        4)
            update_geofiles "MYAI"
            echo -e "${green}MyAI 规则库更新成功！${plain}"
            restart
            ;;
        5)
            update_all_geofiles
            echo -e "${green}所有 Geo 资源文件已成功更新！${plain}"
            restart
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

install_acme() {
    # Check if acme.sh is already installed
    if command -v ~/.acme.sh/acme.sh &> /dev/null || [ -f "$HOME/.acme.sh/acme.sh" ]; then
        LOGI "acme.sh 已安装。"
        return 0
    fi

    LOGI "正在安装 acme.sh..."
    cd ~ || return 1 # Ensure you can change to the home directory

    curl -sL https://get.acme.sh | sh
    if [ $? -ne 0 ] || ! [ -f "$HOME/.acme.sh/acme.sh" ]; then
        LOGW "acme.sh 官方源下载失败或超时，正在切换镜像源..."
        curl -sL https://mirror.ghproxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh
    fi

    if [ -f "$HOME/.acme.sh/acme.sh" ] || command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "Installation of acme.sh succeeded."
        return 0
    else
        LOGE "Installation of acme.sh failed."
        return 1
    fi
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} 申请 SSL 证书 (域名验证)"
    echo -e "${green}\t2.${plain} 吊销证书"
    echo -e "${green}\t3.${plain} 强制续签"
    echo -e "${green}\t4.${plain} 查看已申请域名及证书路径"
    echo -e "${green}\t5.${plain} 配置面板的证书路径"
    echo -e "${green}\t6.${plain} 申请 IP 地址 SSL 证书 (6天有效期，自动续签)"
    echo -e "${green}\t0.${plain} 返回主菜单"

    read -rp "请选择一个选项: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            ssl_cert_issue
            ssl_cert_issue_main
            ;;
        2)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                echo "未找到可吊销的证书。"
            else
                echo "已存在的域名:"
                echo "$domains"
                read -rp "请输入列表中要吊销证书的域名: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --revoke -d ${domain}
                    LOGI "已成功吊销域名 $domain 的证书"
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        3)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                echo "未找到可续签的证书。"
            else
                echo "已存在的域名:"
                echo "$domains"
                read -rp "请输入列表中要续签证书的域名: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --renew -d ${domain} --force
                    LOGI "已成功强制续签域名 $domain 的证书"
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        4)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                echo "未找到任何证书。"
            else
                echo "已有域名及其证书路径:"
                for domain in $domains; do
                    local cert_path="/root/cert/${domain}/fullchain.pem"
                    local key_path="/root/cert/${domain}/privkey.pem"
                    if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                        echo -e "域名: ${domain}"
                        echo -e "\t证书文件路径: ${cert_path}"
                        echo -e "\t私钥文件路径: ${key_path}"
                    else
                        echo -e "域名: ${domain} - 证书或私钥文件缺失。"
                    fi
                done
            fi
            ssl_cert_issue_main
            ;;
        5)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
            if [ -z "$domains" ]; then
                echo "未找到任何证书。"
            else
                echo "可选域名:"
                echo "$domains"
                read -rp "请选择一个域名以配置面板路径: " domain

                if echo "$domains" | grep -qw "$domain"; then
                    local webCertFile="/root/cert/${domain}/fullchain.pem"
                    local webKeyFile="/root/cert/${domain}/privkey.pem"

                    if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                        echo "已成功为域名 $domain 配置面板证书路径"
                        echo "  - 证书文件: $webCertFile"
                        echo "  - 私钥文件: $webKeyFile"
                        restart
                    else
                        echo "错误: 未找到域名 $domain 的证书或私钥文件。"
                    fi
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        6)
            echo -e "${yellow}Let's Encrypt 公网 IP 地址 SSL 证书申请${plain}"
            echo -e "此操作将使用 Let's Encrypt 短效模式为您的服务器公网 IP 申请 SSL 证书。"
            echo -e "${yellow}证书有效期约为 6 天，将通过 acme.sh 自动续签。${plain}"
            echo -e "${yellow}必须向外网开放 80 端口以完成验证。${plain}"
            confirm "您确定要继续吗？" "y"
            if [[ $? == 0 ]]; then
                ssl_cert_issue_for_ip
            fi
            ssl_cert_issue_main
            ;;

        *)
            echo -e "${red}选项无效。请输入正确的选项数字。${plain}\n"
            ssl_cert_issue_main
            ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "正在开始为服务器 IP 自动生成 SSL 证书..."
    LOGI "使用 Let's Encrypt 短效证书模式 (约 6 天有效期，自动续签)"

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

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
        LOGI "无法从任何接口服务自动检测服务器的公网 IP。"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入您服务器's 的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                LOGE "无效的 IPv4 地址，请重新输入。"
                server_ip=""
            fi
        done
    fi

    LOGI "检测到服务器 IP: ${server_ip}"

    # Ask for optional IPv6
    local ipv6_addr=""
    read -rp "是否包含 IPv6 地址？(留空则跳过): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Trim whitespace

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "未找到 acme.sh，正在安装..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme.sh 失败"
            return 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "不支持自动安装 socat 的操作系统"
            ;;
    esac

    # Create certificate directory
    certPath="/root/cert/ip"
    mkdir -p "$certPath"

    # Build domain arguments
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "包含 IPv6 地址: ${ipv6_addr}"
    fi

    # Choose port for HTTP-01 listener (default 80, allow override)
    local WebPort=""
    read -rp "请输入用于 ACME HTTP-01 验证的端口 (默认 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        LOGE "输入端口无效，回退使用端口 80。"
        WebPort=80
    fi
    LOGI "使用端口 ${WebPort} 为 IP ${server_ip} 申请证书"
    if [[ "${WebPort}" -ne 80 ]]; then
        LOGI "提示: Let's Encrypt 仍会尝试连接 80 端口；请确保外网 80 端口已转发至 ${WebPort}。"
    fi

    while true; do
        if is_port_in_use "${WebPort}"; then
            LOGI "端口 ${WebPort} 已被占用。"

            local alt_port=""
            read -rp "请输入另一个端口用于 acme.sh 监听 (留空则终止): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "端口 ${WebPort} 繁忙，无法继续申请。"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "输入的端口无效。"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            LOGI "端口 ${WebPort} 空闲，可用于独立式验证。"
            break
        fi
    done

    # Reload command - restarts panel after renewal
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"

    # issue the certificate for IP with shortlived profile
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        LOGE "为 IP ${server_ip} 申请证书失败"
        LOGE "请确保端口 ${WebPort} 已开放且服务器可从外网访问"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    else
        LOGI "为 IP ${server_ip} 成功申请证书！"
    fi

    # Install the certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "安装后未找到证书文件"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    fi

    LOGI "证书文件安装成功"

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Prompt user to set panel paths after successful certificate installation
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"

    read -rp "是否将此证书应用于面板配置？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "已成功为 IP $server_ip 配置面板证书路径"
            LOGI "  - 证书文件: $webCertFile"
            LOGI "  - 私钥文件: $webKeyFile"
            LOGI "  - 有效期: 约 6 天 (通过 acme.sh 自动续签)"
            echo -e "${green}访问 URL: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            LOGI "正在重启面板以应用 SSL 证书..."
            restart
        else
            LOGE "错误: 未找到 IP $server_ip 的证书或私钥文件。"
            return 1
        fi
    else
        LOGI "已跳过面板证书路径配置。"
    fi

    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未找到 acme.sh，即将开始安装"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme.sh 失败，请检查日志"
            exit 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf -y update > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "当前系统不支持自动安装 socat，请手动安装"
            ;;
    esac
    if [ $? -ne 0 ]; then
        LOGE "安装 socat 失败，请检查日志"
        exit 1
    else
        LOGI "安装 socat 成功..."
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
            LOGE "域名格式无效: ${domain}，请输入有效的域名。"
            continue
        fi

        break
    done
    LOGD "您设定的域名为: ${domain}，正在检测 DNS 解析..."
    SSL_ISSUED_DOMAIN="${domain}"

    # DNS check
    local public_ip=$(get_public_ip)
    local resolved_ip=$(resolve_domain "${domain}")
    if [[ -n "${public_ip}" && -n "${resolved_ip}" ]]; then
        if [[ "${public_ip}" != "${resolved_ip}" ]]; then
            LOGW "警告: 您的域名解析至 IP ${resolved_ip}，而服务器公网 IP 为 ${public_ip}。"
            LOGW "请确认域名的 DNS A 记录已正确指向本服务器的公网 IP。"
            confirm "是否仍然继续尝试申请证书？" "n"
            if [[ $? -ne 0 ]]; then
                return 1
            fi
        else
            LOGI "域名 DNS 解析校验通过 (解析为 ${resolved_ip})。"
        fi
    elif [[ -z "${resolved_ip}" ]]; then
        LOGW "警告: 无法解析域名 ${domain} 的 IP 地址。"
        LOGW "请检查域名的 DNS 配置是否正确且已生效生效。"
        confirm "是否仍然继续尝试申请证书？" "n"
        if [[ $? -ne 0 ]]; then
            return 1
        fi
    fi

    # detect existing certificate and reuse it if present
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        LOGI "检测到域名 ${domain} 已存在有效证书，将直接复用。"
        [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
    else
        LOGI "域名准备就绪，即将开始申请证书..."
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
    local input_port=""
    read -rp "请选择用于验证的端口 (默认 80): " input_port
    [[ -n "${input_port}" ]] && WebPort="${input_port}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "您输入的端口 ${WebPort} 无效，将使用默认端口 80。"
        WebPort=80
    fi
    LOGI "将使用端口 ${WebPort} 申请证书，请确保该端口防火墙已放行。"

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

    if is_port_in_use "${WebPort}"; then
        LOGW "警告: 检测到端口 ${WebPort} 仍被其他进程占用！"
        if command -v ss >/dev/null 2>&1; then
            LOGW "占用详情: $(ss -lptn "sport = :${WebPort}" 2>/dev/null | tail -n +2 | tr '\n' ' ')"
        elif command -v lsof >/dev/null 2>&1; then
            LOGW "占用进程: $(lsof -nP -iTCP:${WebPort} -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $1\"(PID:\"$2\")\"}' | head -n 3 | tr '\n' ' ')"
        fi
        confirm "是否尝试强制结束占用该端口的进程以继续？" "n"
        if [ $? -eq 0 ]; then
            if command -v fuser >/dev/null 2>&1; then
                fuser -k -n tcp ${WebPort} >/dev/null 2>&1
            fi
            sleep 1
        fi
    fi

    # Temporarily open firewall port
    fw_type=$(manage_firewall_port "open" "${WebPort}")

    local issue_status=1

    if [[ ${cert_exists} -eq 0 ]]; then
        # Ask for email to register account
        local email="admin@${domain}"
        read -rp "请输入用于注册 ACME 的邮箱 (默认: admin@${domain}): " user_email
        email="${user_email:-$email}"

        # Check if the server has IPv6 interface
        local use_ipv6=""
        if ip -6 addr show | grep -q "inet6" | grep -qv "lo"; then
            use_ipv6="--listen-v6"
            LOGI "检测到 IPv6 接口，开启 IPv6 独立监听..."
        fi

        # Issue the certificate - try Let's Encrypt first
        LOGI "正在使用邮箱 ${email} 注册 Let's Encrypt 账户..."
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --register-account -m "${email}" --server letsencrypt
        
        LOGI "正在通过 Let's Encrypt 申请证书..."
        ~/.acme.sh/acme.sh --issue -d ${domain} ${use_ipv6} --standalone --httpport ${WebPort} --force
        
        if [ $? -eq 0 ]; then
            LOGI "通过 Let's Encrypt 申请证书成功！"
            issue_status=0
        else
            LOGE "通过 Let's Encrypt 申请证书失败。"
            confirm "是否改用备用 CA (ZeroSSL) 进行申请？" "y"
            if [ $? -eq 0 ]; then
                LOGI "正在使用邮箱 ${email} 注册 ZeroSSL 账户..."
                ~/.acme.sh/acme.sh --set-default-ca --server zerossl --force
                ~/.acme.sh/acme.sh --register-account -m "${email}" --server zerossl
                
                LOGI "正在通过 ZeroSSL 申请证书..."
                ~/.acme.sh/acme.sh --issue -d ${domain} ${use_ipv6} --standalone --httpport ${WebPort} --force
                if [ $? -eq 0 ]; then
                    LOGI "通过 ZeroSSL 申请证书成功！"
                    issue_status=0
                else
                    LOGE "通过 ZeroSSL 申请证书同样失败。"
                fi
            fi
        fi

        if [[ ${issue_status} -ne 0 ]]; then
            LOGE "所有证书申请尝试均已失败，请检查上方日志。"
            rm -rf ~/.acme.sh/${domain}
            restore_env
            trap - INT TERM EXIT
            exit 1
        else
            LOGI "证书申请成功，正在安装证书文件..."
        fi
    else
        LOGI "使用已有证书，正在安装证书文件..."
        issue_status=0
    fi

    # Restore port/firewall environment before panel restart to avoid port conflicts
    restore_env
    trap - INT TERM EXIT

    reloadCmd="x-ui restart"

    LOGI "ACME 默认重载命令为: ${yellow}x-ui restart"
    LOGI "该命令将在每次证书申请或自动续签成功后执行。"
    read -rp "是否需要自定义修改 ACME 的重载命令？(y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; x-ui restart (适用于 Nginx 反代)"
        echo -e "${green}\t2.${plain} 自定义输入命令"
        echo -e "${green}\t0.${plain} 保持默认重载命令"
        read -rp "Choose an option: " choice
        case "$choice" in
            1)
                LOGI "重载命令已设置为: systemctl reload nginx ; x-ui restart"
                reloadCmd="systemctl reload nginx ; x-ui restart"
                ;;
            2)
                LOGD "It's recommended to put x-ui restart at the end, so it won't raise an error if other services fails"
                read -rp "请输入您的自定义重载命令: " reloadCmd
                LOGI "设定的重载命令是: ${reloadCmd}"
                ;;
            *)
                LOGI "保持默认重载命令"
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
        LOGI "证书安装成功，正在开启自动续签..."
    else
        LOGE "证书安装失败，操作退出。"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        exit 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "开启自动续签失败，证书详情如下:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        LOGI "开启自动续签成功，证书详情如下:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Prompt user to set panel paths after successful certificate installation
    read -rp "是否将此证书应用于当前面板？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "已为域名 $domain 设置面板证书路径"
            LOGI "  - 证书公钥文件: $webCertFile"
            LOGI "  - 证书私钥文件: $webKeyFile"
            echo -e "${green}访问链接: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "错误: 未找到域名 $domain 的证书或私钥文件。"
        fi
    else
        LOGI "跳过为面板配置证书路径。"
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** 使用说明 ******"
    LOGI "请按照以下步骤完成申请流程:"
    LOGI "1. 准备 Cloudflare API Token (推荐，权限设为 Zone:DNS:Edit) 或 Global API Key + 注册邮箱。"
    LOGI "2. 准备需申请证书的域名。"
    LOGI "3. 证书签发完成后，可选择是否直接配置给当前面板。"
    LOGI "4. 脚本会在安装后自动配置证书到期自动续签。"

    confirm "您是否已确认以上信息并继续操作？[y/n]" "y"

    if [ $? -eq 0 ]; then
        # Check for acme.sh first
        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            echo "未找到 acme.sh，即将开始安装。"
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "安装 acme.sh 失败，请查看日志。"
                exit 1
            fi
        fi

        CF_Domain=""

        LOGD "请输入域名:"
        read -rp "请输入域名: " CF_Domain
        LOGD "设定的域名为: ${CF_Domain}"

        # Cloudflare API credentials: an API Token (recommended, scoped to a
        # single zone) or the account-wide Global API Key. acme.sh reads
        # CF_Token for tokens, or CF_Key + CF_Email for the Global Key.
        CF_KeyType=""
        read -rp "您使用的是 Cloudflare API Token 还是 Global API Key？(t/g) [默认 t]: " CF_KeyType
        CF_KeyType=${CF_KeyType:-t}

        if [[ "$CF_KeyType" == "g" || "$CF_KeyType" == "G" ]]; then
            CF_GlobalKey=""
            CF_AccountEmail=""
            LOGD "请输入 Global API Key:"
            read -rp "请输入 Key: " CF_GlobalKey
            LOGD "请输入 Cloudflare 注册邮箱:"
            read -rp "请输入邮箱: " CF_AccountEmail
            export CF_Key="${CF_GlobalKey}"
            export CF_Email="${CF_AccountEmail}"
        else
            CF_ApiToken=""
            LOGD "请输入 API Token:"
            read -rp "请输入 Token: " CF_ApiToken
            export CF_Token="${CF_ApiToken}"
        fi

        # Set the default CA to Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            LOGE "Default CA, Let'sEncrypt fail, script exiting..."
            exit 1
        fi

        # Register CA account
        local email="admin@${CF_Domain}"
        read -rp "请输入用于注册 ACME 的邮箱 (默认: admin@${CF_Domain}): " user_email
        email="${user_email:-$email}"
        LOGI "正在使用邮箱 ${email} 注册 Let's Encrypt 账户..."
        ~/.acme.sh/acme.sh --register-account -m "${email}" --server letsencrypt

        # Issue the certificate using Cloudflare DNS
        local issue_status=1
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -eq 0 ]; then
            issue_status=0
        else
            LOGE "通过 Let's Encrypt 申请证书失败。"
            confirm "是否改用备用 CA (ZeroSSL) 进行申请？" "y"
            if [ $? -eq 0 ]; then
                ~/.acme.sh/acme.sh --set-default-ca --server zerossl --force
                LOGI "正在使用邮箱 ${email} 注册 ZeroSSL 账户..."
                ~/.acme.sh/acme.sh --register-account -m "${email}" --server zerossl
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
                if [ $? -eq 0 ]; then
                    issue_status=0
                fi
            fi
        fi

        if [ ${issue_status} -ne 0 ]; then
            LOGE "证书申请失败，脚本退出..."
            exit 1
        else
            LOGI "证书申请成功，正在安装..."
        fi

        # Install the certificate
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            LOGE "创建目录失败: ${certPath}"
            exit 1
        fi

        reloadCmd="x-ui restart"

        LOGI "ACME 默认重载命令为: ${yellow}x-ui restart"
        LOGI "该命令将在每次证书申请或自动续签成功后执行。"
        read -rp "是否需要自定义修改 ACME 的重载命令？(y/n): " setReloadcmd
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; x-ui restart (适用于 Nginx 反代)"
            echo -e "${green}\t2.${plain} 自定义输入命令"
            echo -e "${green}\t0.${plain} 保持默认重载命令"
            read -rp "Choose an option: " choice
            case "$choice" in
                1)
                    LOGI "重载命令已设置为: systemctl reload nginx ; x-ui restart"
                    reloadCmd="systemctl reload nginx ; x-ui restart"
                    ;;
                2)
                    LOGD "It's recommended to put x-ui restart at the end, so it won't raise an error if other services fails"
                    read -rp "请输入您的自定义重载命令: " reloadCmd
                    LOGI "设定的重载命令是: ${reloadCmd}"
                    ;;
                *)
                    LOGI "保持默认重载命令"
                    ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"

        if [ $? -ne 0 ]; then
            LOGE "证书安装失败，脚本退出..."
            exit 1
        else
            LOGI "证书安装成功，正在开启自动续签更新..."
        fi

        # Enable auto-update
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "开启自动续签失败，脚本退出..."
            exit 1
        else
            LOGI "证书已安装且已启用自动续签，详细信息如下:"
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Prompt user to set panel paths after successful certificate installation
        read -rp "是否将此证书应用于当前面板？(y/n): " setPanel
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "已为域名 $CF_Domain 设置面板证书路径"
                LOGI "  - 证书公钥文件: $webCertFile"
                LOGI "  - 证书私钥文件: $webKeyFile"
                echo -e "${green}访问链接: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                restart
            else
                LOGE "错误: 未找到域名 $CF_Domain 的证书或私钥文件。"
            fi
        else
            LOGI "跳过为面板配置证书路径。"
        fi
    else
        show_menu
    fi
}

run_speedtest() {
    # Check if Speedtest is already installed
    if ! command -v speedtest &> /dev/null; then
        # If not installed, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "正在通过 snap 安装 Speedtest..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "错误: 未找到支持的包管理器，您可能需要手动安装 Speedtest。"
                return 1
            else
                echo "正在通过 $pkg_manager 安装 Speedtest..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} 安装 Fail2ban 并配置 IP 限制"
    echo -e "${green}\t2.${plain} 修改封禁时长"
    echo -e "${green}\t3.${plain} 解封所有用户"
    echo -e "${green}\t4.${plain} 查看封禁日志"
    echo -e "${green}\t5.${plain} Ban an IP Address"
    echo -e "${green}\t6.${plain} Unban an IP Address"
    echo -e "${green}\t7.${plain} 实时监控日志"
    echo -e "${green}\t8.${plain} Fail2ban 服务状态"
    echo -e "${green}\t9.${plain} 重启 Fail2ban 服务"
    echo -e "${green}\t10.${plain} 卸载 Fail2ban 与 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "Choose an option: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            confirm "确认安装 Fail2ban 并配置 IP 限制？" "y"
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            read -rp "请输入新的封禁时长 (分钟) [默认 30]: " NUM
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                echo -e "${red}${NUM} 不是有效数字！请重新输入。${plain}"
            fi
            iplimit_main
            ;;
        3)
            confirm "确认从 IP Limit 规则中解封所有 IP？" "y"
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                echo -e "${green}所有用户 IP 已成功解封。${plain}"
                iplimit_main
            else
                echo -e "${yellow}Cancelled.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            read -rp "请输入要手动封禁的 IP 地址: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                echo -e "${green}IP 地址 ${ban_ip} 已成功封禁。${plain}"
            else
                echo -e "${red}IP 地址格式无效！请重新输入。${plain}"
            fi
            iplimit_main
            ;;
        6)
            read -rp "请输入要解封的 IP 地址: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                echo -e "${green}IP 地址 ${unban_ip} 已成功解封。${plain}"
            else
                echo -e "${red}IP 地址格式无效！请重新输入。${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            iplimit_main
            ;;
    esac
}

install_iplimit() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}检测到 Fail2ban 未安装，正在开始安装...!${plain}\n"

        # Install fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 24 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                dnf -y update && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum update -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf -y update && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Syu --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}不支持的操作系统，请手动安装必要软件包。${plain}\n"
                exit 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban 安装失败。${plain}\n"
            exit 1
        fi

        echo -e "${green}Fail2ban 安装成功！${plain}\n"
    else
        echo -e "${yellow}Fail2ban 已经安装。${plain}\n"
    fi

    echo -e "${green}Configuring IP Limit...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP 限制功能已成功安装并配置完成！${plain}\n"
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} 仅移除 IP Limit 限制规则"
    echo -e "${green}\t2.${plain} 彻底卸载 Fail2ban 与 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "Choose an option: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP Limit 限制规则已成功移除！${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}不支持的操作系统，请手动卸载 Fail2ban。${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban 与 IP 限制已成功卸载！${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}正在检查封禁日志...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban 服务未在运行！${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban 服务未在运行！${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}fail2ban.log 中的最近封禁记录:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}No recent system ban activities found${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL 规则封禁日志条目:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}No ban entries found${plain}"
        else
            echo -e "${yellow}封禁日志文件为空${plain}"
        fi
    else
        echo -e "${red}未找到封禁日志文件: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}当前 Jail 规则状态:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Unable to get jail status${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ fail2ban's default backend should be changed to systemd
    if [[ "${release}" == "debian" && ${os_version} -ge 12 ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=1
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    echo -e "${green}IP Limit jail 规则已创建，封禁时长为 ${bantime} 分钟。${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}正在移除 (${file}) 中与 [3x-ipl] 冲突的配置！${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
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
        echo -e "${yellow}无法从任何接口服务自动检测到服务器 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入您服务器的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}无效的 IPv4 地址，请重新输入。${plain}"
                server_ip=""
            fi
        done
    fi

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}面板已启用 SSL 安全加密。${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}警告: 未找到证书与私钥！面板未受安全保护。${plain}"
        echo "建议申请证书或配置 SSH 端口转发以安全访问。"
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}当前 SSH 端口转发配置:${plain}"
        echo -e "标准 SSH 转发命令:"
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\n若使用 SSH 密钥:"
        echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\n连接建立后，通过以下地址访问面板:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\n请选择操作:"
    echo -e "${green}1.${plain} 设置监听 IP"
    echo -e "${green}2.${plain} 清除监听 IP"
    echo -e "${green}0.${plain} 返回主菜单"
    read -rp "请输入选项: " num

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                echo -e "\n当前未配置监听 IP (listenIP)。请选择:"
                echo -e "1. 使用默认本地回环 IP (127.0.0.1)"
                echo -e "2. Set a custom IP"
                read -rp "Select an option (1 or 2): " listen_choice

                config_listenIP="127.0.0.1"
                [[ "$listen_choice" == "2" ]] && read -rp "Enter custom IP to listen on: " config_listenIP

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                echo -e "${green}监听 IP 已设置为 ${config_listenIP}。${plain}"
                echo -e "\n${green}SSH 端口转发配置:${plain}"
                echo -e "标准 SSH 转发命令:"
                echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\n若使用 SSH 密钥:"
                echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\n连接建立后，通过以下地址访问面板:"
                echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                restart
            else
                config_listenIP="${existing_listenIP}"
                echo -e "${green}当前监听 IP 已设置为 ${config_listenIP}。${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            echo -e "${green}监听 IP 已成功清除。${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

# PostgreSQL service management (for panels configured with XUI_DB_TYPE=postgres).

postgresql_installed() {
    command -v pg_lsclusters > /dev/null 2>&1 || command -v psql > /dev/null 2>&1 || command -v postgres > /dev/null 2>&1
}

# Prints "VER CLUSTER" of the first configured cluster on Debian-style installs (e.g. "16 main").
pg_cluster_info() {
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters 2> /dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2; exit}'
    fi
}

# Resolves the systemd unit used to manage the PostgreSQL server.
pg_systemd_unit() {
    local info ver cluster
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        echo "postgresql@${ver}-${cluster}"
    else
        echo "postgresql"
    fi
}

postgresql_status() {
    if ! postgresql_installed; then
        LOGE "当前系统中未检测到已安装的 PostgreSQL。"
        return 1
    fi
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters
    else
        systemctl status "$(pg_systemd_unit)" --no-pager
    fi
    echo ""
    if command -v ss > /dev/null 2>&1; then
        local listening
        listening=$(ss -ltnp 2> /dev/null | grep ':5432')
        if [[ -n "$listening" ]]; then
            echo -e "${green}PostgreSQL is listening on port 5432:${plain}"
            echo "$listening"
        else
            echo -e "${red}5432 端口无服务监听 — PostgreSQL 数据库未在运行。${plain}"
        fi
    fi
}

postgresql_start() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql start
    else
        systemctl start "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_stop() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop
    else
        systemctl stop "$(pg_systemd_unit)"
    fi
    LOGI "PostgreSQL 停止信号已发送。"
}

postgresql_restart() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql restart
    else
        systemctl restart "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_enable() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-update add postgresql default
    else
        systemctl enable "$(pg_systemd_unit)"
    fi
    if [[ $? == 0 ]]; then
        LOGI "已设置 PostgreSQL 开机自启。"
    else
        LOGE "设置 PostgreSQL 开机自启失败。"
    fi
}

postgresql_log() {
    pg_require_installed || return 1
    local info ver cluster logfile
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        logfile="/var/log/postgresql/postgresql-${ver}-${cluster}.log"
    fi
    if [[ -n "$logfile" && -f "$logfile" ]]; then
        tail -n 40 "$logfile"
    elif command -v journalctl > /dev/null 2>&1; then
        journalctl -u "$(pg_systemd_unit)" -n 40 --no-pager
    else
        LOGE "未找到 PostgreSQL 日志文件。"
    fi
}

pg_require_installed() {
    if ! postgresql_installed; then
        LOGE "PostgreSQL 未安装，请先在菜单中选择选项 1 (安装 PostgreSQL)。"
        return 1
    fi
}

# Installs a local PostgreSQL server and creates a dedicated xui user/database.
# Progress goes to stderr; on success the connection DSN is printed to stdout so
# callers can capture it. Mirrors install_postgres_local() from install.sh, so the
# panel can be set up without re-running the remote install script.
pg_install_local() {
    local pg_user pg_pass pg_db pg_host pg_port
    pg_pass=$(gen_random_string 24)
    pg_db="xui"
    pg_host="127.0.0.1"
    pg_port="5432"

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
            echo -e "${red}当前系统暂不支持自动安装 PostgreSQL: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

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

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

# Installs the PostgreSQL client tools (pg_dump/pg_restore) used by in-panel backup.
pg_ensure_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}正在安装 PostgreSQL 客户端工具 (pg_dump/pg_restore)...${plain}" >&2
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

# Writes XUI_DB_TYPE/XUI_DB_DSN into the service env file, preserving other entries.
pg_write_env() {
    local dsn="$1" envfile
    envfile="$(xui_env_file_path)"
    install -d -m 755 "$(dirname "$envfile")"
    touch "$envfile"
    sed -i '/^XUI_DB_TYPE=/d; /^XUI_DB_DSN=/d' "$envfile"
    {
        echo "XUI_DB_TYPE=postgres"
        echo "XUI_DB_DSN=${dsn}"
    } >> "$envfile"
    chmod 600 "$envfile"
}

pg_install_server_action() {
    if postgresql_installed; then
        LOGI "系统中已检测到安装有 PostgreSQL。"
        confirm "是否仍然继续运行配置 (确保 xui 数据库与用户存在)？" "n" || return 0
    fi
    LOGI "正在安装 PostgreSQL 服务并创建专属用户与数据库..."
    local dsn
    dsn=$(pg_install_local)
    if [[ $? -ne 0 || -z "$dsn" ]]; then
        LOGE "PostgreSQL 安装失败。"
        return 1
    fi
    PG_LAST_DSN="$dsn"
    pg_ensure_client || LOGE "Could not install pg_dump/pg_restore (panel DB backup may be unavailable)."
    echo ""
    LOGI "PostgreSQL 已安装就绪。"
    echo -e "${green}连接 DSN:${plain} ${dsn}"
    echo -e "${yellow}可使用选项 2 将 SQLite 数据迁移至 PostgreSQL 并切换面板。${plain}"
}

# Copies the current SQLite data into PostgreSQL, then switches the panel over.
migrate_to_postgres() {
    if [[ ! -x "${xui_folder}/x-ui" ]]; then
        LOGE "x-ui 面板未安装。"
        return 1
    fi
    echo ""
    echo -e "${yellow}此操作将当前的 SQLite 数据复制到 PostgreSQL 数据库中，${plain}"
    echo -e "${yellow}然后切换面板至 PostgreSQL 并自动重启。${plain}"
    echo -e "${yellow}目标 PostgreSQL 数据库必须为空。${plain}"
    confirm "Continue?" "n" || return 0

    local dsn="" pg_mode
    if [[ -n "$PG_LAST_DSN" ]]; then
        echo -e "检测到当前会话中创建的 PostgreSQL 数据库:"
        echo -e "  ${green}${PG_LAST_DSN}${plain}"
        confirm "是否迁移数据至此数据库中？" "y" && dsn="$PG_LAST_DSN"
    fi

    if [[ -z "$dsn" ]]; then
        echo ""
        echo -e "${green}\t1.${plain} 本地安装 PostgreSQL 并创建专属用户/库 (推荐)"
        echo -e "${green}\t2.${plain} 使用现有的 PostgreSQL 服务 (输入 DSN)"
        read -rp "Choose [1]: " pg_mode
        pg_mode="${pg_mode:-1}"
        if [[ "$pg_mode" == "2" ]]; then
            while [[ -z "$dsn" ]]; do
                read -rp "请输入 PostgreSQL DSN 连接串 (postgres://user:pass@host:port/dbname?sslmode=disable): " dsn
                dsn="${dsn// /}"
            done
        else
            LOGI "正在本地安装 PostgreSQL (需要耗费少许时间)..."
            dsn=$(pg_install_local)
            if [[ $? -ne 0 || -z "$dsn" ]]; then
                LOGE "PostgreSQL 安装失败，已中止迁移。"
                return 1
            fi
            PG_LAST_DSN="$dsn"
        fi
    fi

    pg_ensure_client || LOGE "Could not install pg_dump/pg_restore (in-panel DB backup/restore may be unavailable)."

    LOGI "正在停止面板以获取一致性数据快照..."
    stop 0 > /dev/null 2>&1

    echo ""
    LOGI "正在迁移数据至 PostgreSQL..."
    if ! ${xui_folder}/x-ui migrate-db --dsn "$dsn"; then
        LOGE "迁移失败！面板未切换至 PostgreSQL。"
        start 0 > /dev/null 2>&1
        return 1
    fi

    pg_write_env "$dsn"
    LOGI "已将数据库配置写入 $(xui_env_file_path) (XUI_DB_TYPE=postgres)。"
    LOGI "正在使用 PostgreSQL 重启面板..."
    restart 0
    sleep 1
    if check_status; then
        LOGI "数据迁移完成！当前面板现已运行在 PostgreSQL 上。"
    else
        LOGE "面板未能正常启动。请通过选项 16 查看日志确认原因。您的原 SQLite 数据完好无损。"
    fi
}

postgresql_menu() {
    echo -e "${green}\t1.${plain} ${green}安装${plain} PostgreSQL (服务端 + 客户端 + xui 数据库)"
    echo -e "${green}\t2.${plain} 迁移 SQLite ${green}->${plain} PostgreSQL"
    echo -e "${green}\t3.${plain} 查看状态 (集群及 5432 端口)"
    echo -e "${green}\t4.${plain} ${green}启动${plain} PostgreSQL"
    echo -e "${green}\t5.${plain} ${red}停止${plain} PostgreSQL"
    echo -e "${green}\t6.${plain} 重启 PostgreSQL"
    echo -e "${green}\t7.${plain} ${green}启用${plain} 开机自启"
    echo -e "${green}\t8.${plain} 查看 PostgreSQL 日志"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择一个选项: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            pg_install_server_action
            postgresql_menu
            ;;
        2)
            migrate_to_postgres
            postgresql_menu
            ;;
        3)
            postgresql_status
            postgresql_menu
            ;;
        4)
            postgresql_start
            postgresql_menu
            ;;
        5)
            postgresql_stop
            postgresql_menu
            ;;
        6)
            postgresql_restart
            postgresql_menu
            ;;
        7)
            postgresql_enable
            postgresql_menu
            ;;
        8)
            postgresql_log
            postgresql_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入有效序号。${plain}\n"
            postgresql_menu
            ;;
    esac
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}x-ui 控制菜单使用方法 (命令行子命令):${plain}                 │
│                                                                │
│  ${blue}x-ui${plain}                       - 显示管理菜单 (管理脚本)          │
│  ${blue}x-ui start${plain}                 - 启动 x-ui 面板                   │
│  ${blue}x-ui stop${plain}                  - 停止 x-ui 面板                   │
│  ${blue}x-ui restart${plain}               - 重启 x-ui 面板                   │
│  ${blue}x-ui restart-xray${plain}          - 重启 Xray 内核                   │
│  ${blue}x-ui status${plain}                - 查看当前状态                     │
│  ${blue}x-ui settings${plain}              - 查看当前设置                     │
│  ${blue}x-ui enable${plain}                - 启用面板开机自启                 │
│  ${blue}x-ui disable${plain}               - 禁用面板开机自启                 │
│  ${blue}x-ui log${plain}                   - 查看面板运行日志                 │
│  ${blue}x-ui banlog${plain}                - 查看 Fail2ban 封禁日志           │
│  ${blue}x-ui update${plain}                - 更新 x-ui 面板                   │
│  ${blue}x-ui update-all-geofiles${plain}   - 更新所有 Geo 资源文件            │
│  ${blue}x-ui bbr${plain}                  - BBR 网络加速与内核管理            │
│  ${blue}x-ui legacy${plain}                - 切换历史版本                     │
│  ${blue}x-ui install${plain}               - 安装 x-ui 面板                   │
│  ${blue}x-ui uninstall${plain}             - 卸载 x-ui 面板                   │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}3X-UI 面板管理脚本 (已优化版)${plain}                 │
│   ${green}0.${plain} 退出脚本                                   │
│────────────────────────────────────────────────│
│   ${green}1.${plain} 安装面板                                   │
│   ${green}2.${plain} 更新面板                                   │
│   ${green}3.${plain} 更新脚本菜单                               │
│   ${green}4.${plain} 切换历史版本                               │
│   ${green}5.${plain} 卸载面板                                   │
│────────────────────────────────────────────────│
│   ${green}6.${plain} 重置用户名和密码                           │
│   ${green}7.${plain} 重置网页根路径 (webBasePath)               │
│   ${green}8.${plain} 重置面板所有设置                           │
│   ${green}9.${plain} 修改面板监听端口                           │
│  ${green}10.${plain} 查看当前面板配置                           │
│────────────────────────────────────────────────│
│  ${green}11.${plain} 启动面板                                   │
│  ${green}12.${plain} 停止面板                                   │
│  ${green}13.${plain} 重启面板                                   │
│  ${green}14.${plain} 重启 Xray 内核                              │
│  ${green}15.${plain} 查看面板当前状态                           │
│  ${green}16.${plain} 日志及调试管理                             │
│────────────────────────────────────────────────│
│  ${green}17.${plain} 启用开机自启                               │
│  ${green}18.${plain} 禁用开机自启                               │
│────────────────────────────────────────────────│
│  ${green}19.${plain} SSL 证书管理 (DNS/HTTP 独立申请)           │
│  ${green}20.${plain} Cloudflare SSL 证书 (DNS API 申请)         │
│  ${green}21.${plain} 面板 IP 限制管理                           │
│  ${green}22.${plain} 系统防火墙端口管理                         │
│  ${green}23.${plain} SSH 端口转发管理                           │
│────────────────────────────────────────────────│
│  ${green}24.${plain} BBR 网络加速与内核管理                      │
│  ${green}25.${plain} 手动更新 Geo 数据文件                      │
│  ${green}26.${plain} 进行 Ookla 速度测试                        │
│────────────────────────────────────────────────│
│  ${green}27.${plain} PostgreSQL 数据库管理                     │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "请输入您的选择 [0-27]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_menu
            ;;
        4)
            check_install && legacy_version
            ;;
        5)
            check_install && uninstall
            ;;
        6)
            check_install && reset_user
            ;;
        7)
            check_install && reset_webbasepath
            ;;
        8)
            check_install && reset_config
            ;;
        9)
            check_install && set_port
            ;;
        10)
            check_install && check_config
            ;;
        11)
            check_install && start
            ;;
        12)
            check_install && stop
            ;;
        13)
            check_install && restart
            ;;
        14)
            check_install && restart_xray
            ;;
        15)
            check_install && status
            ;;
        16)
            check_install && show_log
            ;;
        17)
            check_install && enable
            ;;
        18)
            check_install && disable
            ;;
        19)
            ssl_cert_issue_main
            ;;
        20)
            ssl_cert_issue_CF
            ;;
        21)
            iplimit_main
            ;;
        22)
            firewall_menu
            ;;
        23)
            SSH_port_forwarding
            ;;
        24)
            bbr_menu
            ;;
        25)
            update_geo
            ;;
        26)
            run_speedtest
            ;;
        27)
            postgresql_menu
            ;;
        *)
            LOGE "请输入正确的选项序号 [0-27]"
            ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "legacy")
            check_install 0 && legacy_version 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            check_install 0 && uninstall 0
            ;;
        "bbr")
            bbr_menu
            ;;
        "update-all-geofiles")
            check_install 0 && update_all_geofiles 0 && restart 0
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
