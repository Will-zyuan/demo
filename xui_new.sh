#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="amd64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="amd64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install wget curl tar socat cronie -y
        systemctl start crond
        systemctl enable crond
    else
        apt update
        apt install wget curl tar socat cron -y
        systemctl start cron
        systemctl enable cron
    fi
}

# SSL 证书申请函数
# 【改动 1】--installcert 增加 --ecc 与 --reloadcmd "systemctl restart x-ui"
#           目的：证书续签后自动重启 x-ui，让 xray 重新读取磁盘证书
# 【改动 2】证书申请失败不再 exit 1 直接中断整机安装，改为警告后返回
install_acme() {
    echo -e "${yellow}--- 开始申请 SSL 证书 ---${plain}"
    read -p "请输入您要申请证书的域名 (例如: **.zoolion-store.com): " ssl_domain
    if [[ -z "${ssl_domain}" ]]; then
        echo -e "${red}域名不能为空，跳过 SSL 申请${plain}"
        return
    fi

    echo -e "${yellow}正在安装 acme.sh...${plain}"
    curl https://get.acme.sh | sh -s email=guanhui_m@aimotech.cn

    # 使用绝对路径调用 acme.sh
    local acme_bin="/root/.acme.sh/acme.sh"

    echo -e "${yellow}设置默认 CA 为 Let's Encrypt...${plain}"
    $acme_bin --set-default-ca --server letsencrypt

    echo -e "${yellow}开始申请证书，请确保 80 端口未被占用且已开放防火墙...${plain}"
    $acme_bin --issue -d ${ssl_domain} --standalone

    if [[ $? -ne 0 ]]; then
        echo -e "${red}证书申请失败！请检查域名解析和 80 端口。${plain}"
        echo -e "${yellow}安装流程继续，x-ui 将无证书启动；可稍后手动执行以下命令补签：${plain}"
        echo -e "  /root/.acme.sh/acme.sh --issue -d ${ssl_domain} --standalone"
        echo -e "  /root/.acme.sh/acme.sh --installcert -d ${ssl_domain} --ecc \\"
        echo -e "    --key-file /root/1.key --fullchain-file /root/1.crt \\"
        echo -e "    --reloadcmd \"systemctl restart x-ui\""
        return
    fi

    echo -e "${yellow}证书申请成功，正在导出到 /root/ 目录...${plain}"
    # --ecc 必加：acme 新版默认签发 ECC 证书，落在 <域名>_ecc/ 目录
    # --reloadcmd：续签完成后自动重启 x-ui，避免"证书更新但进程仍用旧证书"
    $acme_bin --installcert -d ${ssl_domain} --ecc \
        --key-file /root/1.key \
        --fullchain-file /root/1.crt \
        --reloadcmd "systemctl restart x-ui"

    echo -e "${green}证书已就绪：${plain}"
    echo -e "公钥路径: ${green}/root/1.crt${plain}"
    echo -e "私钥路径: ${green}/root/1.key${plain}"
    echo -e "${green}已配置续签钩子：证书自动续签后将重启 x-ui${plain}"
    echo -e "下次续签时间: $(grep -oP "Le_NextRenewTimeStr='\K[^']*" /root/.acme.sh/${ssl_domain}_ecc/${ssl_domain}.conf 2>/dev/null)"
}

config_after_install() {
    echo -e "${yellow}出于安全考虑，安装/更新完成后需要强制修改端口与账户密码${plain}"
    read -p "确认是否继续?[y/n]": config_confirm
    if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
        read -p "请设置您的账户名:" config_account
        read -p "请设置您的账户密码:" config_password
        read -p "请设置面板访问端口:" config_port
        # 【改动 3】变量加双引号，避免密码含空格/$/引号时解析失败
        /usr/local/x-ui/x-ui setting -username "${config_account}" -password "${config_password}"
        /usr/local/x-ui/x-ui setting -port "${config_port}"
        echo -e "${green}面板账号端口设定完成${plain}"
    else
        echo -e "${red}已取消,所有设置项均为默认设置,请及时修改${plain}"
    fi
}

install_x-ui() {
    systemctl stop x-ui
    cd /usr/local/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        # 【改动 4】版本检测失败不再 exit 1，回退到已知可用版本
        if [[ -z "$last_version" ]]; then
            last_version="0.3.2"
            echo -e "${yellow}检测 x-ui 版本失败，回退到默认版本 ${last_version}${plain}"
        fi
    else
        last_version=$1
    fi

    # 下载失败重试 + 镜像兜底（GitHub 直连在国内常失败）
    local url="https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz"
    local mirrors=(
        "$url"
        "https://ghproxy.net/${url}"
        "https://gh-proxy.com/${url}"
    )
    local got=0
    for m in "${mirrors[@]}"; do
        echo -e "${yellow}下载 x-ui ${last_version}: ${m}${plain}"
        if wget -N --no-check-certificate --timeout=30 --tries=2 -O /usr/local/x-ui-linux-${arch}.tar.gz "$m"; then
            got=1
            break
        fi
    done
    if [[ $got -eq 0 ]]; then
        echo -e "${red}x-ui 下载失败，所有镜像均不可用${plain}"
        exit 1
    fi

    tar zxvf x-ui-linux-${arch}.tar.gz
    rm x-ui-linux-${arch}.tar.gz -f
    cd x-ui
    chmod +x x-ui bin/xray-linux-${arch}
    cp -f x-ui.service /etc/systemd/system/
    # x-ui.sh 同样做镜像兜底
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/vaxilu/x-ui/main/x-ui.sh \
        || wget --no-check-certificate -O /usr/bin/x-ui https://ghproxy.net/https://raw.githubusercontent.com/vaxilu/x-ui/main/x-ui.sh \
        || wget --no-check-certificate -O /usr/bin/x-ui https://cdn.jsdelivr.net/gh/vaxilu/x-ui@main/x-ui.sh
    chmod +x /usr/bin/x-ui

    config_after_install

    # 执行 SSL 证书申请
    install_acme
    systemctl daemon-reload
    # 【改动 5】删除原 "每周六 10:00 x-ui restart" 的定时任务
    #   原行： (crontab -l 2>/dev/null; echo "0 10 * * 6 x-ui restart >> /home/user/cron.log 2>&1") | crontab -
    #   原因：那是用"定期重启"掩盖证书不重载的老办法，且日志路径 /home/user 在纯 root 机器上不存在。
    #        现由 acme 的 --reloadcmd 精确触发，无需盲重启。

    # 【改动 6】komari agent 安装：token 不再硬编码，支持环境变量覆盖
    KOMARI_ENDPOINT="${KOMARI_ENDPOINT:-https://kom.zoolion-store.com}"
    KOMARI_TOKEN="${KOMARI_TOKEN:-p68fWRS5bYrNFKxGfrURydlZ}"
    echo -e "${yellow}安装 komari agent -> ${KOMARI_ENDPOINT}${plain}"
    wget -qO- https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh \
        | bash -s -- -e "${KOMARI_ENDPOINT}" --auto-discovery "${KOMARI_TOKEN}" \
        || echo -e "${red}komari agent 安装失败（不影响 x-ui），可稍后手动安装${plain}"

    systemctl enable x-ui
    systemctl start x-ui
    echo -e "${green}x-ui v${last_version} 安装完成${plain}"
}

echo -e "${green}开始安装流程${plain}"
install_base
install_x-ui $1
