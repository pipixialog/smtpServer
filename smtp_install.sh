#!/bin/bash

# 获取传递给脚本的第一个参数
SMTP_SERVER="$1"
CONFIG_EMAIL="bbctv@myyahoo.com"


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
    postconf "inet_interfaces = all"

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

install_sssd() {
    # 安装 sssd 及相关客户端
    yum install sssd sssd-client nscd -y
    if [ $? -ne 0 ]; then
        echo "Failed to install sssd and related packages"
        exit 1
    fi

    # 下载配置文件并覆盖
    wget -O /etc/sssd/sssd.conf https://raw.githubusercontent.com/pipixialog/smtpServer/main/sssd.conf
    if [ $? -ne 0 ]; then
        echo "Failed to download sssd.conf"
        exit 1
    fi

    # 设置配置文件权限
    chmod 600 /etc/sssd/sssd.conf
    if [ $? -ne 0 ]; then
        echo "Failed to set permissions on sssd.conf"
        exit 1
    fi

    # 启动并启用 sssd 服务
    systemctl start sssd
    if [ $? -ne 0 ]; then
        echo "Failed to start sssd service"
        exit 1
    fi

    systemctl enable sssd
    if [ $? -ne 0 ]; then
        echo "Failed to enable sssd service"
        exit 1
    fi

    # 将 postfix 用户添加到 opendkim 组
    gpasswd -a postfix opendkim
    if [ $? -ne 0 ]; then
        echo "Failed to add postfix to opendkim group"
        exit 1
    fi
}

open_firewall() {
     # 检查 firewalld 是否存在，如果不存在就安装
    if ! systemctl list-unit-files | grep -q firewalld; then
        yum install firewalld -y
        if [ $? -ne 0 ]; then
            echo "Failed to install firewalld"
            exit 1
        fi
    fi

    # 启动并启用 firewalld 服务
    systemctl start firewalld
    if [ $? -ne 0 ]; then
        echo "Failed to start firewalld service"
        exit 1
    fi

    systemctl enable firewalld
    if [ $? -ne 0 ]; then
        echo "Failed to enable firewalld service"
        exit 1
    fi

    # 添加防火墙规则
    firewall-cmd --permanent --add-port=25/tcp
    if [ $? -ne 0 ]; then
        echo "Failed to add port 25 to firewalld"
        exit 1
    fi

    firewall-cmd --permanent --add-service={smtp-submission,http}
    if [ $? -ne 0 ]; then
        echo "Failed to add services to firewalld"
        exit 1
    fi

    # 重新加载 firewalld 以应用更改
    systemctl reload firewalld
    if [ $? -ne 0 ]; then
        echo "Failed to reload firewalld"
        exit 1
    fi
}

change_master() {
    sed -i '28a submission     inet     n    -    y    -    -    smtpd\n -o syslog_name=postfix/submission\n -o smtpd_tls_security_level=encrypt\n -o smtpd_tls_wrappermode=no\n -o smtpd_tls_loglevel=1\n -o smtpd_sasl_auth_enable=yes\n -o smtpd_relay_restrictions=permit_sasl_authenticated,reject\n -o smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject\n -o smtpd_sasl_type=dovecot\n -o smtpd_sasl_path=private/auth' /etc/postfix/master.cf
}

install_dovecot() {
    # 安装 Dovecot
    dnf install dovecot -y
    if [ $? -ne 0 ]; then
        echo "Failed to install Dovecot"
        exit 1
    fi

    # 启动并启用 Dovecot 服务
    systemctl start dovecot
    if [ $? -ne 0 ]; then
        echo "Failed to start Dovecot service"
        exit 1
    fi

    systemctl enable dovecot
    if [ $? -ne 0 ]; then
        echo "Failed to enable Dovecot service"
        exit 1
    fi

    # 编辑 Dovecot 认证配置文件
    AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"

    # 确保配置文件存在
    if [ ! -f "$AUTH_CONF" ]; then
        echo "Dovecot auth configuration file not found: $AUTH_CONF"
        exit 1
    fi

    # 禁用明文认证
    sed -i 's/#disable_plaintext_auth = yes/disable_plaintext_auth = yes/' "$AUTH_CONF"

    # 配置认证机制为 plain 和 login
    sed -i 's/^auth_mechanisms = plain/auth_mechanisms = plain login/' "$AUTH_CONF"

    sed -i '/^service auth {$/a\ \ unix_listener /var/spool/postfix/private/auth {\n\ \ \ \ mode = 0660\n\ \ \ \ user = postfix\n\ \ \ \ group = postfix\n\ \ }' /etc/dovecot/conf.d/10-master.conf

    # 重启 Dovecot 以应用更改
    systemctl restart dovecot
    if [ $? -ne 0 ]; then
        echo "Failed to restart Dovecot service"
        exit 1
    fi
}
install_certbot() {
    # 安装 Certbot
    dnf install certbot -y
    if [ $? -ne 0 ]; then
        echo "Failed to install Certbot"
        exit 1
    fi

    # 使用 Certbot 获取证书
    certbot certonly --standalone --agree-tos --email "$CONFIG_EMAIL" -d "$SMTP_SERVER"
    if [ $? -ne 0 ]; then
        echo "Failed to obtain SSL certificate using Certbot"
        exit 1
    fi

    # 配置 Postfix 使用获取的证书
    postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/$SMTP_SERVER/fullchain.pem"
    if [ $? -ne 0 ]; then
        echo "Failed to configure smtpd_tls_cert_file in Postfix"
        exit 1
    fi

    postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/$SMTP_SERVER/privkey.pem"
    if [ $? -ne 0 ]; then
        echo "Failed to configure smtpd_tls_key_file in Postfix"
        exit 1
    fi

    # 重启 Postfix 服务
    systemctl restart postfix
    if [ $? -ne 0 ]; then
        echo "Failed to restart Postfix service"
        exit 1
    fi

    (crontab -l 2>/dev/null; echo "@daily certbot renew --quiet") | crontab -
}

add_check_head() {
    # 创建并编辑 /etc/postfix/smtp_header_checks 文件
    echo "/^Received:/            IGNORE" | sudo tee /etc/postfix/smtp_header_checks

    # 在 Postfix 主配置文件中添加 smtp_header_checks 配置
    sudo sed -i '$a\smtp_header_checks = regexp:/etc/postfix/smtp_header_checks' /etc/postfix/main.cf

    # 重建哈希表
    sudo postmap /etc/postfix/smtp_header_checks

    # 重新加载 Postfix 以应用更改
    sudo systemctl reload postfix
}

change_opendkim_conf() {
    mkdir /var/spool/postfix/opendkim
    chown opendkim:postfix /var/spool/postfix/opendkim

    # 注释掉 /etc/opendkim.conf 文件中的 Socket 配置行
    sed -i '/^Socket local:\/run\/opendkim\/opendkim.sock/s/^/#/' /etc/opendkim.conf

    # 在被注释行的下面新增一行新的 Socket 配置
    sed -i '/^#Socket local:\/run\/opendkim\/opendkim.sock/a Socket    local:/var/spool/postfix/opendkim/opendkim.sock' /etc/opendkim.conf


    postconf -e "milter_default_action = accept"
    postconf -e "milter_protocol = 6"
    postconf -e "smtpd_milters = local:opendkim/opendkim.sock"
    postconf -e "non_smtpd_milters = \$smtpd_milters"

    postconf -e "smtp_tls_security_level = may"
    postconf -e "smtp_tls_loglevel = 1"

    setenforce 0

    systemctl restart opendkim
    systemctl restart postfix
}


# 执行各项功能
set_hostname
install_postfix
install_opendkim
# 更新/etc/opendkim.conf文件
add_domain_opendkim
generate_private

change_opendkim_conf
install_sssd

open_firewall
#/etc/postfix/master.cf 更新这个文件
change_master

install_dovecot
install_certbot
add_check_head

echo "DNS TO : mta1._domainkey.$DOMAIN_HOST"
echo "Generated DKIM key content:"
echo "$KEY_CONTENT"
echo "All tasks completed successfully."


