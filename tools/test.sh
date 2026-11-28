#!/bin/bash
# 单元测试：把 Sources（除 main.swift）和 Tests 一起编成一个命令行程序再运行，不用装到“应用程序”里。
# 测试写在 Tests/*.swift 里：每个测试是一个不带参数的函数，名字以 test 开头，断言用 expect / expectEq
set -e
cd "$(dirname "$0")/.."
mkdir -p build/test-main
OUT=build/convoy-tests
MAIN=build/test-main/main.swift
# 按名字把所有测试都调一遍，最后报数
{
  echo 'import Foundation'
  grep -ho '^func test[A-Za-z0-9_]*()' Tests/*.swift | sed 's/^func \(.*\)()/\1()/'
  echo 'print("\(passed) passed, \(failed) failed")'
  echo 'exit(failed == 0 ? 0 : 1)'
} > "$MAIN"
swiftc -swift-version 5 -lsqlite3 -o "$OUT" $(ls Sources/*.swift | grep -v '/main.swift$') Tests/*.swift "$MAIN"
"$OUT"
