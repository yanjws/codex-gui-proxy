#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build/RelayTests
xcrun swiftc -parse-as-library -swift-version 6 \
  -module-cache-path build/RelayTests/ModuleCache \
  ChatGPTProxy/ProxySettings.swift ChatGPTProxy/RelayRequest.swift \
  ChatGPTProxy/ProxyRelay.swift ChatGPTProxy/RelaySession.swift \
  ChatGPTProxy/LaunchConfiguration.swift Tests/RelayTestDriver.swift \
  -o build/RelayTests/relay-test-driver
xcrun swiftc -parse-as-library -swift-version 6 \
  -module-cache-path build/RelayTests/ModuleCache \
  ChatGPTProxy/ProxySettings.swift ChatGPTProxy/RelayRequest.swift \
  ChatGPTProxy/ProxyRelay.swift ChatGPTProxy/RelaySession.swift \
  ChatGPTProxy/LaunchConfiguration.swift ChatGPTProxy/ProxyPortChecker.swift \
  ChatGPTProxy/ApplicationLocator.swift ChatGPTProxy/ApplicationLauncher.swift \
  ChatGPTProxy/LauncherModel.swift Tests/LauncherModelTestDriver.swift \
  -o build/RelayTests/launcher-model-test-driver
python3 Tests/test_relay.py build/RelayTests/relay-test-driver build/RelayTests/launcher-model-test-driver
