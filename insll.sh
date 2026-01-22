#!/bin/bash

# --- 颜色定义  ---
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# --- 基础环境检查 (整合自脚本 1) ---
# 检查 root 权限 
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# 检测系统发行版 [cite: 1, 2, 3, 4, 5, 6]
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

# 检测架构 [cite: 6, 7, 8, 9]
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

# --- 整合脚本 2：交互式 SSL 证书申请 ---
install_ssl() {
    echo -e "${green}开始配置 SSL 证书申请...${plain}"
    
    # 交互获取域名 
    read -p "请输入您的域名 (例如: example.com): " ssl_domain
    if [[ -z "${ssl_domain}" ]]; then
        echo -e "${red}域名不能为空，跳过证书申请！${plain}"
        return
    fi

    # 安装依赖 
    echo -e "${yellow}正在安装 acme.sh 依赖...${plain}"
    if [[ x"${release}" == x"centos" ]]; then
        yum install curl socat cronie tar -y [cite: 18]
        systemctl start crond
        systemctl enable crond
    else
        apt update && apt upgrade -y 
        apt install curl socat cron -y 
    fi

    # 安装 acme.sh 并申请证书 
    curl https://get.acme.sh | sh -s email=guanhui_m@aimotech.cn 
    
    # 使用别名执行 acme.sh
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt 
    
    echo -e "${yellow}正在通过 Standalone 模式申请证书，请确保 80 端口未被占用...${plain}"
    /root/.acme.sh/acme.sh --issue -d ${ssl_domain} --standalone 
    
    if [[ $? -eq 0 ]]; then
        # 安装证书到 /root/ 目录下 
        /root/.acme.sh/acme.sh --installcert -d ${ssl_domain} \
            --key-file /root/1.key \
            --fullchain-file /root/1.crt 
        echo -e "${green}证书申请成功！${plain}"
        echo -e "公钥路径: ${yellow}/root/1.crt${plain}"
        echo -e "私钥路径: ${yellow}/root/1.key${plain}"
    else
        echo -e "${red}证书申请失败，请检查域名解析是否正确及 80 端口是否放行。${plain}"
    fi
}

# --- x-ui 安装与配置 (整合自脚本 1) ---
install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install wget curl tar -y [cite: 18]
    else
        apt install wget curl tar -y [cite: 18]
    fi
}

config_after_install() {
    echo -e "${yellow}出于安全考虑，安装完成后需要强制修改端口与账户密码 [cite: 19]${plain}"
    read -p "确认是否继续?[y/n]": config_confirm
    if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
        read -p "请设置您的账户名: " config_account [cite: 19]
        read -p "请设置您的账户密码: " config_password [cite: 19]
        read -p "请设置面板访问端口: " config_port [cite: 19]
        /usr/local/x-ui/x-ui setting -username ${config_account} -password ${config_password} [cite: 19]
        /usr/local/x-ui/x-ui setting -port ${config_port} [cite: 20]
        echo -e "${green}账户与端口设定完成 [cite: 20]${plain}"
    else
        echo -e "${red}已取消,所有设置项均为默认设置 [cite: 20]${plain}"
    fi
}

install_x-ui() {
    systemctl stop x-ui 2>/dev/null [cite: 21]
    cd /usr/local/

    # 自动获取最新版本 [cite: 21]
    last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$last_version" ]]; then
        echo -e "${red}检测 x-ui 版本失败，请检查网络 [cite: 21]${plain}"
        exit 1
    fi

    wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz https://github.com/vaxilu/x-ui/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz [cite: 21]
    
    if [[ -e /usr/local/x-ui/ ]]; then
        rm /usr/local/x-ui/ -rf [cite: 24]
    fi

    tar zxvf x-ui-linux-${arch}.tar.gz [cite: 24]
    rm x-ui-linux-${arch}.tar.gz -f [cite: 24]
    cd x-ui
    chmod +x x-ui bin/xray-linux-${arch} [cite: 24]
    cp -f x-ui.service /etc/systemd/system/ [cite: 24]
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/vaxilu/x-ui/main/x-ui.sh [cite: 24]
    chmod +x /usr/bin/x-ui [cite: 24]
    
    config_after_install [cite: 24]
    
    systemctl daemon-reload [cite: 25]
    systemctl enable x-ui [cite: 25]
    systemctl start x-ui [cite: 25]
    echo -e "${green}x-ui v${last_version}${plain} 安装完成 [cite: 25]"
}

# --- 运行逻辑 ---
clear
echo -e "${green}开始执行整合安装脚本...${plain}"
install_base    # 安装 wget/curl [cite: 18]
install_ssl     # 脚本 2：申请证书 (支持域名输入) 
install_x-ui    # 脚本 1：安装面板 [cite: 21, 24]

echo -e "\n${green}所有流程已处理完毕！${plain}"
echo -e "你可以通过 x-ui 命令管理面板，并在面板设置中使用 /root/1.crt 和 /root/1.key 配置 SSL。"
