# Secure Server Panel Installer

高速、低延迟、安全加固的服务器后台一键安装脚本。

该脚本用于在 Linux 服务器上快速部署服务器管理后台，并自动进行基础网络加速、低延迟 TCP 优化和安全加固。

## 功能特点

- 一键安装
- 默认安装最新版本
- BBR 网络加速
- TCP 低延迟优化
- 高连接数优化
- 基础防火墙保护
- fail2ban 防 SSH 暴力破解
- 自动安装系统依赖
- 自动安装 x-ui 面板
- 自动保存安装日志
- 安装信息仅 root 用户可查看

## 支持系统

- Debian
- Ubuntu
- CentOS
- Rocky Linux
- AlmaLinux

## 安装命令

请使用 root 用户执行以下命令：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Liam0810-liang/secure-server-panel-installer/main/install.sh)
