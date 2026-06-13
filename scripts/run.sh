#!/bin/zsh
set -euo pipefail

# 一键：构建 + 签名 + 重启。
# 使用固定的 Apple Development 证书签名（见 build-app.sh），
# 因此每次重新编译 macOS 都识别为同一个 App，
# 麦克风 / 语音识别 / 辅助功能权限不会重置、不会反复弹窗。

ROOT=${0:A:h:h}
APP="$ROOT/build/LocalVoice.app"

# 退出正在运行的旧实例，避免“正在使用中无法覆盖”。
pkill -x LocalVoice 2>/dev/null || true
sleep 1

"$ROOT/scripts/build-app.sh"

open "$APP"
echo "已启动：$APP（图标在菜单栏）"
