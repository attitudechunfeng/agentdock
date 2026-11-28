#!/bin/bash
# 编译并打包成 build/Convoy.app，用钥匙串里的“AgentDock Local Signing”证书签名。
# 没有这张证书的环境（比如 CI）设 CONVOY_SKIP_SIGN=1，只编译不签名
set -e
cd "$(dirname "$0")"
APP=build/Convoy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/* "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 -lsqlite3 -o "$APP/Contents/MacOS/Convoy" Sources/*.swift
if [ "${CONVOY_SKIP_SIGN:-}" = "1" ]; then
  echo "built $APP (unsigned)"
  exit 0
fi
codesign --force --sign "AgentDock Local Signing" "$APP"
echo "built $APP"
