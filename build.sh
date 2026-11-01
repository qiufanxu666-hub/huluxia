#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${THEOS:?请先设置 THEOS 环境变量}"
: "${TARGET_BUNDLES:?请设置 TARGET_BUNDLES，例如 com.example.app,com.example.test}"

python3 - <<'PY'
import os, plistlib
items=[x.strip() for x in os.environ['TARGET_BUNDLES'].split(',') if x.strip()]
if not items: raise SystemExit('TARGET_BUNDLES 不能为空')
for x in items:
    if ' ' in x or '.' not in x: raise SystemExit('无效 Bundle ID: '+x)
with open('Tweak/HuluXiaTweak.plist','wb') as f:
    plistlib.dump({'Filter': {'Bundles': items}}, f)
print('将仅为以下 Bundle ID 配置注入过滤器：')
print('\n'.join(items))
PY

make clean package THEOS_PACKAGE_SCHEME="${THEOS_PACKAGE_SCHEME:-rootless}" FINALPACKAGE=1
mkdir -p build-output
find . -maxdepth 3 \( -name '*.deb' -o -name '*.dylib' \) -type f -exec cp -f {} build-output/ \;
printf '\n构建完成。产物位于 %s/build-output\n' "$ROOT"
