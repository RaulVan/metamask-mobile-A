#!/bin/bash
# build-android-release.sh
# MetaMask Mobile 二开项目 - Android Release APK 一键构建脚本
#
# 功能：环境检测、依赖安装、配置生成、编译、签名、导出 APK
#
# 用法：
#   ./scripts/build-android-release.sh                  # 完整构建（首次）
#   ./scripts/build-android-release.sh --skip-install    # 跳过依赖安装（增量编译）
#   ./scripts/build-android-release.sh --clean           # 清理后重新构建
#   ./scripts/build-android-release.sh --help            # 显示帮助
#
# 配置项（可通过环境变量覆盖）：
#   INFURA_API_KEY       - Infura API 密钥（必需）
#   KEYSTORE_PATH        - keystore 文件路径
#   KEYSTORE_PASSWORD    - keystore 密码
#   KEY_ALIAS            - key 别名
#   KEY_PASSWORD         - key 密码
#   BUILD_ARCH           - 构建架构 (默认 arm64-v8a)
#   OUTPUT_DIR           - APK 输出目录

set -euo pipefail

###############################################################################
# 默认配置
###############################################################################
INFURA_API_KEY="${INFURA_API_KEY:-2265902bbc08433a8274a3cd455e08fc}"
KEYSTORE_PATH="${KEYSTORE_PATH:-android/keystores/uni.moneycat.keystore}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-uni.moneycat}"
KEY_ALIAS="${KEY_ALIAS:-uni.moneycat}"
KEY_PASSWORD="${KEY_PASSWORD:-uni.moneycat}"
BUILD_ARCH="${BUILD_ARCH:-arm64-v8a}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
APPLICATION_ID="uni.moneycat"

SKIP_INSTALL=false
DO_CLEAN=false
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
NODE_VERSION="20.18.0"

# React Native 构建依赖（透明代理环境下需手动下载）
RN_DOWNLOADS=(
  "folly-2024.10.14.00.tar.gz|https://github.com/facebook/folly/archive/v2024.10.14.00.tar.gz"
  "fast_float-6.1.4.tar.gz|https://github.com/fastfloat/fast_float/archive/v6.1.4.tar.gz"
  "glog-0.3.5.tar.gz|https://github.com/google/glog/archive/v0.3.5.tar.gz"
)

###############################################################################
# 辅助函数
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

elapsed_time() {
  local s=$1
  printf "%dm%ds" $((s/60)) $((s%60))
}

OS_TYPE="$(uname -s)"

# macOS/Linux 兼容的 sed -i
sedi() {
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# macOS/Linux 兼容的 base64 编码（无换行）
base64_encode() {
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    base64 -i "$1" | tr -d '\n'
  else
    base64 -w0 "$1"
  fi
}

###############################################################################
# 参数解析
###############################################################################
show_help() {
  cat <<'HELP'
MetaMask Mobile Android Release APK 构建脚本

用法:
  ./scripts/build-android-release.sh [选项]

选项:
  --skip-install    跳过 yarn install 和 setup（增量编译时使用）
  --clean           清理所有构建缓存后重新构建
  --help            显示此帮助信息

环境变量:
  INFURA_API_KEY       Infura API 密钥（默认已内置）
  KEYSTORE_PATH        keystore 路径（默认 android/keystores/uni.moneycat.keystore）
  KEYSTORE_PASSWORD    keystore 密码（默认 uni.moneycat）
  KEY_ALIAS            key 别名（默认 uni.moneycat）
  KEY_PASSWORD         key 密码（默认 uni.moneycat）
  BUILD_ARCH           构建架构（默认 arm64-v8a）
  OUTPUT_DIR           APK 输出目录（默认 output）

示例:
  # 首次构建
  ./scripts/build-android-release.sh

  # 修改代码后增量编译
  ./scripts/build-android-release.sh --skip-install

  # 清理后全量重建
  ./scripts/build-android-release.sh --clean

  # 自定义签名
  KEYSTORE_PATH=my.keystore KEY_ALIAS=mykey ./scripts/build-android-release.sh
HELP
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=true ;;
    --clean) DO_CLEAN=true ;;
    --help|-h) show_help ;;
    *) log_error "未知参数: $arg"; show_help ;;
  esac
done

###############################################################################
# Step 0: 环境检测
###############################################################################
step_check_env() {
  log_info "=== Step 0: 环境检测 ==="

  cd "$PROJECT_ROOT"

  # 检测操作系统
  if [[ "$OS_TYPE" != "Darwin" && "$OS_TYPE" != "Linux" ]]; then
    log_error "不支持的操作系统: $OS_TYPE（需要 macOS 或 Linux，Windows 请使用 build-android-release.bat）"
    exit 1
  fi
  log_ok "操作系统: $OS_TYPE"

  # 检测 nvm
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    log_error "未找到 nvm，请先安装: https://github.com/nvm-sh/nvm"
    exit 1
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" --no-use
  log_ok "nvm: $(nvm --version)"

  # 检测 yarn
  if ! command -v yarn &>/dev/null; then
    log_warn "yarn 未安装，尝试通过 npm 安装..."
    npm install -g yarn
  fi

  # 检测 JAVA_HOME
  if [[ -z "${JAVA_HOME:-}" ]]; then
    if [[ "$OS_TYPE" == "Darwin" ]]; then
      # macOS: Android Studio 自带 JDK
      if [[ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
        export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
      fi
    else
      # Linux: 常见路径自动探测
      local jdk_dirs=(
        "/usr/lib/jvm/java-17-openjdk-amd64"
        "/usr/lib/jvm/java-17-openjdk"
        "/usr/lib/jvm/java-17"
        "/usr/lib/jvm/zulu-17"
        "/snap/android-studio/current/jbr"
      )
      for jdir in "${jdk_dirs[@]}"; do
        if [[ -d "$jdir" ]]; then
          export JAVA_HOME="$jdir"
          break
        fi
      done
    fi

    if [[ -z "${JAVA_HOME:-}" ]]; then
      log_error "JAVA_HOME 未设置且未自动检测到 JDK"
      log_error "请设置 JAVA_HOME 环境变量（推荐 JDK 17）"
      exit 1
    fi
  fi
  if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
    log_error "JAVA_HOME 无效: $JAVA_HOME"
    exit 1
  fi
  log_ok "JAVA_HOME: $JAVA_HOME"
  log_ok "Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

  # 检测 ANDROID_HOME / ANDROID_SDK_ROOT
  if [[ -z "${ANDROID_HOME:-}" ]]; then
    if [[ -d "$HOME/Library/Android/sdk" ]]; then
      export ANDROID_HOME="$HOME/Library/Android/sdk"
    elif [[ -d "$HOME/Android/Sdk" ]]; then
      export ANDROID_HOME="$HOME/Android/Sdk"
    else
      log_error "ANDROID_HOME 未设置且未自动检测到 Android SDK"
      log_error "请安装 Android Studio 或手动设置 ANDROID_HOME"
      exit 1
    fi
  fi
  export ANDROID_SDK_ROOT="$ANDROID_HOME"

  # 检测 build-tools（apksigner、zipalign）
  local bt_dir
  bt_dir=$(ls -d "$ANDROID_HOME/build-tools/"* 2>/dev/null | sort -V | tail -1)
  if [[ -z "$bt_dir" ]]; then
    log_error "未找到 Android build-tools，请通过 Android Studio SDK Manager 安装"
    exit 1
  fi
  BUILD_TOOLS_DIR="$bt_dir"
  log_ok "Android SDK: $ANDROID_HOME"
  log_ok "Build Tools: $BUILD_TOOLS_DIR"

  # 检测 keystore
  if [[ ! -f "$PROJECT_ROOT/$KEYSTORE_PATH" ]]; then
    log_error "未找到 keystore: $KEYSTORE_PATH"
    log_error "请将 keystore 文件放到指定路径"
    exit 1
  fi
  log_ok "Keystore: $KEYSTORE_PATH (alias: $KEY_ALIAS)"

  # 检测 libusb
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    if ! brew list libusb &>/dev/null; then
      log_warn "libusb 未安装，正在安装..."
      brew install libusb
    fi
    log_ok "libusb: 已安装"
  elif [[ "$OS_TYPE" == "Linux" ]]; then
    if ! ldconfig -p 2>/dev/null | grep -q libusb; then
      log_warn "libusb 未安装，尝试安装..."
      if command -v apt-get &>/dev/null; then
        sudo apt-get install -y libusb-1.0-0-dev
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y libusb1-devel
      elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm libusb
      else
        log_warn "无法自动安装 libusb，请手动安装"
      fi
    fi
    log_ok "libusb: 已安装"
  fi

  log_ok "环境检测通过"
  echo ""
}

###############################################################################
# Step 1: Node.js 环境
###############################################################################
step_setup_node() {
  log_info "=== Step 1: 配置 Node.js ==="

  nvm install "$NODE_VERSION" 2>/dev/null || true
  nvm use "$NODE_VERSION"
  log_ok "Node: $(node --version)"
  log_ok "npm: $(npm --version)"
  log_ok "yarn: $(yarn --version)"
  echo ""
}

###############################################################################
# Step 2: 清理（可选）
###############################################################################
step_clean() {
  if [[ "$DO_CLEAN" != true ]]; then
    return
  fi

  log_info "=== Step 2: 清理项目 ==="

  # Android 构建产物
  rm -rf android/app/build android/.gradle android/build android/app/.cxx
  log_ok "Android 构建产物已清理"

  # node_modules
  chmod -R u+w node_modules 2>/dev/null || true
  rm -rf node_modules
  log_ok "node_modules 已清理"

  # 各种缓存
  rm -rf .expo .yarn/install-state.gz
  local tmp_dir="${TMPDIR:-/tmp}"
  rm -rf "$tmp_dir"/metro-* "$tmp_dir"/react-native-* 2>/dev/null || true
  log_ok "缓存已清理"

  # 强制走完整安装
  SKIP_INSTALL=false
  echo ""
}

###############################################################################
# Step 3: 安装依赖
###############################################################################
step_install_deps() {
  if [[ "$SKIP_INSTALL" == true ]]; then
    log_info "=== Step 3: 跳过依赖安装（--skip-install）==="
    echo ""
    return
  fi

  log_info "=== Step 3: 安装依赖 ==="

  yarn install
  log_ok "yarn install 完成"

  yarn allow-scripts auto 2>/dev/null || true
  log_ok "allow-scripts 配置完成"
  echo ""
}

###############################################################################
# Step 4: 配置环境变量文件
###############################################################################
step_configure_env() {
  log_info "=== Step 4: 配置环境变量 ==="

  # .js.env
  if [[ ! -f .js.env ]]; then
    cp .js.env.example .js.env

    # 修复 .js.env.example 中的语法错误
    # DECODING_API_URL 使用了错误的 YAML 语法，需要改为 shell 语法
    if grep -q "DECODING_API_URL:" .js.env; then
      sedi "s|export DECODING_API_URL:.*|export DECODING_API_URL=\"https://signature-insights.api.cx.metamask.io/v1\"|" .js.env
      log_ok "已修复 DECODING_API_URL 语法"
    fi

    # 设置 Infura API Key
    sedi "s|export MM_INFURA_PROJECT_ID=.*|export MM_INFURA_PROJECT_ID=\"${INFURA_API_KEY}\"|" .js.env
    log_ok "已设置 MM_INFURA_PROJECT_ID"
  else
    log_ok ".js.env 已存在，跳过创建"
  fi

  # .android.env
  if [[ ! -f .android.env ]]; then
    cp .android.env.example .android.env
    log_ok "已创建 .android.env"
  else
    log_ok ".android.env 已存在"
  fi

  # Sentry 配置
  if [[ ! -f sentry.release.properties ]]; then
    cp sentry.release.properties.example sentry.release.properties 2>/dev/null || \
      echo "# placeholder" > sentry.release.properties
    log_ok "已创建 sentry.release.properties"
  fi
  if [[ ! -f sentry.debug.properties ]]; then
    cp sentry.debug.properties.example sentry.debug.properties 2>/dev/null || \
      echo "# placeholder" > sentry.debug.properties
    log_ok "已创建 sentry.debug.properties"
  fi

  # google-services.json
  if [[ ! -f android/app/google-services.json ]]; then
    cat > android/app/google-services.json <<GSJSON
{
  "project_info": {
    "project_number": "000000000000",
    "firebase_url": "https://metamask-mobile.firebaseio.com",
    "project_id": "metamask-mobile",
    "storage_bucket": "metamask-mobile.appspot.com"
  },
  "client": [
    {
      "client_info": {
        "mobilesdk_app_id": "1:000000000000:android:0000000000000000",
        "android_client_info": {
          "package_name": "${APPLICATION_ID}"
        }
      },
      "oauth_client": [],
      "api_key": [{"current_key": "placeholder_api_key"}],
      "services": {"appinvite_service": {"other_platform_oauth_client": []}}
    },
    {
      "client_info": {
        "mobilesdk_app_id": "1:000000000000:android:0000000000000001",
        "android_client_info": {
          "package_name": "${APPLICATION_ID}.debug"
        }
      },
      "oauth_client": [],
      "api_key": [{"current_key": "placeholder_api_key"}],
      "services": {"appinvite_service": {"other_platform_oauth_client": []}}
    }
  ],
  "configuration_version": "1"
}
GSJSON
    log_ok "已创建 google-services.json (package: ${APPLICATION_ID})"
  else
    log_ok "google-services.json 已存在"
  fi

  # 更新 .js.env 中的 GOOGLE_SERVICES_B64_ANDROID
  local google_b64
  google_b64=$(base64_encode ./android/app/google-services.json)
  sedi "s|export GOOGLE_SERVICES_B64_ANDROID=.*|export GOOGLE_SERVICES_B64_ANDROID=\"${google_b64}\"|" .js.env
  log_ok "已更新 GOOGLE_SERVICES_B64_ANDROID"

  echo ""
}

###############################################################################
# Step 5: 项目 setup
###############################################################################
step_project_setup() {
  if [[ "$SKIP_INSTALL" == true ]]; then
    log_info "=== Step 5: 跳过项目 setup（--skip-install）==="
    echo ""
    return
  fi

  log_info "=== Step 5: 项目 setup ==="
  yarn setup --no-build-ios
  log_ok "项目 setup 完成"
  echo ""
}

###############################################################################
# Step 6: 预下载 GitHub 依赖（绕过透明代理问题）
###############################################################################
step_predownload_deps() {
  log_info "=== Step 6: 预下载 React Native 构建依赖 ==="

  local dl_dir="node_modules/react-native/ReactAndroid/build/downloads"
  mkdir -p "$dl_dir"

  local all_exist=true
  for entry in "${RN_DOWNLOADS[@]}"; do
    local filename="${entry%%|*}"
    if [[ ! -f "$dl_dir/$filename" ]]; then
      all_exist=false
      break
    fi
  done

  if [[ "$all_exist" == true ]]; then
    log_ok "所有依赖已存在，跳过下载"
    echo ""
    return
  fi

  for entry in "${RN_DOWNLOADS[@]}"; do
    local filename="${entry%%|*}"
    local url="${entry##*|}"

    if [[ -f "$dl_dir/$filename" ]]; then
      log_ok "$filename 已存在"
      continue
    fi

    log_info "下载 $filename ..."
    if curl -sL -o "$dl_dir/$filename" "$url"; then
      log_ok "$filename 下载完成 ($(du -h "$dl_dir/$filename" | cut -f1))"
    else
      log_warn "$filename 下载失败（如果不使用透明代理可忽略，Gradle 会自动下载）"
      rm -f "$dl_dir/$filename"
    fi
  done
  echo ""
}

###############################################################################
# Step 7: 编译 Release APK
###############################################################################
step_build_apk() {
  log_info "=== Step 7: 编译 Android Release APK ==="
  log_info "架构: $BUILD_ARCH"

  local build_start
  build_start=$(date +%s)

  # 拷贝资源文件
  mkdir -p android/app/src/main/assets/fonts
  cp -f app/core/InpageBridgeWeb3.js android/app/src/main/assets/.
  cp -f app/fonts/Metamask.ttf android/app/src/main/assets/fonts/Metamask.ttf
  log_ok "资源文件已拷贝"

  # 设置构建环境变量
  export SENTRY_DISABLE_AUTO_UPLOAD=true
  export METAMASK_ENVIRONMENT=production
  export METAMASK_BUILD_TYPE=main

  # 清除代理环境变量（防止 Gradle TLS 握手失败）
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY 2>/dev/null || true

  # 加载 .js.env
  set -a
  # shellcheck disable=SC1091
  source .js.env
  set +a

  # 执行 Gradle 编译
  log_info "开始 Gradle 编译..."
  cd android
  ./gradlew app:assembleProdRelease \
    --no-daemon \
    --parallel \
    -PreactNativeArchitectures="$BUILD_ARCH" \
    -x lint \
    -x lintVitalAnalyzeProdRelease \
    -x test
  cd ..

  local build_end
  build_end=$(date +%s)
  log_ok "编译完成，耗时: $(elapsed_time $((build_end - build_start)))"
  echo ""
}

###############################################################################
# Step 8: 签名并导出 APK
###############################################################################
step_sign_and_export() {
  log_info "=== Step 8: 签名并导出 APK ==="

  local apk_path="android/app/build/outputs/apk/prod/release/app-prod-release.apk"

  if [[ ! -f "$apk_path" ]]; then
    log_error "APK 文件未找到: $apk_path"
    exit 1
  fi

  mkdir -p "$OUTPUT_DIR"
  local tmp_aligned="$OUTPUT_DIR/_aligned.apk"
  local output_apk="$OUTPUT_DIR/${APPLICATION_ID}-release.apk"

  # zipalign
  "$BUILD_TOOLS_DIR/zipalign" -v -p 4 "$apk_path" "$tmp_aligned" > /dev/null 2>&1
  log_ok "zipalign 完成"

  # apksigner
  "$BUILD_TOOLS_DIR/apksigner" sign \
    --ks "$KEYSTORE_PATH" \
    --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:$KEYSTORE_PASSWORD" \
    --key-pass "pass:$KEY_PASSWORD" \
    --out "$output_apk" \
    "$tmp_aligned"
  log_ok "apksigner 签名完成"

  # 清理临时文件
  rm -f "$tmp_aligned"

  # 验证
  log_info "验证 APK 签名..."
  "$BUILD_TOOLS_DIR/apksigner" verify --verbose --print-certs "$output_apk" 2>&1 | \
    grep -E "Verifies|Verified using|certificate DN|key size" || true

  echo ""

  # 提取 APK 信息
  local pkg_info
  pkg_info=$("$BUILD_TOOLS_DIR/aapt" dump badging "$output_apk" 2>/dev/null | head -1)
  local apk_size
  apk_size=$(du -h "$output_apk" | cut -f1)

  echo ""
  echo "==========================================="
  echo "  构建完成"
  echo "==========================================="
  echo "  APK:           $output_apk"
  echo "  大小:          $apk_size"
  echo "  $pkg_info" | sed 's/package: //' | sed "s/' /'\n                 /g" | head -5
  echo "  签名:          $KEY_ALIAS ($KEYSTORE_PATH)"
  echo "  架构:          $BUILD_ARCH"
  echo "==========================================="
}

###############################################################################
# 主流程
###############################################################################
main() {
  local total_start
  total_start=$(date +%s)

  echo ""
  echo "==========================================="
  echo "  MetaMask Mobile - Android Release Builder"
  echo "==========================================="
  echo ""

  step_check_env
  step_setup_node
  step_clean
  step_install_deps
  step_configure_env
  step_project_setup
  step_predownload_deps
  step_build_apk
  step_sign_and_export

  local total_end
  total_end=$(date +%s)
  echo ""
  log_ok "总耗时: $(elapsed_time $((total_end - total_start)))"
}

main "$@"
