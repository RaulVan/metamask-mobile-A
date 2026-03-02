@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

REM ============================================================================
REM build-android-release.bat
REM MetaMask Mobile - Android Release APK Windows 构建脚本
REM
REM 用法:
REM   scripts\build-android-release.bat                   完整构建
REM   scripts\build-android-release.bat --skip-install     跳过依赖安装
REM   scripts\build-android-release.bat --clean            清理后重新构建
REM   scripts\build-android-release.bat --help             显示帮助
REM
REM 前置要求:
REM   - nvm-windows (https://github.com/coreybutler/nvm-windows)
REM   - Android Studio (提供 JDK 和 SDK)
REM   - Git for Windows (包含 curl)
REM   - PowerShell 5.1+
REM ============================================================================

REM --- 默认配置 ---
if not defined INFURA_API_KEY set "INFURA_API_KEY=2265902bbc08433a8274a3cd455e08fc"
if not defined KEYSTORE_PATH set "KEYSTORE_PATH=android\keystores\uni.moneycat.keystore"
if not defined KEYSTORE_PASSWORD set "KEYSTORE_PASSWORD=uni.moneycat"
if not defined KEY_ALIAS set "KEY_ALIAS=uni.moneycat"
if not defined KEY_PASSWORD set "KEY_PASSWORD=uni.moneycat"
if not defined BUILD_ARCH set "BUILD_ARCH=arm64-v8a"
if not defined OUTPUT_DIR set "OUTPUT_DIR=output"
set "APPLICATION_ID=uni.moneycat"
set "NODE_VERSION=20.18.0"
set "SKIP_INSTALL=false"
set "DO_CLEAN=false"

REM --- 解析参数 ---
:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="--skip-install" ( set "SKIP_INSTALL=true" & shift & goto :parse_args )
if "%~1"=="--clean" ( set "DO_CLEAN=true" & shift & goto :parse_args )
if "%~1"=="--help" goto :show_help
if "%~1"=="-h" goto :show_help
echo [ERROR] 未知参数: %~1
goto :show_help
:args_done

REM --- 定位项目根目录 ---
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%.."
set "PROJECT_ROOT=%CD%"

REM --- 记录开始时间 ---
set "TOTAL_START=%TIME%"

echo.
echo ===========================================
echo   MetaMask Mobile - Android Release Builder
echo   Platform: Windows
echo ===========================================
echo.

REM ============================================================================
REM Step 0: 环境检测
REM ============================================================================
call :step_check_env
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 1: Node.js 环境
REM ============================================================================
call :step_setup_node
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 2: 清理（可选）
REM ============================================================================
call :step_clean

REM ============================================================================
REM Step 3: 安装依赖
REM ============================================================================
call :step_install_deps
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 4: 配置环境变量文件
REM ============================================================================
call :step_configure_env
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 5: 项目 setup
REM ============================================================================
call :step_project_setup
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 6: 预下载依赖
REM ============================================================================
call :step_predownload_deps

REM ============================================================================
REM Step 7: 编译 Release APK
REM ============================================================================
call :step_build_apk
if errorlevel 1 goto :error_exit

REM ============================================================================
REM Step 8: 签名并导出 APK
REM ============================================================================
call :step_sign_and_export
if errorlevel 1 goto :error_exit

REM --- 总耗时 ---
call :calc_elapsed "%TOTAL_START%" "%TIME%"
echo.
echo [OK]    总耗时: !ELAPSED_RESULT!

popd
endlocal
exit /b 0

REM ============================================================================
REM 子程序定义
REM ============================================================================

:step_check_env
echo [INFO]  === Step 0: 环境检测 ===

REM 检测 nvm-windows
where nvm >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未找到 nvm-windows
    echo [ERROR] 请安装: https://github.com/coreybutler/nvm-windows/releases
    exit /b 1
)
echo [OK]    nvm-windows 已安装

REM 检测 JAVA_HOME
if not defined JAVA_HOME (
    REM Android Studio 常见安装路径
    if exist "%LOCALAPPDATA%\Programs\Android Studio\jbr\bin\java.exe" (
        set "JAVA_HOME=%LOCALAPPDATA%\Programs\Android Studio\jbr"
    ) else if exist "%ProgramFiles%\Android\Android Studio\jbr\bin\java.exe" (
        set "JAVA_HOME=%ProgramFiles%\Android\Android Studio\jbr"
    ) else (
        echo [ERROR] JAVA_HOME 未设置且未检测到 Android Studio JDK
        echo [ERROR] 请设置 JAVA_HOME 环境变量（推荐 JDK 17）
        exit /b 1
    )
)
if not exist "!JAVA_HOME!\bin\java.exe" (
    echo [ERROR] JAVA_HOME 无效: !JAVA_HOME!
    exit /b 1
)
echo [OK]    JAVA_HOME: !JAVA_HOME!

REM 检测 ANDROID_HOME
if not defined ANDROID_HOME (
    if exist "%LOCALAPPDATA%\Android\Sdk" (
        set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
    ) else if defined ANDROID_SDK_ROOT (
        set "ANDROID_HOME=!ANDROID_SDK_ROOT!"
    ) else (
        echo [ERROR] ANDROID_HOME 未设置
        echo [ERROR] 请安装 Android Studio 或手动设置 ANDROID_HOME
        exit /b 1
    )
)
set "ANDROID_SDK_ROOT=!ANDROID_HOME!"
echo [OK]    Android SDK: !ANDROID_HOME!

REM 检测 build-tools（取版本号最大的）
set "BUILD_TOOLS_DIR="
for /f "delims=" %%d in ('dir /b /ad /on "!ANDROID_HOME!\build-tools" 2^>nul') do (
    set "BUILD_TOOLS_DIR=!ANDROID_HOME!\build-tools\%%d"
)
if not defined BUILD_TOOLS_DIR (
    echo [ERROR] 未找到 Android build-tools
    exit /b 1
)
echo [OK]    Build Tools: !BUILD_TOOLS_DIR!

REM 检测 keystore
if not exist "%PROJECT_ROOT%\%KEYSTORE_PATH%" (
    echo [ERROR] 未找到 keystore: %KEYSTORE_PATH%
    exit /b 1
)
echo [OK]    Keystore: %KEYSTORE_PATH% (alias: %KEY_ALIAS%)

REM 检测 PowerShell
where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] 未找到 PowerShell，Windows 构建需要 PowerShell
    exit /b 1
)
echo [OK]    PowerShell: 已安装

REM 检测 curl
where curl >nul 2>&1
if errorlevel 1 (
    echo [WARN]  curl 未找到，预下载步骤可能失败
    echo [WARN]  请安装 Git for Windows 或 Windows 10+ 自带 curl
) else (
    echo [OK]    curl: 已安装
)

echo [OK]    环境检测通过
echo.
exit /b 0

:step_setup_node
echo [INFO]  === Step 1: 配置 Node.js ===

call nvm install %NODE_VERSION% >nul 2>&1
call nvm use %NODE_VERSION%

REM 验证 node
node --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Node.js 安装或切换失败
    exit /b 1
)
for /f "delims=" %%v in ('node --version') do echo [OK]    Node: %%v

REM 检测 yarn
where yarn >nul 2>&1
if errorlevel 1 (
    echo [WARN]  yarn 未安装，正在安装...
    call npm install -g yarn
)
for /f "delims=" %%v in ('yarn --version 2^>nul') do echo [OK]    yarn: %%v
echo.
exit /b 0

:step_clean
if not "%DO_CLEAN%"=="true" exit /b 0

echo [INFO]  === Step 2: 清理项目 ===

if exist "android\app\build" rmdir /s /q "android\app\build"
if exist "android\.gradle" rmdir /s /q "android\.gradle"
if exist "android\build" rmdir /s /q "android\build"
if exist "android\app\.cxx" rmdir /s /q "android\app\.cxx"
echo [OK]    Android 构建产物已清理

if exist "node_modules" rmdir /s /q "node_modules"
echo [OK]    node_modules 已清理

if exist ".expo" rmdir /s /q ".expo"
if exist ".yarn\install-state.gz" del /f ".yarn\install-state.gz" 2>nul
echo [OK]    缓存已清理

set "SKIP_INSTALL=false"
echo.
exit /b 0

:step_install_deps
if "%SKIP_INSTALL%"=="true" (
    echo [INFO]  === Step 3: 跳过依赖安装（--skip-install）===
    echo.
    exit /b 0
)

echo [INFO]  === Step 3: 安装依赖 ===
call yarn install
if errorlevel 1 (
    echo [ERROR] yarn install 失败
    exit /b 1
)
echo [OK]    yarn install 完成

call yarn allow-scripts auto 2>nul
echo [OK]    allow-scripts 配置完成
echo.
exit /b 0

:step_configure_env
echo [INFO]  === Step 4: 配置环境变量 ===

REM .js.env
if not exist ".js.env" (
    copy ".js.env.example" ".js.env" >nul
    echo [OK]    已复制 .js.env.example

    REM 用 PowerShell 修复 DECODING_API_URL 和设置 INFURA_API_KEY
    powershell -NoProfile -Command ^
        "$c = Get-Content '.js.env' -Raw;" ^
        "$c = $c -replace 'export DECODING_API_URL:.*', 'export DECODING_API_URL=\"https://signature-insights.api.cx.metamask.io/v1\"';" ^
        "$c = $c -replace 'export MM_INFURA_PROJECT_ID=.*', 'export MM_INFURA_PROJECT_ID=\"%INFURA_API_KEY%\"';" ^
        "[System.IO.File]::WriteAllText('.js.env', $c)"
    echo [OK]    已修复 DECODING_API_URL 并设置 INFURA_API_KEY
) else (
    echo [OK]    .js.env 已存在
)

REM .android.env
if not exist ".android.env" (
    copy ".android.env.example" ".android.env" >nul
    echo [OK]    已创建 .android.env
) else (
    echo [OK]    .android.env 已存在
)

REM sentry 配置
if not exist "sentry.release.properties" (
    if exist "sentry.release.properties.example" (
        copy "sentry.release.properties.example" "sentry.release.properties" >nul
    ) else (
        echo # placeholder> "sentry.release.properties"
    )
    echo [OK]    已创建 sentry.release.properties
)
if not exist "sentry.debug.properties" (
    if exist "sentry.debug.properties.example" (
        copy "sentry.debug.properties.example" "sentry.debug.properties" >nul
    ) else (
        echo # placeholder> "sentry.debug.properties"
    )
    echo [OK]    已创建 sentry.debug.properties
)

REM google-services.json
if not exist "android\app\google-services.json" (
    call :create_google_services
    echo [OK]    已创建 google-services.json (package: %APPLICATION_ID%)
) else (
    echo [OK]    google-services.json 已存在
)

REM 更新 GOOGLE_SERVICES_B64_ANDROID
set "GS_PATH=%PROJECT_ROOT%\android\app\google-services.json"
for /f "delims=" %%b in ('powershell -NoProfile -Command "[Convert]::ToBase64String([System.IO.File]::ReadAllBytes(\"%GS_PATH%\"))"') do set "GOOGLE_B64=%%b"
powershell -NoProfile -Command ^
    "$c = Get-Content '.js.env' -Raw;" ^
    "$c = $c -replace 'export GOOGLE_SERVICES_B64_ANDROID=.*', ('export GOOGLE_SERVICES_B64_ANDROID=' + [char]34 + '%GOOGLE_B64%' + [char]34);" ^
    "[System.IO.File]::WriteAllText('.js.env', $c)"
echo [OK]    已更新 GOOGLE_SERVICES_B64_ANDROID
echo.
exit /b 0

:create_google_services
REM 用 PowerShell 生成格式正确的 google-services.json
powershell -NoProfile -Command ^
    "$appId = '%APPLICATION_ID%';" ^
    "$json = '{' + [char]10;" ^
    "$json += '  \"project_info\": {' + [char]10;" ^
    "$json += '    \"project_number\": \"000000000000\",' + [char]10;" ^
    "$json += '    \"firebase_url\": \"https://metamask-mobile.firebaseio.com\",' + [char]10;" ^
    "$json += '    \"project_id\": \"metamask-mobile\",' + [char]10;" ^
    "$json += '    \"storage_bucket\": \"metamask-mobile.appspot.com\"' + [char]10;" ^
    "$json += '  },' + [char]10;" ^
    "$json += '  \"client\": [' + [char]10;" ^
    "$json += '    {' + [char]10;" ^
    "$json += '      \"client_info\": {' + [char]10;" ^
    "$json += '        \"mobilesdk_app_id\": \"1:000000000000:android:0000000000000000\",' + [char]10;" ^
    "$json += '        \"android_client_info\": { \"package_name\": \"' + $appId + '\" }' + [char]10;" ^
    "$json += '      },' + [char]10;" ^
    "$json += '      \"oauth_client\": [],' + [char]10;" ^
    "$json += '      \"api_key\": [{ \"current_key\": \"placeholder_api_key\" }],' + [char]10;" ^
    "$json += '      \"services\": { \"appinvite_service\": { \"other_platform_oauth_client\": [] } }' + [char]10;" ^
    "$json += '    },' + [char]10;" ^
    "$json += '    {' + [char]10;" ^
    "$json += '      \"client_info\": {' + [char]10;" ^
    "$json += '        \"mobilesdk_app_id\": \"1:000000000000:android:0000000000000001\",' + [char]10;" ^
    "$json += '        \"android_client_info\": { \"package_name\": \"' + $appId + '.debug\" }' + [char]10;" ^
    "$json += '      },' + [char]10;" ^
    "$json += '      \"oauth_client\": [],' + [char]10;" ^
    "$json += '      \"api_key\": [{ \"current_key\": \"placeholder_api_key\" }],' + [char]10;" ^
    "$json += '      \"services\": { \"appinvite_service\": { \"other_platform_oauth_client\": [] } }' + [char]10;" ^
    "$json += '    }' + [char]10;" ^
    "$json += '  ],' + [char]10;" ^
    "$json += '  \"configuration_version\": \"1\"' + [char]10;" ^
    "$json += '}';" ^
    "[System.IO.File]::WriteAllText('android\app\google-services.json', $json)"
exit /b 0

:step_project_setup
if "%SKIP_INSTALL%"=="true" (
    echo [INFO]  === Step 5: 跳过项目 setup（--skip-install）===
    echo.
    exit /b 0
)

echo [INFO]  === Step 5: 项目 setup ===
call yarn setup --no-build-ios
if errorlevel 1 (
    echo [ERROR] yarn setup 失败
    exit /b 1
)
echo [OK]    项目 setup 完成
echo.
exit /b 0

:step_predownload_deps
echo [INFO]  === Step 6: 预下载 React Native 构建依赖 ===

set "DL_DIR=node_modules\react-native\ReactAndroid\build\downloads"
if not exist "%DL_DIR%" mkdir "%DL_DIR%"

where curl >nul 2>&1
if errorlevel 1 (
    echo [WARN]  curl 不可用，跳过预下载（Gradle 会自动下载）
    echo.
    exit /b 0
)

if not exist "%DL_DIR%\folly-2024.10.14.00.tar.gz" (
    echo [INFO]  下载 folly...
    curl -sL -o "%DL_DIR%\folly-2024.10.14.00.tar.gz" "https://github.com/facebook/folly/archive/v2024.10.14.00.tar.gz"
    if errorlevel 1 echo [WARN]  folly 下载失败
) else (
    echo [OK]    folly 已存在
)

if not exist "%DL_DIR%\fast_float-6.1.4.tar.gz" (
    echo [INFO]  下载 fast_float...
    curl -sL -o "%DL_DIR%\fast_float-6.1.4.tar.gz" "https://github.com/fastfloat/fast_float/archive/v6.1.4.tar.gz"
    if errorlevel 1 echo [WARN]  fast_float 下载失败
) else (
    echo [OK]    fast_float 已存在
)

if not exist "%DL_DIR%\glog-0.3.5.tar.gz" (
    echo [INFO]  下载 glog...
    curl -sL -o "%DL_DIR%\glog-0.3.5.tar.gz" "https://github.com/google/glog/archive/v0.3.5.tar.gz"
    if errorlevel 1 echo [WARN]  glog 下载失败
) else (
    echo [OK]    glog 已存在
)

echo [OK]    预下载完成
echo.
exit /b 0

:step_build_apk
echo [INFO]  === Step 7: 编译 Android Release APK ===
echo [INFO]  架构: %BUILD_ARCH%

set "BUILD_START=%TIME%"

REM 拷贝资源文件
if not exist "android\app\src\main\assets\fonts" mkdir "android\app\src\main\assets\fonts"
copy /y "app\core\InpageBridgeWeb3.js" "android\app\src\main\assets\" >nul 2>&1
copy /y "app\fonts\Metamask.ttf" "android\app\src\main\assets\fonts\" >nul 2>&1
echo [OK]    资源文件已拷贝

REM 设置构建环境变量
set "SENTRY_DISABLE_AUTO_UPLOAD=true"
set "METAMASK_ENVIRONMENT=production"
set "METAMASK_BUILD_TYPE=main"

REM 清除代理环境变量
set "http_proxy="
set "https_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "all_proxy="
set "ALL_PROXY="

REM 加载 .js.env
call :load_env_file ".js.env"

REM 执行 Gradle 编译
echo [INFO]  开始 Gradle 编译...
pushd android
call gradlew.bat app:assembleProdRelease ^
    --no-daemon ^
    --parallel ^
    -PreactNativeArchitectures=%BUILD_ARCH% ^
    -x lint ^
    -x lintVitalAnalyzeProdRelease ^
    -x test
if errorlevel 1 (
    echo [ERROR] Gradle 编译失败
    popd
    exit /b 1
)
popd

call :calc_elapsed "%BUILD_START%" "%TIME%"
echo [OK]    编译完成，耗时: !ELAPSED_RESULT!
echo.
exit /b 0

:step_sign_and_export
echo [INFO]  === Step 8: 签名并导出 APK ===

set "APK_PATH=android\app\build\outputs\apk\prod\release\app-prod-release.apk"
if not exist "%APK_PATH%" (
    echo [ERROR] APK 文件未找到: %APK_PATH%
    exit /b 1
)

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
set "TMP_ALIGNED=%OUTPUT_DIR%\_aligned.apk"
set "OUTPUT_APK=%OUTPUT_DIR%\%APPLICATION_ID%-release.apk"

REM zipalign
"!BUILD_TOOLS_DIR!\zipalign.exe" -v -p 4 "%APK_PATH%" "%TMP_ALIGNED%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] zipalign 失败
    exit /b 1
)
echo [OK]    zipalign 完成

REM apksigner
call "!BUILD_TOOLS_DIR!\apksigner.bat" sign ^
    --ks "%KEYSTORE_PATH%" ^
    --ks-key-alias "%KEY_ALIAS%" ^
    --ks-pass "pass:%KEYSTORE_PASSWORD%" ^
    --key-pass "pass:%KEY_PASSWORD%" ^
    --out "%OUTPUT_APK%" ^
    "%TMP_ALIGNED%"
if errorlevel 1 (
    echo [ERROR] apksigner 签名失败
    exit /b 1
)
echo [OK]    apksigner 签名完成

REM 清理临时文件
del /f "%TMP_ALIGNED%" 2>nul

REM 验证
echo [INFO]  验证 APK 签名...
call "!BUILD_TOOLS_DIR!\apksigner.bat" verify --verbose --print-certs "%OUTPUT_APK%" 2>&1 | findstr /i "Verifies Verified certificate"

REM APK 大小
for %%f in ("%OUTPUT_APK%") do set "APK_SIZE=%%~zf"
set /a "APK_SIZE_MB=!APK_SIZE! / 1048576"

echo.
echo ===========================================
echo   构建完成
echo ===========================================
echo   APK:     %OUTPUT_APK%
echo   大小:    !APK_SIZE_MB! MB
echo   签名:    %KEY_ALIAS% (%KEYSTORE_PATH%)
echo   架构:    %BUILD_ARCH%
echo ===========================================
exit /b 0

REM ============================================================================
REM 工具函数
REM ============================================================================

:load_env_file
REM 加载 export KEY="VALUE" 格式的 env 文件，跳过注释和空行
REM 使用 PowerShell 解析，避免 bat 引号转义陷阱
powershell -NoProfile -Command ^
    "Get-Content '%~1' | ForEach-Object {" ^
    "  $line = $_.Trim();" ^
    "  if ($line -and -not $line.StartsWith('#') -and $line.StartsWith('export ')) {" ^
    "    $pair = $line.Substring(7);" ^
    "    $eq = $pair.IndexOf('=');" ^
    "    if ($eq -gt 0) {" ^
    "      $k = $pair.Substring(0, $eq);" ^
    "      $v = $pair.Substring($eq+1).Trim('\"', \"'\");" ^
    "      Write-Output (\"$k=$v\");" ^
    "    }" ^
    "  }" ^
    "}" > "%TEMP%\_mmenv.tmp"
for /f "usebackq tokens=1,* delims==" %%a in ("%TEMP%\_mmenv.tmp") do (
    set "%%a=%%b"
)
del /f "%TEMP%\_mmenv.tmp" 2>nul
exit /b 0

:calc_elapsed
REM 计算两个 TIME 值之间的差（格式 HH:MM:SS.CC 或 HH:MM:SS,CC）
set "T_START=%~1"
set "T_END=%~2"

REM 统一分隔符（某些区域设置用逗号代替句点）
set "T_START=%T_START:,=.%"
set "T_END=%T_END:,=.%"

REM 解析开始时间
for /f "tokens=1-4 delims=:." %%a in ("%T_START%") do (
    set /a "START_S=(%%a %% 100)*3600 + (%%b %% 100)*60 + (%%c %% 100)"
)
REM 解析结束时间
for /f "tokens=1-4 delims=:." %%a in ("%T_END%") do (
    set /a "END_S=(%%a %% 100)*3600 + (%%b %% 100)*60 + (%%c %% 100)"
)

set /a "DIFF_S=END_S - START_S"
if !DIFF_S! lss 0 set /a "DIFF_S+=86400"
set /a "DIFF_M=DIFF_S / 60"
set /a "DIFF_RS=DIFF_S %% 60"
set "ELAPSED_RESULT=!DIFF_M!m!DIFF_RS!s"
exit /b 0

REM ============================================================================
REM 帮助信息
REM ============================================================================
:show_help
echo.
echo MetaMask Mobile Android Release APK 构建脚本 (Windows)
echo.
echo 用法:
echo   scripts\build-android-release.bat [选项]
echo.
echo 选项:
echo   --skip-install    跳过 yarn install 和 setup
echo   --clean           清理所有构建缓存后重新构建
echo   --help            显示此帮助信息
echo.
echo 环境变量:
echo   INFURA_API_KEY       Infura API 密钥
echo   KEYSTORE_PATH        keystore 路径
echo   KEYSTORE_PASSWORD    keystore 密码
echo   KEY_ALIAS            key 别名
echo   KEY_PASSWORD         key 密码
echo   BUILD_ARCH           构建架构 (默认 arm64-v8a)
echo   OUTPUT_DIR           APK 输出目录 (默认 output)
echo.
echo 前置要求:
echo   - nvm-windows: https://github.com/coreybutler/nvm-windows
echo   - Android Studio: https://developer.android.com/studio
echo   - Git for Windows (含 curl): https://git-scm.com
echo   - PowerShell 5.1+
echo.
echo 示例:
echo   REM 首次构建
echo   scripts\build-android-release.bat
echo.
echo   REM 修改代码后增量编译
echo   scripts\build-android-release.bat --skip-install
echo.
echo   REM 清理后全量重建
echo   scripts\build-android-release.bat --clean
echo.
echo   REM 自定义签名
echo   set KEYSTORE_PATH=my.keystore
echo   set KEY_ALIAS=mykey
echo   scripts\build-android-release.bat
echo.
exit /b 0

:error_exit
popd 2>nul
endlocal
exit /b 1
