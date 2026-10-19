#!/bin/bash
# ============================================================
# 一次性初始化脚本（修正版）
# 作用：给 hgj 安装 SSH 公钥（免密登录）+ 配置免密 sudo
# 用法：在虚拟机终端里执行（建议不加 sudo，脚本内部会自己调用）
#   bash /mnt/hgfs/bishe/ssh_setup/setup.sh
# 执行日志会写到同目录的 setup.log
# ============================================================

LOGDIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$LOGDIR/setup.log"
exec > >(tee "$LOG") 2>&1

echo "===== 开始 $(date '+%F %T') ====="
echo "运行身份: $(id -un)   脚本所在: $LOGDIR"

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC07Q2xHSutOcA1SYSRooe6xXaPgaDKbcY1GRXafljI9 bishe-agent"

echo
echo "== 0. 共享目录 =="
mount | grep -i hgfs || echo "hgfs 未出现在 mount 输出中"

echo
echo "== 1. 安装公钥 =="
install_key() {
    local u="$1"
    local h
    h="$(getent passwd "$u" | cut -d: -f6)"
    if [ -z "$h" ]; then
        echo "  跳过 $u（系统无此用户）"
        return
    fi
    mkdir -p "$h/.ssh"
    chmod 700 "$h/.ssh"
    touch "$h/.ssh/authorized_keys"
    if grep -qF "$KEY" "$h/.ssh/authorized_keys" 2>/dev/null; then
        echo "  $u 公钥已存在"
    else
        echo "$KEY" >> "$h/.ssh/authorized_keys"
        echo "  $u 公钥已写入"
    fi
    chmod 600 "$h/.ssh/authorized_keys"
    chown -R "$u":"$u" "$h/.ssh" 2>/dev/null
    echo "  目标文件: $h/.ssh/authorized_keys"
    ls -l "$h/.ssh/authorized_keys"
}

install_key hgj
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "hgj" ]; then
    install_key "$SUDO_USER"
fi

echo
echo "== 2. 配置免密 sudo =="
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
$SUDO sh -c 'echo "hgj ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-bishe-nopasswd'
$SUDO chmod 440 /etc/sudoers.d/99-bishe-nopasswd
if $SUDO visudo -c >/dev/null 2>&1; then
    echo "  sudoers 语法检查通过"
else
    echo "  sudoers 语法有误，已回滚"
    $SUDO rm -f /etc/sudoers.d/99-bishe-nopasswd
fi

echo
echo "== 3. sshd 状态与公钥认证配置 =="
systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "  ssh 服务状态未知"
grep -rih "^[[:space:]]*PubkeyAuthentication" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || echo "  sshd_config 未显式设置 PubkeyAuthentication（默认即允许）"
$SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || echo "  sshd reload 跳过"

echo
echo "===== 完成 $(date '+%F %T') ====="
