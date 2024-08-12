#!/bin/bash

# 获取传递给脚本的第一个参数
SMTP_SERVER="$1"

# 检查是否提供了参数
if [ -z "$1" ]; then
    echo "Usage: $0 <smtp_server>"
    exit 1
fi

# 使用 sed 解析获取主域名部分
DOMAIN_HOST=$(echo "$SMTP_SERVER" | sed -E 's/^[^.]+\.([^.]+\.[^.]+)$/\1/')

# 全局变量，用于保存密钥文件内容
KEY_CONTENT=""

# 设置主机名
set_hostname() {
    hostnamectl set-hostname "$SMTP_SERVER"
    if [ $? -ne 0 ]; then
        echo "Failed to set hostname"
        exit 1
    fi
}

# 安装并配置 Postfix
install_postfix() {
    dnf install postfix -y
    if [ $? -ne 0 ]; then
        echo "Failed to install Postfix"
        exit 1
    fi

    systemctl start postfix
    systemctl enable postfix

    postconf -e "myhostname = $SMTP_SERVER"
    postconf -e "myorigin = $DOMAIN_HOST"

    systemctl restart postfix
    if [ $? -ne 0 ]; then
        echo "Failed to restart Postfix"
        exit 1
    fi
}

# 安装 OpenDKIM
install_opendkim() {
    dnf install epel-release -y
    dnf install opendkim opendkim-tools perl-Getopt-Long -y
    if [ $? -ne 0 ]; then
        echo "Failed to install OpenDKIM"
        exit 1
    fi
}

# 更新 SigningTable 文件
update_SigningTable() {
    SIGNING_TABLE_STR="*@$DOMAIN_HOST    mta1._domainkey.$DOMAIN_HOST"
    SIGNING_TABLE_FILE="/etc/opendkim/SigningTable"
    
    if [ ! -f "$SIGNING_TABLE_FILE" ]; then
        echo "SigningTable file not found: $SIGNING_TABLE_FILE"
        exit 1
    fi
    
    # 检查是否已经存在该条目
    grep -qxF "$SIGNING_TABLE_STR" "$SIGNING_TABLE_FILE" || echo "$SIGNING_TABLE_STR" >> "$SIGNING_TABLE_FILE"
    
    if [ $? -eq 0 ]; then
        echo "Successfully added to SigningTable: $SIGNING_TABLE_STR"
    else
        echo "Failed to add to SigningTable"
        exit 1
    fi
}

# 更新 KeyTable 文件
update_KeyTable() {
    KeyTable_str="mta1._domainkey.$DOMAIN_HOST     $DOMAIN_HOST:mta1:/etc/opendkim/keys/$DOMAIN_HOST/mta1.private"
    KEYTABLE_FILE="/etc/opendkim/KeyTable"

    if [ ! -f "$KEYTABLE_FILE" ]; then
        echo "KeyTable file not found: $KEYTABLE_FILE"
        exit 1
    fi
    
    grep -qxF "$KeyTable_str" "$KEYTABLE_FILE" || echo "$KeyTable_str" >> "$KEYTABLE_FILE"
    
    if [ $? -eq 0 ]; then
        echo "Successfully added to KeyTable: $KeyTable_str"
    else
        echo "Failed to add to KeyTable"
        exit 1
    fi
}

# 更新 TrustedHosts 文件
update_TrustedHosts() {
    TrustedHosts_str="*.$DOMAIN_HOST"
    TRUSTEDHOSTS_FILE="/etc/opendkim/TrustedHosts"

    if [ ! -f "$TRUSTEDHOSTS_FILE" ]; then
        echo "TrustedHosts file not found: $TRUSTEDHOSTS_FILE"
        exit 1
    fi
    
    grep -qxF "$TrustedHosts_str" "$TRUSTEDHOSTS_FILE" || echo "$TrustedHosts_str" >> "$TRUSTEDHOSTS_FILE"
    
    if [ $? -eq 0 ]; then
        echo "Successfully added to TrustedHosts: $TrustedHosts_str"
    else
        echo "Failed to add to TrustedHosts"
        exit 1
    fi
}

# 执行 OpenDKIM 配置更新
add_domain_opendkim() {
    update_SigningTable
    update_KeyTable
    update_TrustedHosts  
}

generate_private() {
    # 创建目录并生成密钥
    mkdir -p /etc/opendkim/keys/$DOMAIN_HOST
    opendkim-genkey -b 2048 -d $DOMAIN_HOST -D /etc/opendkim/keys/$DOMAIN_HOST -s mta1 -v
    chown opendkim:opendkim /etc/opendkim/keys/ -R
    
    # 定义密钥文件路径
    KEY_FILE_PATH="/etc/opendkim/keys/$DOMAIN_HOST/mta1.txt"
    
    # 读取密钥文件内容
    if [ -f "$KEY_FILE_PATH" ]; then
        KEY_CONTENT=$(cat "$KEY_FILE_PATH")
    else
        echo "Failed to generate the key file: $KEY_FILE_PATH"
        exit 1
    fi
    
    # 启动并启用 opendkim 服务
    systemctl start opendkim
    if [ $? -ne 0 ]; then
        echo "Failed to start opendkim service"
        exit 1
    fi
    
    systemctl enable opendkim
    if [ $? -ne 0 ]; then
        echo "Failed to enable opendkim service"
        exit 1
    fi
}


# 执行各项功能
# set_hostname
# install_postfix
# install_opendkim
# 更新/etc/opendkim.conf文件
# add_domain_opendkim
# generate_private

#/etc/postfix/main.cf 更新这个文件

echo "DNS TO : mta1._domainkey.$DOMAIN_HOST"
echo "Generated DKIM key content:"
echo "$KEY_CONTENT"
echo "All tasks completed successfully."


