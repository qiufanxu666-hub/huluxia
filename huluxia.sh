#!/bin/sh
# ============================================================================
#  葫芦侠 iOS 越狱版 —— 单文件 sh 源码  v3.0
#  ── 手机端 theos 直接 make package ──
#
#  两种形态，一次打包全都有：
#    A. 越狱软件（桌面 App）：/Applications/HuluXia.app  点图标打开即用
#    B. 注入 dylib：HuluXiaTweak.dylib + plist  指定 bundle id 注入任意 App
#
#  全部采用 iOS 私有 / 系统级 API：
#    · task_for_pid + vm_read_overwrite / vm_write / vm_protect / vm_region_64
#    · sysctl(KERN_PROC_ALL) + proc_pidpath
#    · task_info(TASK_DYLD_INFO) + dyld_all_image_infos
#    · IOKit 私有 IOHIDEventSystemClient / IOHIDEventCreateDigitizerFingerEvent
#    · dylib 内 loopback HTTP + WKWebView —— 原 HTML 面板零改动复用
#
#  用法（iPhone 越狱后，SSH / NewTerm / Filza 终端）：
#    sh huluxia.sh gen [目录] [UI.html] [图标.png]   生成 theos 工程
#    sh huluxia.sh doctor                            检查编译环境
#    sh huluxia.sh inject <bundle.id>                改注入目标（游戏包名）
#    sh huluxia.sh icon <图片>                       换桌面图标
#    sh huluxia.sh build / install / respring        编译 / 安装 / 生效
# ============================================================================

VERSION="3.0"
DEF_DIR="${HULUXIA_DIR:-/var/mobile/huluxia_theos}"
UI_DST="/usr/share/huluxia/ui.html"
TWEAK_LIB="/usr/lib/HuluXia.dylib"

usage() {
    cat <<USAGE
葫芦侠 iOS 越狱版 v$VERSION  (手机端 theos)

  gen [dir] [UI.html] [图标.png]   生成 theos 工程
  doctor                            检查编译环境 (theos/SDK/ldid/clang)
  inject <bundle.id>                设置注入目标（改成你的游戏包名）
  icon <图片>                       生成 / 更换桌面图标
  ui <文件.html>                    更换控制面板页面
  build [dir]                       make package
  install [dir]                     dpkg -i 安装 deb
  respring                          重启 SpringBoard 生效

产物两种都有：
  A. 越狱软件  /Applications/HuluXia.app   桌面图标，点开即用
  B. 注入 dylib  /Library/MobileSubstrate/DynamicLibraries/HuluXiaTweak.dylib
USAGE
}

# ============================================================================
#  环境检查（手机端）
# ============================================================================
doctor() {
    printf '========== 手机端编译环境检查 ==========\n'
    [ -n "$THEOS" ] && printf 'THEOS = %s\n' "$THEOS" || printf 'THEOS 未设置（将尝试 /var/theos ~/theos）\n'
    for c in make clang ldid dpkg-deb git perl; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '  [OK]      %s\n' "$c"
        else
            printf '  [MISSING] %s\n' "$c"
        fi
    done
    for t in /var/theos "$HOME/theos" /usr/theos; do
        if [ -d "$t" ]; then
            printf '  theos 目录: %s\n' "$t"
            ls "$t/sdks" 2>/dev/null | sed 's/^/    SDK: /'
        fi
    done
    printf '\n---- 越狱类型 ----\n'
    jb="$(detect_jb)"
    case "$jb" in
        roothide)
            printf '  隐根 (roothide)\n'
            printf '  jbroot 是随机路径，编译需带 THEOS_PACKAGE_SCHEME=roothide\n'
            printf '  控制文件架构: iphoneos-arm64e\n'
            ;;
        rootless)
            printf '  无根 (rootless)  路径前缀 /var/jb\n'
            printf '  编译需带 THEOS_PACKAGE_SCHEME=rootless\n'
            ;;
        *)
            printf '  有根 (rootful)   路径无前缀\n'
            ;;
    esac

    printf '\n---- theos 本体 ----\n'
    found=0
    for t in "$THEOS" "$HOME/theos" /var/mobile/theos /var/jb/var/theos /var/jb/theos /var/theos /usr/theos; do
        if [ -n "$t" ] && [ -f "$t/bin/nic.pl" ]; then
            printf '  [OK] theos 已就绪: %s\n' "$t"
            printf '       建议执行: export THEOS=%s\n' "$t"
            found=1
            break
        fi
    done
    if [ "$found" != "1" ]; then
        printf '  [注意] 没找到 theos 本体（nic.pl）\n'
        printf '  theos-dependencies 只是依赖包，theos 本体要另外装（用 mobile 用户，别用 root）:\n'
        printf '\n'
        case "$jb" in
            roothide)
                printf '    bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"\n'
                printf '    ^ RootHide 必须用这个专用版，官方原版认不出随机 jbroot\n'
                ;;
            *)
                printf '    bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"\n'
                ;;
        esac
        printf '\n  装完完全重开终端，再: $THEOS/bin/install-sdk iPhoneOS<版本>\n'
    fi

    printf '\n缺失项安装提示:\n'
    printf '  apt-get update && apt-get install make ldid dpkg git\n'
    printf '  # SDK: 把 iPhoneOS.sdk 放到 \$THEOS/sdks/ 下\n'
    printf '\n如果手机上缺少 SDK，这份工程拷到 Mac 上同样能编译。\n'
}

# ============================================================================
#  把 UI 页面转成 C 字节数组（内嵌进单体 dylib）
# ============================================================================
hx_embed_ui() {
    src="$1"
    dst="$2"
    [ -n "$src" ] && [ -f "$src" ] || return 1
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$src" "$dst" <<'HX_EMBED_PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
out = []
out.append('/* 自动生成：控制面板页面内嵌进 dylib，注入 IPA 后无需外部文件 */\n')
out.append('#include <stddef.h>\n\n')
out.append('const unsigned char hx_embedded_ui[] = {\n')
for i in range(0, len(data), 16):
    chunk = data[i:i+16]
    out.append(','.join('0x%02x' % b for b in chunk) + ',\n')
out.append('};\n')
out.append('const unsigned int hx_embedded_ui_len = %d;\n' % len(data))
open(dst, 'w').write(''.join(out))
HX_EMBED_PY
        [ -f "$dst" ] && return 0
    fi
    if command -v xxd >/dev/null 2>&1; then
        xxd -i -n hx_embedded_ui "$src" > "$dst" && return 0
    fi
    return 1
}

# ============================================================================
#  越狱类型检测：rootful(有根) / rootless(无根 /var/jb) / roothide(隐根 随机jbroot)
# ============================================================================
detect_jb() {
    if [ -n "$HULUXIA_SCHEME" ]; then
        printf '%s' "$HULUXIA_SCHEME"
        return
    fi
    if ls -d /var/containers/Bundle/Application/.jbroot-* >/dev/null 2>&1; then
        printf 'roothide'; return
    fi
    if [ -d /var/jb ]; then
        printf 'rootless'; return
    fi
    if [ -d /Library/MobileSubstrate/DynamicLibraries ]; then
        printf 'rootful'; return
    fi
    printf 'rootful'
}

scheme_prefix() {
    case "$(detect_jb)" in
        roothide) printf '@loader_path/.jbroot' ;;
        rootless) printf '/var/jb' ;;
        *)        printf '' ;;
    esac
}

scheme_arch() {
    case "$(detect_jb)" in
        roothide) printf 'iphoneos-arm64e' ;;
        rootless) printf 'iphoneos-arm64' ;;
        *)        printf 'iphoneos-arm' ;;
    esac
}

# ============================================================================
#  生成 theos 工程
# ============================================================================
gen_project() {
    d="${1:-$DEF_DIR}"
    ui_file="${2:-}"
    sch="$(detect_jb)"
    prefix="$(scheme_prefix)"
    printf '检测到越狱类型: %s\n' "$sch"
    [ -n "$prefix" ] && printf '路径前缀: %s\n' "$prefix"
    mkdir -p "$d/core" "$d/ui" "$d/app" "$d/tweak" "$d/cli" "$d/Resources/AppIcon" "$d/layout/usr/share/huluxia" "$d/layout/DEBIAN"

    # ---------------- 顶层 Makefile（aggregate 聚合三个子工程） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'TARGET := iphone:clang:latest:14.0\n'
        printf 'ARCHS = arm64 arm64e\n'
        printf 'DEBUG = 0\n'
        printf 'THEOS_PACKAGE_DIR_NAME = debs\n'
        printf '\n'
        printf '# 越狱类型: roothide(隐根) / rootless(无根) / 空(有根)\n'
        printf '# 手动指定: make package THEOS_PACKAGE_SCHEME=roothide\n'
        printf '# 永久切换: sh huluxia.sh scheme roothide\n'
        printf 'THEOS_PACKAGE_SCHEME ?= %s\n' "$sch"
        printf '\n'
        printf '# 子工程顺序：先编 dylib，tweak 与 cli 依赖它\n'
        printf 'SUBPROJECTS = core ui app tweak cli\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/aggregate.mk\n'
        printf '\n'
        printf 'before-package::\n'
        printf '\t@mkdir -p $(THEOS_STAGING_DIR)/usr/share/huluxia\n'
        printf '\t@cp -f Resources/ui.html $(THEOS_STAGING_DIR)/usr/share/huluxia/ui.html\n'
        printf '\t@chmod 0644 $(THEOS_STAGING_DIR)/usr/share/huluxia/ui.html\n'
        printf '\t@echo "[葫芦侠] 安装 App 图标"\n'
        printf '\t@cp -f Resources/AppIcon/*.png $(THEOS_STAGING_DIR)/Applications/HuluXia.app/ 2>/dev/null || true\n'
        printf '\t@cp -f Resources/ball.png $(THEOS_STAGING_DIR)/Applications/HuluXia.app/ball.png 2>/dev/null || true\n'
        printf '\t@cp -f app/Info.plist $(THEOS_STAGING_DIR)/Applications/HuluXia.app/Info.plist 2>/dev/null || true\n'
    } > "$d/Makefile"

    # ---------------- control ----------------
    cat > "$d/control" <<'CTRL_EOF'
Package: com.huluxia.ios
Name: 葫芦侠 (iOS 越狱版)
Version: 3.0-1
Architecture: ARCH_PLACEHOLDER
Description: 葫芦侠修改器 - 悬浮窗面板 / 内存搜索修改锁定 / 触摸模拟（私有 API）
Maintainer: huluxia
Author: huluxia
Section: Utilities
Depends: firmware (>= 14.0), mobilesubstrate, network-cmds
Conflicts: com.huluxia.ios.old
Replaces: com.huluxia.ios.old
CTRL_EOF

    # ---------------- deb 安装脚本（setuid root + 刷新图标） ----------------
    cat > "$d/layout/DEBIAN/postinst" <<'POST_EOF'
#!/bin/sh
# ==========================================================================
#  roothide / rootless 通用安装后脚本
#  1) 把 UI 面板放到 /var/mobile —— 该目录在三种越狱下路径一致且可写
#  2) App 设为 setuid root，task_for_pid 才能读改别的进程
#  3) 必须执行 uicache，否则系统 App 未注册，安装会失败
# ==========================================================================

# --- 找 jbroot（roothide 是随机路径，rootless 固定 /var/jb，rootful 为空） ---
JBROOT=""
if command -v jbroot >/dev/null 2>&1; then
    JBROOT="$(jbroot 2>/dev/null)"
fi
if [ -z "$JBROOT" ] && [ -d /var/jb ]; then
    JBROOT="/var/jb"
fi

# --- 1. 部署 UI 面板 ---
mkdir -p /var/mobile/Library/HuluXia 2>/dev/null
for p in "$JBROOT/usr/share/huluxia/ui.html" "/usr/share/huluxia/ui.html" \
         "$JBROOT/var/mobile/Library/HuluXia/ui.html"; do
    if [ -f "$p" ]; then
        cp -f "$p" /var/mobile/Library/HuluXia/ui.html 2>/dev/null && break
    fi
done
chmod 0644 /var/mobile/Library/HuluXia/ui.html 2>/dev/null

# --- 1b. 部署悬浮球图标 ---
for p in "$JBROOT/usr/share/huluxia/ball.png" "/usr/share/huluxia/ball.png"; do
    if [ -f "$p" ]; then
        cp -f "$p" /var/mobile/Library/HuluXia/ball.png 2>/dev/null && break
    fi
done
chmod 0644 /var/mobile/Library/HuluXia/ball.png 2>/dev/null

# --- 2. App 提权 ---
APPBIN=""
for p in "$JBROOT/Applications/HuluXia.app/HuluXia" "/Applications/HuluXia.app/HuluXia"; do
    [ -f "$p" ] && APPBIN="$p" && break
done
if [ -n "$APPBIN" ]; then
    chown root:wheel "$APPBIN" 2>/dev/null
    chmod 4755 "$APPBIN" 2>/dev/null
fi
chmod 0755 "$JBROOT/usr/bin/huluxia" 2>/dev/null
chmod 0755 /usr/bin/huluxia 2>/dev/null

# --- 3. 刷新图标（roothide 下必须，否则安装失败） ---
if command -v uicache >/dev/null 2>&1; then
    uicache -a 2>/dev/null || uicache 2>/dev/null || true
fi
if command -v sbreload >/dev/null 2>&1; then
    sbreload 2>/dev/null || true
fi

echo "[葫芦侠] 安装完成"
echo "[葫芦侠] 面板: /var/mobile/Library/HuluXia/ui.html"
exit 0
POST_EOF

    cat > "$d/layout/DEBIAN/prerm" <<'PRE_EOF'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then
    uicache -p /Applications/HuluXia.app 2>/dev/null || true
fi
exit 0
PRE_EOF

    chmod 0755 "$d/layout/DEBIAN/postinst" "$d/layout/DEBIAN/prerm"

    # ---------------- tweak 注入目标（SpringBoard）----------------
    # theos 要求 filter 文件名与 TWEAK_NAME 一致，且放在该子工程目录内
    cat > "$d/tweak/HuluXiaTweak.plist" <<'FILT_EOF'
{ Filter = { Bundles = ( "com.example.replace-me" ); }; }
FILT_EOF

    sed -i.bak "s|ARCH_PLACEHOLDER|$(scheme_arch)|" "$d/control" && rm -f "$d/control.bak"

    # ---------------- 权限（dylib/tweak/cli 共用） ----------------
    cat > "$d/ent.plist" <<'ENT_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>task_for_pid-allow</key><true/>
    <key>com.apple.system-task-ports</key><true/>
    <key>com.apple.private.hid.client</key><true/>
    <key>com.apple.multitouch.client</key><true/>
    <key>com.apple.iohideventsystem.client</key><true/>
    <key>com.apple.backboardd.client</key><true/>
    <key>com.apple.private.springboard.launch-application</key><true/>
    <key>get-task-allow</key><true/>
</dict>
</plist>
ENT_EOF

    # ---------------- core/Makefile（产出 HuluXia.dylib） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'LIBRARY_NAME = HuluXia\n'
        printf '# 引擎库：纯 Foundation + IOKit，不含 UIKit，命令行也能安全加载\n'
        printf 'HuluXia_FILES = HXEngine.c HXEngineTouch.c HXServer.c HXCore.m\n'
        printf 'HuluXia_INSTALL_PATH = /usr/lib\n'
        printf 'HuluXia_CFLAGS = -I$(shell pwd) -O2 -Wall -Wno-unused-parameter -Wno-deprecated-declarations -fobjc-arc\n'
        printf 'HuluXia_FRAMEWORKS = Foundation CoreFoundation IOKit\n'
        printf 'HuluXia_LDFLAGS = -lpthread\n'
        printf 'ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\n'
        printf 'HuluXia_LDFLAGS += -lroothide -Wl,-rpath,@loader_path/.jbroot/usr/lib\n'
        printf 'endif\n'
        printf 'HuluXia_CODESIGN_FLAGS = -S../ent.plist\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/library.mk\n'
    } > "$d/core/Makefile"

    # ---------------- HXEngine.h ----------------
    cat > "$d/core/HXEngine.h" <<'H_EOF'
#ifndef HX_ENGINE_H
#define HX_ENGINE_H

#include <stdint.h>
#include <stddef.h>

/* 值类型：与葫芦侠 HTML 面板一致 */
#define HX_T_I8    1
#define HX_T_I16   2
#define HX_T_I32   3
#define HX_T_I64   4
#define HX_T_U8    5
#define HX_T_U16   6
#define HX_T_U32   7
#define HX_T_U64   8
#define HX_T_F32   9
#define HX_T_F64   10
#define HX_T_UTF8  11

/* 搜索模式 */
#define HX_M_EXACT     1
#define HX_M_BIGGER    2
#define HX_M_SMALLER   3
#define HX_M_CHANGED   4
#define HX_M_UNCHANGED 5
#define HX_M_FUZZY     6
#define HX_M_RANGE     7
#define HX_M_JOINT     8
#define HX_M_ANY       9

typedef struct {
    uint64_t addr;
    uint8_t  type;
    uint64_t val;      /* 上一轮保存的原始位值，二次搜索的比较基准 */
} hx_res;

/* 类型 / 模式 */
int         hx_type_id(const char *s);
int         hx_type_size(int id);
const char *hx_type_name(int id);
int         hx_mode_id(const char *s);

/* 输出缓冲：命令结果写入缓冲，由调用方取出（供 HTTP / UI / CLI 共用） */
void        hx_out(const char *fmt, ...);
const char *hx_buffer(void);

/* 命令执行：一条命令行 -> 一段文本结果 */
const char *hx_run(const char *cmdline);
int         hx_dispatch(int argc, char **argv);
const char *hx_home(void);

/* 结果集 */
extern hx_res  *hx_results;
extern size_t   hx_results_n;

/* 触摸：IOKit 私有 HID 通道 */
int hx_touch_tap(double x, double y);
int hx_touch_swipe(double x1, double y1, double x2, double y2, int ms, int steps);
int hx_touch_long(double x, double y, int ms);
int hx_touch_down(double x, double y);
int hx_touch_move(double x, double y);
int hx_touch_up(double x, double y);

/* 内置 loopback HTTP（WKWebView 面板用它调宿主 API） */
int  hx_server_start(int port, const char *uipath);
void hx_server_stop(void);
int  hx_server_port(void);

#endif
H_EOF

    # ---------------- HXEngine.c（纯 C：进程 / 内存 / 模块 / 锁定） ----------------
    cat > "$d/core/HXEngine.c" <<'ENGINE_C_EOF'
/* ==========================================================================
 * HXEngine.c —— 葫芦侠 iOS 内核（纯 C，无 OC 依赖）
 * 进程枚举 / 跨进程内存搜索·修改·锁定 / 模块基址
 * 私有 API: task_for_pid, vm_read_overwrite, vm_write, vm_protect,
 *           vm_region_64, sysctl, TASK_DYLD_INFO
 * ========================================================================== */
#include "HXEngine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <strings.h>
#include <ctype.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <sys/resource.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach/task_info.h>

#if defined(__has_include)
#if __has_include(<libproc.h>)
#include <libproc.h>
#define HX_HAVE_LIBPROC 1
#endif
#endif

/* iOS SDK 个别版本不导出该 flavor，这里兜底 */
#ifndef TASK_DYLD_INFO
#define TASK_DYLD_INFO 17
struct task_dyld_info {
    uint64_t all_image_info_addr;
    uint64_t all_image_info_size;
    uint32_t all_image_info_format;
};
#endif

/* 大小写无关子串查找（不依赖 GNU 扩展 strcasestr） */
static char *hx_stristr(const char *hay, const char *needle)
{
    size_t i, n = strlen(needle);
    if (!n) return (char *)hay;
    for (i = 0; hay[i]; i++) {
        size_t j = 0;
        while (j < n && hay[i + j] &&
               tolower((unsigned char)hay[i + j]) == tolower((unsigned char)needle[j])) j++;
        if (j == n) return (char *)(hay + i);
    }
    return NULL;
}

/* ------------------------------------------------------------ 输出缓冲 */
static char  *g_out = NULL;
static size_t g_out_len = 0, g_out_cap = 0;

void hx_out(const char *fmt, ...)
{
    char tmp[1024];
    int n;
    va_list ap;
    va_start(ap, fmt);
    n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if ((size_t)n < sizeof(tmp)) {
        if (g_out_len + (size_t)n + 1 > g_out_cap) {
            size_t nc = g_out_cap ? g_out_cap * 2 : 4096;
            while (g_out_len + (size_t)n + 1 > nc) nc *= 2;
            g_out = (char *)realloc(g_out, nc);
            if (!g_out) { g_out_cap = 0; g_out_len = 0; return; }
            g_out_cap = nc;
        }
        memcpy(g_out + g_out_len, tmp, (size_t)n);
        g_out_len += (size_t)n;
        g_out[g_out_len] = 0;
    } else {
        char *big = (char *)malloc((size_t)n + 1);
        if (!big) return;
        va_start(ap, fmt);
        vsnprintf(big, (size_t)n + 1, fmt, ap);
        va_end(ap);
        if (g_out_len + (size_t)n + 1 > g_out_cap) {
            size_t nc = g_out_cap ? g_out_cap * 2 : 4096;
            while (g_out_len + (size_t)n + 1 > nc) nc *= 2;
            g_out = (char *)realloc(g_out, nc);
            if (!g_out) { free(big); g_out_cap = 0; g_out_len = 0; return; }
            g_out_cap = nc;
        }
        memcpy(g_out + g_out_len, big, (size_t)n);
        g_out_len += (size_t)n;
        g_out[g_out_len] = 0;
        free(big);
    }
}

const char *hx_buffer(void)
{
    return g_out ? g_out : "";
}

static void out_reset(void)
{
    g_out_len = 0;
    if (g_out) g_out[0] = 0;
}

/* ------------------------------------------------------------ 类型 / 模式 */
static const char *kTypeNames[] = {
    "?", "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64", "F32", "F64", "UTF8"
};
static const int kTypeSize[] = { 0, 1, 2, 4, 8, 1, 2, 4, 8, 4, 8, 1 };

int hx_type_id(const char *s)
{
    int i;
    if (!s || !*s) return 0;
    for (i = 1; i <= 11; i++)
        if (strcasecmp(s, kTypeNames[i]) == 0) return i;
    /* 兼容 GameGuardian / VansonMod / 葫芦侠 HTML 面板里的常量名 */
    if (!strcasecmp(s, "BYTE"))   return HX_T_U8;
    if (!strcasecmp(s, "WORD"))   return HX_T_U16;
    if (!strcasecmp(s, "DWORD"))  return HX_T_U32;
    if (!strcasecmp(s, "QWORD"))  return HX_T_U64;
    if (!strcasecmp(s, "FLOAT"))  return HX_T_F32;
    if (!strcasecmp(s, "DOUBLE")) return HX_T_F64;
    if (!strcasecmp(s, "XOR"))    return HX_T_I32;
    if (!strcasecmp(s, "AUTO"))   return HX_T_I32;
    return 0;
}

int hx_type_size(int id)
{
    return (id >= 1 && id <= 11) ? kTypeSize[id] : 0;
}

const char *hx_type_name(int id)
{
    return (id >= 1 && id <= 11) ? kTypeNames[id] : "?";
}

int hx_mode_id(const char *s)
{
    if (!s || !*s) return 0;
    if (!strcasecmp(s, "exact"))                               return HX_M_EXACT;
    if (!strcasecmp(s, "bigger")    || !strcasecmp(s, "increased")) return HX_M_BIGGER;
    if (!strcasecmp(s, "smaller")   || !strcasecmp(s, "decreased")) return HX_M_SMALLER;
    if (!strcasecmp(s, "changed"))                             return HX_M_CHANGED;
    if (!strcasecmp(s, "unchanged"))                           return HX_M_UNCHANGED;
    if (!strcasecmp(s, "fuzzy"))                               return HX_M_FUZZY;
    if (!strcasecmp(s, "range"))                               return HX_M_RANGE;
    if (!strcasecmp(s, "joint"))                               return HX_M_JOINT;
    if (!strcasecmp(s, "any") || !strcasecmp(s, "unknown"))    return HX_M_ANY;
    return 0;
}

/* ------------------------------------------------------------ 工作目录 */
static char g_home[512];

const char *hx_home(void)
{
    static const char *cands[] = {
        "/var/mobile/Library/HuluXia",
        "/var/mobile/Documents/HuluXia",
        "/var/root/.huluxia",
        "/tmp/.huluxia"
    };
    size_t i;
    if (g_home[0]) return g_home;
    for (i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        if (mkdir(cands[i], 0755) == 0 || access(cands[i], W_OK) == 0) {
            strncpy(g_home, cands[i], sizeof(g_home) - 1);
            return g_home;
        }
    }
    return "/tmp";
}

static void home_path(char *out, size_t n, const char *file)
{
    snprintf(out, n, "%s/%s", hx_home(), file);
}

/* ------------------------------------------------------------ 结果集 */
hx_res *hx_results = NULL;
size_t  hx_results_n = 0;
static size_t g_res_cap = 0;
static size_t g_res_limit = 300000;

static void res_clear(void) { hx_results_n = 0; }

static int res_add(uint64_t addr, int type, uint64_t val)
{
    if (hx_results_n >= g_res_limit) return -1;
    if (hx_results_n == g_res_cap) {
        size_t nc = g_res_cap ? g_res_cap * 2 : 8192;
        hx_res *p = (hx_res *)realloc(hx_results, nc * sizeof(hx_res));
        if (!p) return -1;
        hx_results = p;
        g_res_cap = nc;
    }
    hx_results[hx_results_n].addr = addr;
    hx_results[hx_results_n].type = (uint8_t)type;
    hx_results[hx_results_n].val  = val;
    hx_results_n++;
    return 0;
}

static int res_save(void)
{
    char p[512];
    FILE *f;
    home_path(p, sizeof(p), "results.bin");
    f = fopen(p, "wb");
    if (!f) return -1;
    fwrite(hx_results, sizeof(hx_res), hx_results_n, f);
    fclose(f);
    return 0;
}

static int res_load(void)
{
    char p[512];
    FILE *f;
    long sz;
    size_t n;
    home_path(p, sizeof(p), "results.bin");
    f = fopen(p, "rb");
    if (!f) { res_clear(); return -1; }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    n = (size_t)(sz / sizeof(hx_res));
    if (n > g_res_cap) {
        hx_res *pp = (hx_res *)realloc(hx_results, n * sizeof(hx_res));
        if (!pp) { fclose(f); return -1; }
        hx_results = pp;
        g_res_cap = n;
    }
    n = fread(hx_results, sizeof(hx_res), n, f);
    fclose(f);
    hx_results_n = n;
    return 0;
}

/* -------------------------------------------------------- 目标进程 / task */
static pid_t       g_pid  = -1;
static mach_port_t g_task = MACH_PORT_NULL;
static int         g_task_bad = 0;

static int target_open(void)
{
    char p[512];
    FILE *f;
    kern_return_t kr;
    if (g_task != MACH_PORT_NULL) return 0;
    if (g_task_bad) { hx_out("task_for_pid 之前失败，请检查权限/entitlement\n"); return 1; }
    home_path(p, sizeof(p), "pid");
    f = fopen(p, "r");
    if (!f) { hx_out("未选择目标进程，请先执行: sel <pid>（sel 0 = 自身进程）\n"); return 1; }
    if (fscanf(f, "%d", &g_pid) != 1) { fclose(f); hx_out("目标文件损坏\n"); return 1; }
    fclose(f);
    /* sel 0 / 自身 pid：直接用 mach_task_self()，不依赖 task_for_pid 权限。
       把 dylib 注入目标 App 后用这种方式，成功率 100%。 */
    if (g_pid == 0 || g_pid == (int)getpid()) {
        g_task = mach_task_self();
        g_pid  = (int)getpid();
        return 0;
    }
    /* 私有权限接口：需要 task_for_pid-allow / com.apple.system-task-ports */
    kr = task_for_pid(mach_task_self(), g_pid, &g_task);
    if (kr != KERN_SUCCESS) {
        hx_out("task_for_pid(%d) 失败: %s\n", g_pid, mach_error_string(kr));
        hx_out("请确认：以 root 运行 + 已 ldid 签 ent.plist + 越狱未限制 task port\n");
        g_task_bad = 1;
        g_pid = -1;
        return 1;
    }
    return 0;
}

static void target_drop(void)
{
    if (g_task != MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(), g_task); g_task = MACH_PORT_NULL; }
    g_task_bad = 0;
    g_pid = -1;
}

static const char *proc_name_of(pid_t pid)
{
    static char buf[256];
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    buf[0] = 0;
    if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len > 0)
        snprintf(buf, sizeof(buf), "%s", kp.kp_proc.p_comm);
    return buf;
}

static void proc_path_of(pid_t pid, char *out, size_t n)
{
    out[0] = 0;
#ifdef HX_HAVE_LIBPROC
    if (proc_pidpath(pid, out, (uint32_t)n) <= 0) out[0] = 0;
#else
    (void)pid;
#endif
}

/* /var/containers/Bundle/.../X.app/X  ->  X */
static void app_label_of(const char *path, char *out, size_t n)
{
    const char *p, *q;
    size_t i = 0;
    out[0] = 0;
    if (!path || !*path) return;
    q = strstr(path, ".app/");
    if (!q) { snprintf(out, n, "%s", path); return; }
    p = q;
    while (p > path && *(p - 1) != '/') p--;
    while (p < q && i < n - 1) out[i++] = *p++;
    out[i] = 0;
}

/* ------------------------------------------------------------ 数值工具 */
static uint64_t size_mask(int sz)
{
    if (sz >= 8) return ~0ULL;
    return (1ULL << (8 * sz)) - 1ULL;
}

static uint64_t parse_value(const char *s, int id)
{
    uint64_t out = 0;
    if (id == HX_T_F32) {
        float f = (float)strtod(s, NULL);
        uint32_t t;
        memcpy(&t, &f, 4);
        out = (uint64_t)t;
    } else if (id == HX_T_F64) {
        double d = strtod(s, NULL);
        memcpy(&out, &d, 8);
    } else if (id >= HX_T_U8 && id <= HX_T_U64) {
        out = strtoull(s, NULL, 0) & size_mask(kTypeSize[id]);
    } else {
        long long v = strtoll(s, NULL, 0);
        memcpy(&out, &v, 8);
        out &= size_mask(kTypeSize[id]);
    }
    return out;
}

static double as_double(int id, uint64_t raw)
{
    if (id == HX_T_F32) { float f; uint32_t t = (uint32_t)raw; memcpy(&f, &t, 4); return (double)f; }
    if (id == HX_T_F64) { double d; memcpy(&d, &raw, 8); return d; }
    return 0.0;
}

static int64_t as_signed(int id, uint64_t raw)
{
    switch (id) {
    case HX_T_I8:  return (int64_t)(int8_t)(uint8_t)raw;
    case HX_T_I16: return (int64_t)(int16_t)(uint16_t)raw;
    case HX_T_I32: return (int64_t)(int32_t)(uint32_t)raw;
    default:       return (int64_t)raw;
    }
}

static uint64_t as_unsigned(int id, uint64_t raw)
{
    return raw & size_mask(kTypeSize[id]);
}

static void fmt_value(char *buf, size_t n, int id, uint64_t raw)
{
    if (id == HX_T_F32 || id == HX_T_F64)
        snprintf(buf, n, "%g", as_double(id, raw));
    else if (id >= HX_T_U8 && id <= HX_T_U64)
        snprintf(buf, n, "%llu", (unsigned long long)as_unsigned(id, raw));
    else
        snprintf(buf, n, "%lld", (long long)as_signed(id, raw));
}

/* 返回 1 命中 */
static int value_match(int id, int mode, uint64_t cur, uint64_t old,
                       uint64_t tgt, uint64_t tgt2, double tol)
{
    if (id == HX_T_F32 || id == HX_T_F64) {
        double c = as_double(id, cur), o = as_double(id, old);
        double t = as_double(id, tgt), t2 = as_double(id, tgt2);
        switch (mode) {
        case HX_M_EXACT:     return (c == t);
        case HX_M_BIGGER:    return (c > o);
        case HX_M_SMALLER:   return (c < o);
        case HX_M_CHANGED:   return (c != o);
        case HX_M_UNCHANGED: return (c == o);
        case HX_M_FUZZY:     return (c >= t - tol && c <= t + tol);
        case HX_M_RANGE:     return (c >= t && c <= t2);
        case HX_M_JOINT:     return (c >= t && c <= t2 && c != o);
        default:             return 1;
        }
    } else if (id >= HX_T_U8 && id <= HX_T_U64) {
        uint64_t c = as_unsigned(id, cur), o = as_unsigned(id, old);
        uint64_t t = as_unsigned(id, tgt), t2 = as_unsigned(id, tgt2);
        uint64_t d = (uint64_t)tol;
        switch (mode) {
        case HX_M_EXACT:     return (c == t);
        case HX_M_BIGGER:    return (c > o);
        case HX_M_SMALLER:   return (c < o);
        case HX_M_CHANGED:   return (c != o);
        case HX_M_UNCHANGED: return (c == o);
        case HX_M_FUZZY:     return (c >= t - d && c <= t + d);
        case HX_M_RANGE:     return (c >= t && c <= t2);
        case HX_M_JOINT:     return (c >= t && c <= t2 && c != o);
        default:             return 1;
        }
    } else {
        int64_t c = as_signed(id, cur), o = as_signed(id, old);
        int64_t t = (int64_t)as_signed(id, tgt), t2 = (int64_t)as_signed(id, tgt2);
        int64_t d = (int64_t)tol;
        switch (mode) {
        case HX_M_EXACT:     return (c == t);
        case HX_M_BIGGER:    return (c > o);
        case HX_M_SMALLER:   return (c < o);
        case HX_M_CHANGED:   return (c != o);
        case HX_M_UNCHANGED: return (c == o);
        case HX_M_FUZZY:     return (c >= t - d && c <= t + d);
        case HX_M_RANGE:     return (c >= t && c <= t2);
        case HX_M_JOINT:     return (c >= t && c <= t2 && c != o);
        default:             return 1;
        }
    }
}

/* ------------------------------------------------------------ 内存读写 */
static int mem_read(uint64_t addr, int sz, uint64_t *out)
{
    uint8_t b[8];
    vm_size_t got = 0;
    kern_return_t kr;
    *out = 0;
    if (target_open()) return -1;
    kr = vm_read_overwrite(g_task, (vm_address_t)addr, (vm_size_t)sz,
                           (vm_address_t)b, &got);
    if (kr != KERN_SUCCESS || got != (vm_size_t)sz) return -1;
    memcpy(out, b, sz);
    *out &= size_mask(sz);
    return 0;
}

static int mem_write(uint64_t addr, int id, uint64_t raw)
{
    uint8_t b[8];
    int sz = kTypeSize[id];
    kern_return_t kr;
    if (target_open()) return -1;
    memcpy(b, &raw, 8);                        /* 小端：低字节在前 */
    /* 先放开写保护，写完不还原（锁定/修改场景需要保持可写） */
    vm_protect(g_task, (vm_address_t)addr, (vm_size_t)sz, 0,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    kr = vm_write(g_task, (vm_address_t)addr, (vm_offset_t)b,
                  (mach_msg_type_number_t)sz);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

static int mem_read_buf(uint64_t addr, uint8_t *buf, vm_size_t len, vm_size_t *got)
{
    kern_return_t kr;
    *got = 0;
    kr = vm_read_overwrite(g_task, (vm_address_t)addr, len,
                           (vm_address_t)buf, got);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

static int mem_read_cstr(uint64_t addr, char *out, size_t n)
{
    size_t off = 0;
    while (off < n - 1) {
        vm_size_t got = 0;
        if (mem_read_buf(addr + off, (uint8_t *)(out + off), 1, &got) != 0 || got != 1) break;
        if (out[off] == 0) break;
        off++;
    }
    out[off] = 0;
    return (int)off;
}

/* -------------------------------------------------------------- 命令 */
static int cmd_ps(int argc, char **argv)
{
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    struct kinfo_proc *procs;
    size_t len = 0;
    size_t n, i;
    int only_app = 0;
    (void)argc;
    if (argc > 1 && (!strcmp(argv[1], "app") || !strcmp(argv[1], "--app"))) only_app = 1;

    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) {
        hx_out("sysctl 失败\n");
        return 1;
    }
    procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return 1;
    if (sysctl(mib, 3, procs, &len, NULL, 0) != 0) { free(procs); return 1; }
    n = len / sizeof(struct kinfo_proc);
    hx_out("%-8s %-26s %s\n", "PID", "NAME", "PATH");
    for (i = 0; i < n; i++) {
        char path[1024], label[256];
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        proc_path_of(pid, path, sizeof(path));
        if (only_app && !strstr(path, "/var/containers/")) continue;
        app_label_of(path, label, sizeof(label));
        if (label[0])
            hx_out("%-8d %-26s %s\n", pid, label, path);
        else
            hx_out("%-8d %-26s %s\n", pid, procs[i].kp_proc.p_comm, path);
    }
    free(procs);
    return 0;
}

static int cmd_sel(int argc, char **argv)
{
    char p[512];
    FILE *f;
    pid_t pid;
    if (argc < 2) { hx_out("用法: sel <pid|进程名>\n"); return 1; }
    if (sscanf(argv[1], "%d", &pid) != 1) {
        int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
        struct kinfo_proc *procs;
        size_t len = 0, n, i;
        pid = -1;
        if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len > 0) {
            procs = (struct kinfo_proc *)malloc(len);
            if (procs && sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
                n = len / sizeof(struct kinfo_proc);
                for (i = 0; i < n; i++) {
                    if (strcasecmp(procs[i].kp_proc.p_comm, argv[1]) == 0 ||
                        strstr(procs[i].kp_proc.p_comm, argv[1]) != NULL) {
                        pid = procs[i].kp_proc.p_pid;
                        break;
                    }
                }
            }
            free(procs);
        }
        if (pid <= 0) { hx_out("未找到进程: %s\n", argv[1]); return 1; }
    }
    home_path(p, sizeof(p), "pid");
    f = fopen(p, "w");
    if (!f) { hx_out("无法写入 %s\n", p); return 1; }
    fprintf(f, "%d\n", pid);
    fclose(f);
    target_drop();
    res_clear();
    if (pid == 0)
        hx_out("已选择目标: 自身进程 (%d)，走 mach_task_self()，不需要 task_for_pid\n", (int)getpid());
    else
        hx_out("已选择目标: %d (%s)\n", pid, proc_name_of(pid));
    return 0;
}

static int cmd_target(int argc, char **argv)
{
    char p[512], path[1024], label[256];
    FILE *f;
    int pid = 0;
    (void)argc; (void)argv;
    home_path(p, sizeof(p), "pid");
    f = fopen(p, "r");
    if (!f) { hx_out("未选择\n"); return 1; }
    if (fscanf(f, "%d", &pid) != 1) { fclose(f); hx_out("未选择\n"); return 1; }
    fclose(f);
    proc_path_of((pid_t)pid, path, sizeof(path));
    app_label_of(path, label, sizeof(label));
    if (pid == 0) pid = (int)getpid();   /* sel 0 = 自身进程 */
    hx_out("pid=%d\n", pid);
    hx_out("name=%s\n", proc_name_of((pid_t)pid));
    hx_out("package=%s\n", label[0] ? label : proc_name_of((pid_t)pid));
    hx_out("path=%s\n", path);
    return 0;
}

static int cmd_regions(int argc, char **argv)
{
    vm_address_t addr = 0;
    vm_size_t rsize = 0;
    int count = 0, only_rw = 1;
    int i;
    if (argc > 1 && !strcmp(argv[1], "all")) only_rw = 0;
    if (target_open()) return 1;
    hx_out("%-20s %-20s %-12s %s\n", "START", "END", "SIZE", "PROT");
    for (i = 0; i < 20000; i++) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        char prot[8];
        kern_return_t kr = vm_region_64(g_task, &addr, &rsize, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS) break;
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if (only_rw && !(info.protection & VM_PROT_WRITE)) { addr += rsize; continue; }
        snprintf(prot, sizeof(prot), "%c%c%c",
                 (info.protection & VM_PROT_READ) ? 'r' : '-',
                 (info.protection & VM_PROT_WRITE) ? 'w' : '-',
                 (info.protection & VM_PROT_EXECUTE) ? 'x' : '-');
        hx_out("0x%016llx 0x%016llx %-12llu %s\n",
               (unsigned long long)addr,
               (unsigned long long)(addr + rsize),
               (unsigned long long)rsize, prot);
        count++;
        addr += rsize;
    }
    hx_out("共 %d 个区域\n", count);
    return 0;
}

#define CHUNK_SIZE (1 << 20)

static uint8_t *g_buf = NULL;
static size_t   g_buf_cap = 0;

static int ensure_buf(void)
{
    if (g_buf_cap < CHUNK_SIZE + 64) {
        uint8_t *p = (uint8_t *)realloc(g_buf, CHUNK_SIZE + 64);
        if (!p) return -1;
        g_buf = p;
        g_buf_cap = CHUNK_SIZE + 64;
    }
    return 0;
}

static int scan_region(uint64_t base, vm_size_t size, int id, int mode,
                       uint64_t tgt, uint64_t tgt2, double tol,
                       const uint8_t *pat, size_t patlen)
{
    vm_size_t off = 0;
    int tsz = kTypeSize[id];
    size_t step = (id == HX_T_UTF8) ? 1 : (size_t)tsz;
    uint64_t mask = size_mask(tsz);

    while (off < size) {
        vm_size_t want = size - off;
        vm_size_t got = 0;
        size_t i;
        if (want > CHUNK_SIZE) want = CHUNK_SIZE;
        if (mem_read_buf(base + off, g_buf, want, &got) != 0 || got == 0) {
            off += (want < 4096 ? want : 4096);
            continue;
        }
        if (got > want) got = want;
        for (i = 0; i + tsz <= (size_t)got; i += step) {
            uint64_t raw = 0;
            int hit = 0;
            if (id == HX_T_UTF8) {
                if (patlen && (size_t)got - i >= patlen && memcmp(g_buf + i, pat, patlen) == 0) hit = 1;
            } else {
                memcpy(&raw, g_buf + i, tsz);
                raw &= mask;
                hit = value_match(id, mode, raw, 0, tgt, tgt2, tol);
            }
            if (hit && res_add(base + off + i, id, raw) != 0) return 1;
        }
        off += want;
    }
    return 0;
}

static int cmd_search(int argc, char **argv)
{
    const char *vs = NULL, *ts = "I32", *his = NULL;
    int mode = HX_M_EXACT, id, all_prot = 0;
    uint64_t tgt = 0, tgt2 = 0, from = 0, to = ~0ULL;
    double tol = 0;
    vm_address_t addr = 0;
    vm_size_t rsize = 0;
    int i, nscan = 0, loop;
    const uint8_t *pat = NULL;
    size_t patlen = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mode") && i + 1 < argc) { mode = hx_mode_id(argv[++i]); continue; }
        if (!strcmp(argv[i], "--from") && i + 1 < argc) { from = strtoull(argv[++i], NULL, 0); continue; }
        if (!strcmp(argv[i], "--to")   && i + 1 < argc) { to   = strtoull(argv[++i], NULL, 0); continue; }
        if (!strcmp(argv[i], "--tol")  && i + 1 < argc) { tol  = strtod(argv[++i], NULL); continue; }
        if (!strcmp(argv[i], "--hi")   && i + 1 < argc) { his  = argv[++i]; continue; }
        if (!strcmp(argv[i], "--limit")&& i + 1 < argc) { g_res_limit = (size_t)strtoull(argv[++i], NULL, 0); continue; }
        if (!strcmp(argv[i], "--all"))  { all_prot = 1; continue; }
        if (!vs) { vs = argv[i]; continue; }
        if (hx_type_id(argv[i])) { ts = argv[i]; continue; }
        if (hx_mode_id(argv[i]) && !strpbrk(argv[i], "0123456789")) { mode = hx_mode_id(argv[i]); continue; }
        his = argv[i];
    }
    if (!vs) {
        hx_out("用法: search <值> [类型] [模式] [--mode m] [--from a] [--to a] [--hi 上界] [--tol n] [--all]\n");
        return 1;
    }
    id = hx_type_id(ts);
    if (!id) { hx_out("未知类型: %s\n", ts); return 1; }
    if (id == HX_T_UTF8) { pat = (const uint8_t *)vs; patlen = strlen(vs); }
    else tgt = parse_value(vs, id);
    if (his) {
        if (id == HX_T_F32 || id == HX_T_F64) tol = strtod(his, NULL);
        else tgt2 = parse_value(his, id);
    } else if ((mode == HX_M_RANGE || mode == HX_M_JOINT) && tgt2 == 0 && tol == 0) {
        tgt2 = tgt;
    }
    if (target_open()) return 1;
    if (ensure_buf()) return 1;
    res_clear();

    for (loop = 0; loop < 20000; loop++) {
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(g_task, &addr, &rsize, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &cnt, &obj);
        if (kr != KERN_SUCCESS) break;
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if ((info.protection & VM_PROT_READ) &&
            (all_prot || (info.protection & VM_PROT_WRITE))) {
            uint64_t rbase = (uint64_t)addr, rend = (uint64_t)addr + rsize;
            uint64_t s = rbase > from ? rbase : from;
            uint64_t e = rend < to ? rend : to;
            if (s < e) {
                nscan++;
                if (scan_region(s, (vm_size_t)(e - s), id, mode, tgt, tgt2, tol, pat, patlen))
                    break;
            }
        }
        addr += rsize;
        if (hx_results_n >= g_res_limit) break;
    }
    res_save();
    hx_out("扫描区域 %d 个，找到 %zu 个结果\n", nscan, hx_results_n);
    if (hx_results_n >= g_res_limit) hx_out("(已达上限 %zu，可用 --limit 提高)\n", g_res_limit);
    return 0;
}

static int cmd_refine(int argc, char **argv)
{
    const char *vs = NULL, *ts = NULL, *ms = "exact";
    int mode, id = -1, tsz;
    uint64_t tgt = 0, tgt2 = 0;
    double tol = 0;
    size_t i, w = 0;
    hx_res *out;
    int ai;

    /* 参数任意顺序：识别模式名 / 类型名 / 数值 */
    for (ai = 1; ai < argc; ai++) {
        const char *a = argv[ai];
        if (!strcmp(a, "--tol") && ai + 1 < argc) { tol = strtod(argv[++ai], NULL); continue; }
        if (!strcmp(a, "--hi") && ai + 1 < argc) {
            if (!vs) { hx_out("--hi 需要配合主值使用\n"); return 1; }
            tgt2 = parse_value(argv[++ai], id > 0 ? id : HX_T_I32);
            continue;
        }
        if (hx_mode_id(a) && !strpbrk(a, "0123456789")) { ms = a; continue; }
        if (hx_type_id(a)) { ts = a; continue; }
        if (!vs) { vs = a; continue; }
        if (!ts) { ts = a; continue; }
    }
    mode = hx_mode_id(ms);
    if (!mode) { hx_out("未知模式: %s\n", ms); return 1; }
    if (res_load() != 0 || hx_results_n == 0) { hx_out("暂无结果，请先 search\n"); return 1; }
    if (vs) {
        int tid = hx_type_id(ts ? ts : "I32");
        if (!tid) tid = hx_results[0].type;
        id = tid;
        tgt = parse_value(vs, id);
    }
    if (target_open()) return 1;
    out = (hx_res *)malloc((hx_results_n ? hx_results_n : 1) * sizeof(hx_res));
    if (!out) return 1;

    for (i = 0; i < hx_results_n; i++) {
        uint64_t cur = 0;
        int rid = id > 0 ? id : hx_results[i].type;
        if (rid == HX_T_UTF8) continue;
        tsz = kTypeSize[rid];
        if (mem_read(hx_results[i].addr, tsz, &cur) != 0) continue;
        if (value_match(rid, mode, cur, hx_results[i].val, tgt, tgt2, tol)) {
            out[w].addr = hx_results[i].addr;
            out[w].type = (uint8_t)rid;
            out[w].val  = cur;
            w++;
        }
    }
    memcpy(hx_results, out, w * sizeof(hx_res));
    hx_results_n = w;
    free(out);
    res_save();
    hx_out("剩余 %zu 个结果\n", hx_results_n);
    return 0;
}

static int cmd_count(int argc, char **argv)
{
    (void)argc; (void)argv;
    if (hx_results_n == 0) res_load();
    hx_out("%zu\n", hx_results_n);
    return 0;
}

static int cmd_list(int argc, char **argv)
{
    size_t off = 0, limit = 100, i;
    if (argc > 1) off = (size_t)strtoull(argv[1], NULL, 0);
    if (argc > 2) limit = (size_t)strtoull(argv[2], NULL, 0);
    if (hx_results_n == 0) res_load();
    if (target_open()) return 1;
    hx_out("%-20s %-6s %s\n", "ADDRESS", "TYPE", "VALUE");
    for (i = off; i < hx_results_n && i < off + limit; i++) {
        char vb[64];
        uint64_t cur = 0;
        int tsz = kTypeSize[hx_results[i].type];
        if (mem_read(hx_results[i].addr, tsz, &cur) != 0) snprintf(vb, sizeof(vb), "?");
        else fmt_value(vb, sizeof(vb), hx_results[i].type, cur);
        hx_out("0x%016llx %-6s %s\n",
               (unsigned long long)hx_results[i].addr,
               hx_type_name(hx_results[i].type), vb);
    }
    hx_out("(共 %zu 个)\n", hx_results_n);
    return 0;
}

static int cmd_read(int argc, char **argv)
{
    uint64_t addr, raw;
    int id = HX_T_I32;
    char vb[64];
    if (argc < 2) { hx_out("用法: read <addr> [类型]\n"); return 1; }
    addr = strtoull(argv[1], NULL, 0);
    if (argc > 2) { id = hx_type_id(argv[2]); if (!id) { hx_out("未知类型\n"); return 1; } }
    if (mem_read(addr, kTypeSize[id], &raw) != 0) { hx_out("读取失败\n"); return 1; }
    fmt_value(vb, sizeof(vb), id, raw);
    hx_out("%s\n", vb);
    return 0;
}

static int cmd_write(int argc, char **argv)
{
    uint64_t addr, raw;
    int id = HX_T_I32;
    if (argc < 3) { hx_out("用法: write <addr> <值> [类型]\n"); return 1; }
    addr = strtoull(argv[1], NULL, 0);
    if (argc > 3) { id = hx_type_id(argv[3]); if (!id) { hx_out("未知类型\n"); return 1; } }
    raw = parse_value(argv[2], id);
    if (mem_write(addr, id, raw) != 0) { hx_out("写入失败 (vm_write)\n"); return 1; }
    hx_out("ok 0x%llx -> %s\n", (unsigned long long)addr, argv[2]);
    return 0;
}

static int cmd_editall(int argc, char **argv)
{
    uint64_t raw;
    int id = HX_T_I32;
    size_t i, ok = 0, limit = (size_t)-1;
    if (argc < 2) { hx_out("用法: editall <值> [类型] [条数]\n"); return 1; }
    if (argc > 2) { int t = hx_type_id(argv[2]); if (t) id = t; }
    if (argc > 3) limit = (size_t)strtoull(argv[3], NULL, 0);
    raw = parse_value(argv[1], id);
    if (hx_results_n == 0) res_load();
    if (target_open()) return 1;
    for (i = 0; i < hx_results_n && ok < limit; i++) {
        if (mem_write(hx_results[i].addr, id, raw) == 0) ok++;
    }
    hx_out("已修改 %zu / %zu 个地址\n", ok, hx_results_n);
    return 0;
}

static int cmd_clear(int argc, char **argv)
{
    (void)argc; (void)argv;
    res_clear();
    res_save();
    hx_out("结果已清空\n");
    return 0;
}

/* --------------------------------------------------------- 冻结 / 锁定 */
static void freeze_path(char *out, size_t n)
{
    home_path(out, n, "freeze.txt");
}

static int cmd_freeze(int argc, char **argv)
{
    char p[512];
    if (argc < 2) {
        hx_out("用法: freeze add <addr> <值> [类型] | del <addr> | list | clear\n");
        return 1;
    }
    freeze_path(p, sizeof(p));
    if (!strcmp(argv[1], "add")) {
        FILE *f;
        if (argc < 4) { hx_out("用法: freeze add <addr> <值> [类型]\n"); return 1; }
        f = fopen(p, "a");
        if (!f) return 1;
        fprintf(f, "%s %s %s\n", argv[2], argv[3], argc > 4 ? argv[4] : "I32");
        fclose(f);
        hx_out("已加入锁定列表\n");
        return 0;
    }
    if (!strcmp(argv[1], "del")) {
        FILE *f, *g;
        char line[512], tmp[512];
        if (argc < 3) return 1;
        home_path(tmp, sizeof(tmp), "freeze.tmp");
        f = fopen(p, "r"); g = fopen(tmp, "w");
        if (!f) return 1;
        while (fgets(line, sizeof(line), f)) {
            char a[64];
            sscanf(line, "%63s", a);
            if (strtoull(a, NULL, 0) == strtoull(argv[2], NULL, 0)) continue;
            if (g) fputs(line, g);
        }
        fclose(f); if (g) fclose(g);
        rename(tmp, p);
        hx_out("已移除\n");
        return 0;
    }
    if (!strcmp(argv[1], "list")) {
        FILE *f; char line[512]; int n = 0;
        f = fopen(p, "r");
        if (!f) { hx_out("(空)\n"); return 0; }
        while (fgets(line, sizeof(line), f)) { hx_out("%s", line); n++; }
        fclose(f);
        hx_out("共 %d 条\n", n);
        return 0;
    }
    if (!strcmp(argv[1], "clear")) {
        FILE *f = fopen(p, "w");
        if (f) fclose(f);
        hx_out("已清空\n");
        return 0;
    }
    return 1;
}

/* 锁定守护：持续把冻结值写回目标进程 */
static volatile int g_daemon_run = 0;

static int cmd_freeze_tick(int argc, char **argv)
{
    char p[512];
    FILE *f;
    char line[512];
    int n = 0;
    (void)argc; (void)argv;
    freeze_path(p, sizeof(p));
    f = fopen(p, "r");
    if (!f) return 0;
    if (target_open()) { fclose(f); return 0; }
    while (fgets(line, sizeof(line), f)) {
        char as[64], vs[64], ts[32];
        int id;
        uint64_t addr, raw;
        if (sscanf(line, "%63s %63s %31s", as, vs, ts) != 3) continue;
        id = hx_type_id(ts);
        if (!id) id = HX_T_I32;
        addr = strtoull(as, NULL, 0);
        raw  = parse_value(vs, id);
        if (mem_write(addr, id, raw) == 0) n++;
    }
    fclose(f);
    return n;
}

static int cmd_daemon(int argc, char **argv)
{
    int interval = 200;
    if (argc > 1) interval = atoi(argv[1]);
    if (interval < 20) interval = 20;
    g_daemon_run = 1;
    hx_out("锁定守护已启动（间隔 %d ms）\n", interval);
    while (g_daemon_run) {
        cmd_freeze_tick(0, NULL);
        usleep((useconds_t)interval * 1000);
    }
    return 0;
}

static int cmd_daemon_stop(int argc, char **argv)
{
    (void)argc; (void)argv;
    g_daemon_run = 0;
    hx_out("守护已停止\n");
    return 0;
}

static int cmd_tick(int argc, char **argv)
{
    int n = cmd_freeze_tick(argc, argv);
    hx_out("已写回 %d 条\n", n);
    return 0;
}

/* ------------------------------------------------- 自动锁定（后台线程） */
static pthread_t      g_lock_th;
static volatile int   g_lock_run = 0;
static int            g_lock_ms  = 300;

static void *lock_thread(void *arg)
{
    (void)arg;
    while (g_lock_run) {
        cmd_freeze_tick(0, NULL);
        usleep((useconds_t)g_lock_ms * 1000);
    }
    return NULL;
}

static int cmd_autolock(int argc, char **argv)
{
    if (argc < 2) {
        hx_out("用法: autolock on [间隔ms] | off | status\n");
        return 1;
    }
    if (!strcmp(argv[1], "on")) {
        if (argc > 2) { int v = atoi(argv[2]); if (v >= 20) g_lock_ms = v; }
        if (g_lock_run) { hx_out("自动锁定已在运行（%d ms）\n", g_lock_ms); return 0; }
        g_lock_run = 1;
        pthread_create(&g_lock_th, NULL, lock_thread, NULL);
        hx_out("自动锁定已开启（间隔 %d ms）\n", g_lock_ms);
        return 0;
    }
    if (!strcmp(argv[1], "off")) {
        g_lock_run = 0;
        hx_out("自动锁定已关闭\n");
        return 0;
    }
    if (!strcmp(argv[1], "status")) {
        hx_out("自动锁定: %s（间隔 %d ms）\n", g_lock_run ? "运行中" : "已停止", g_lock_ms);
        return 0;
    }
    hx_out("用法: autolock on [间隔ms] | off | status\n");
    return 1;
}

/* ------------------------------------------------------------ 模块遍历 */
static int cmd_modules(int argc, char **argv)
{
    struct task_dyld_info info;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    kern_return_t kr;
    uint64_t infos_addr, arr;
    const char *filter = (argc > 1) ? argv[1] : NULL;
    int i;

    if (target_open()) return 1;
    memset(&info, 0, sizeof(info));
    kr = task_info(g_task, TASK_DYLD_INFO, (task_info_t)&info, &cnt);
    if (kr != KERN_SUCCESS) {
        hx_out("task_info(TASK_DYLD_INFO) 失败: %s\n", mach_error_string(kr));
        return 1;
    }
    infos_addr = (uint64_t)(uintptr_t)info.all_image_info_addr;
    if (!infos_addr) { hx_out("无法获取 dyld 信息\n"); return 1; }
    /* struct dyld_all_image_infos: u32 version, u32 timestamp, ptr infoArray */
    if (mem_read(infos_addr + 8, 8, &arr) != 0 || !arr) { hx_out("无法定位 image 数组\n"); return 1; }

    hx_out("%-20s %-20s %s\n", "BASE", "END", "NAME");
    for (i = 0; i < 2048; i++) {
        uint64_t load = 0, pathp = 0;
        char path[1024], *name;
        uint64_t end = 0;
        if (mem_read(arr + (uint64_t)i * 24, 8, &load) != 0 || load == 0) break;
        if (mem_read(arr + (uint64_t)i * 24 + 8, 8, &pathp) != 0 || pathp == 0) continue;
        if (mem_read_cstr(pathp, path, sizeof(path)) <= 0) continue;
        if (filter && !hx_stristr(path, filter)) continue;
        name = strrchr(path, '/');
        name = name ? name + 1 : path;
        {
            vm_address_t a = (vm_address_t)load;
            vm_size_t rs = 0;
            vm_region_basic_info_data_64_t bi;
            mach_msg_type_number_t bc = VM_REGION_BASIC_INFO_COUNT_64;
            mach_port_t obj = MACH_PORT_NULL;
            if (vm_region_64(g_task, &a, &rs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &bc, &obj) == KERN_SUCCESS) {
                if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
                if ((vm_address_t)load >= a) end = (uint64_t)a + rs;
            }
        }
        hx_out("0x%016llx 0x%016llx %s\n",
               (unsigned long long)load, (unsigned long long)end, name);
    }
    return 0;
}

static int cmd_offset(int argc, char **argv)
{
    uint64_t addr = 0, off = 0;
    if (argc < 3) { hx_out("用法: offset <模块名|基址> <偏移>\n"); return 1; }
    if (strncasecmp(argv[1], "0x", 2) == 0 || isdigit((unsigned char)argv[1][0])) {
        addr = strtoull(argv[1], NULL, 0);
    } else {
        struct task_dyld_info info;
        mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
        uint64_t infos_addr, arr;
        int i;
        if (target_open()) return 1;
        if (task_info(g_task, TASK_DYLD_INFO, (task_info_t)&info, &cnt) != KERN_SUCCESS) return 1;
        infos_addr = (uint64_t)(uintptr_t)info.all_image_info_addr;
        if (mem_read(infos_addr + 8, 8, &arr) != 0) return 1;
        for (i = 0; i < 2048; i++) {
            uint64_t load = 0, pathp = 0;
            char path[1024];
            if (mem_read(arr + (uint64_t)i * 24, 8, &load) != 0 || load == 0) break;
            if (mem_read(arr + (uint64_t)i * 24 + 8, 8, &pathp) != 0) continue;
            if (mem_read_cstr(pathp, path, sizeof(path)) <= 0) continue;
            if (hx_stristr(path, argv[1])) { addr = load; break; }
        }
        if (!addr) { hx_out("未找到模块: %s\n", argv[1]); return 1; }
    }
    off = strtoull(argv[2], NULL, 0);
    hx_out("0x%llx\n", (unsigned long long)(addr + off));
    return 0;
}

/* ------------------------------------------------------------ 变速（私有） */
static int cmd_speed(int argc, char **argv)
{
    int prio = 0;
    pid_t pid = 0;
    char p[512];
    FILE *f;
    if (argc < 2) { hx_out("用法: speed <倍率 0.1-5>\n"); return 1; }
    home_path(p, sizeof(p), "pid");
    f = fopen(p, "r");
    if (!f) { hx_out("未选择进程\n"); return 1; }
    if (fscanf(f, "%d", &pid) != 1) { fclose(f); return 1; }
    fclose(f);
    prio = (int)(atof(argv[1]) * 10);
    if (prio < -20) prio = -20;
    if (prio > 20) prio = 20;
    if (setpriority(PRIO_PROCESS, (id_t)pid, prio) != 0) {
        hx_out("setpriority 失败: %s\n", strerror(errno));
        return 1;
    }
    hx_out("已设置调度优先级 %d（配合注入式 hook 可做真实变速）\n", prio);
    return 0;
}

static int cmd_info(int argc, char **argv)
{
    struct utsname u;
    (void)argc; (void)argv;
    uname(&u);
    hx_out("葫芦侠 iOS v2.0 (越狱 · 私有 API)\n");
    hx_out("设备: %s %s\n", u.machine, u.release);
    hx_out("数据目录: %s\n", hx_home());
    cmd_target(0, NULL);
    return 0;
}

static void print_help(void)
{
    hx_out("葫芦侠命令:\n");
    hx_out("  ps [app] / sel <pid|名> / target / info\n");
    hx_out("  regions [all]                     内存区域\n");
    hx_out("  search <值> [类型] [模式] [--from a] [--to a] [--hi 上界] [--tol n] [--all] [--limit n]\n");
    hx_out("  refine <值> [类型] [模式]          二次搜索\n");
    hx_out("  count / list [off] [n]            结果统计 / 列表\n");
    hx_out("  read <addr> [类型] / write <addr> <值> [类型]\n");
    hx_out("  editall <值> [类型] [条数]         批量修改\n");
    hx_out("  clear                             清空结果\n");
    hx_out("  freeze add <addr> <值> [类型] | del <addr> | list | clear\n");
    hx_out("  tick                              写回一次锁定值\n");
    hx_out("  autolock on [间隔ms] | off | status  自动锁定（后台持续写回）\n");
    hx_out("  modules [关键字] / offset <模块|基址> <偏移>\n");
    hx_out("  speed <倍率>                       调度优先级（近似变速）\n");
    hx_out("  tap <x> <y> / swipe <x1> <y1> <x2> <y2> [ms] / long <x> <y> [ms]\n");
    hx_out("  down|move|up <x> <y>               触摸原始事件\n");
    hx_out("  serve <端口> [ui路径] / stop       面板服务\n");
    hx_out("  类型: I8 I16 I32 I64 U8 U16 U32 U64 F32 F64 UTF8\n");
    hx_out("  模式: exact bigger smaller changed unchanged fuzzy range joint any\n");
}

int hx_dispatch(int argc, char **argv)
{
    const char *c;
    if (argc < 1) { print_help(); return 0; }
    if (argc < 2) { print_help(); return 0; }
    c = argv[1];
    if (!strcmp(c, "help") || !strcmp(c, "-h"))   { print_help(); return 0; }
    if (!strcmp(c, "ps"))        return cmd_ps(argc - 1, argv + 1);
    if (!strcmp(c, "sel"))       return cmd_sel(argc - 1, argv + 1);
    if (!strcmp(c, "target"))    return cmd_target(argc - 1, argv + 1);
    if (!strcmp(c, "regions"))   return cmd_regions(argc - 1, argv + 1);
    if (!strcmp(c, "search"))    return cmd_search(argc - 1, argv + 1);
    if (!strcmp(c, "refine"))    return cmd_refine(argc - 1, argv + 1);
    if (!strcmp(c, "count"))     return cmd_count(argc - 1, argv + 1);
    if (!strcmp(c, "list"))      return cmd_list(argc - 1, argv + 1);
    if (!strcmp(c, "read"))      return cmd_read(argc - 1, argv + 1);
    if (!strcmp(c, "write"))     return cmd_write(argc - 1, argv + 1);
    if (!strcmp(c, "editall"))   return cmd_editall(argc - 1, argv + 1);
    if (!strcmp(c, "clear"))     return cmd_clear(argc - 1, argv + 1);
    if (!strcmp(c, "freeze"))    return cmd_freeze(argc - 1, argv + 1);
    if (!strcmp(c, "tick"))      return cmd_tick(argc - 1, argv + 1);
    if (!strcmp(c, "daemon"))    return cmd_daemon(argc - 1, argv + 1);
    if (!strcmp(c, "stopdaemon")) return cmd_daemon_stop(argc - 1, argv + 1);
    if (!strcmp(c, "autolock"))   return cmd_autolock(argc - 1, argv + 1);
    if (!strcmp(c, "modules"))   return cmd_modules(argc - 1, argv + 1);
    if (!strcmp(c, "offset"))    return cmd_offset(argc - 1, argv + 1);
    if (!strcmp(c, "speed"))     return cmd_speed(argc - 1, argv + 1);
    if (!strcmp(c, "info"))      return cmd_info(argc - 1, argv + 1);
    if (!strcmp(c, "tap"))       return (argc >= 3) ? hx_touch_tap(atof(argv[2]), atof(argv[3])) : (hx_out("用法: tap <x> <y>\n"), 1);
    if (!strcmp(c, "swipe"))     return (argc >= 5) ? hx_touch_swipe(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), argc > 6 ? atoi(argv[6]) : 300, 12) : (hx_out("用法: swipe <x1> <y1> <x2> <y2> [ms]\n"), 1);
    if (!strcmp(c, "long"))      return (argc >= 3) ? hx_touch_long(atof(argv[2]), atof(argv[3]), argc > 4 ? atoi(argv[4]) : 1000) : (hx_out("用法: long <x> <y> [ms]\n"), 1);
    if (!strcmp(c, "down"))      return (argc >= 3) ? hx_touch_down(atof(argv[2]), atof(argv[3])) : 1;
    if (!strcmp(c, "move"))      return (argc >= 3) ? hx_touch_move(atof(argv[2]), atof(argv[3])) : 1;
    if (!strcmp(c, "up"))        return (argc >= 3) ? hx_touch_up(atof(argv[2]), atof(argv[3])) : 1;
    if (!strcmp(c, "serve"))     return hx_server_start(argc > 2 ? atoi(argv[2]) : 8080, argc > 3 ? argv[3] : NULL);
    if (!strcmp(c, "stop"))      { hx_server_stop(); hx_out("服务已停止\n"); return 0; }
    hx_out("未知命令: %s（输入 help 查看）\n", c);
    return 1;
}

const char *hx_run(const char *cmdline)
{
    char *copy, *p;
    char *argv[64];
    int argc = 0;
    out_reset();
    if (!cmdline || !*cmdline) { print_help(); return hx_buffer(); }
    copy = strdup(cmdline);
    if (!copy) return hx_buffer();
    p = strtok(copy, " \t\r\n");
    while (p && argc < 63) { argv[argc++] = p; p = strtok(NULL, " \t\r\n"); }
    argv[argc] = NULL;
    {
        char *full[65];
        int i;
        full[0] = (char *)"huluxia";
        for (i = 0; i < argc; i++) full[i + 1] = argv[i];
        hx_dispatch(argc + 1, full);
    }
    free(copy);
    return hx_buffer();
}
ENGINE_C_EOF

    # ---------------- HXEngineTouch.c（IOKit 私有 HID 触摸） ----------------
    cat > "$d/core/HXEngineTouch.c" <<'TOUCH_C_EOF'
/* ==========================================================================
 * HXEngineTouch.c —— 真实触摸模拟
 * IOKit 私有 API：IOHIDEventSystemClient + IOHIDEventCreateDigitizerFingerEvent
 * 事件直接投递到 HID 系统客户端，效果等同真手指（可作用于任意前台 App）
 * 需要 entitlement：com.apple.private.hid.client / com.apple.iohideventsystem.client
 * ========================================================================== */
#include "HXEngine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <math.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent            *IOHIDEventRef;

#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *)-2)
#endif

/* IOHIDDigitizerEventMask */
#define HX_HID_RANGE    0x00000001
#define HX_HID_TOUCH    0x00000002
#define HX_HID_POSITION 0x00000004

/* 私有符号（IOKit 导出，公开 SDK 无头文件，故运行时取） */
typedef IOHIDEventSystemClientRef (*fn_client_create)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*fn_client_create2)(CFAllocatorRef, int, void *);
typedef IOHIDEventRef (*fn_finger)(CFAllocatorRef, uint64_t,
                                   uint32_t, uint32_t, uint32_t,
                                   double, double, double,
                                   double, double, double, double,
                                   double, double, double, double,
                                   double, uint32_t, uint32_t);
typedef void (*fn_dispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*fn_setint)(IOHIDEventRef, uint32_t, uint32_t);

static fn_client_create  p_create   = NULL;
static fn_client_create2 p_create2  = NULL;
static fn_finger         p_finger   = NULL;
static fn_dispatch       p_dispatch = NULL;
static fn_setint         p_setint   = NULL;

static IOHIDEventSystemClientRef g_client = NULL;
static int g_ready = -1;

/* kIOHIDEventSystemClientTypePassive */
#define HX_CLIENT_TYPE_PASSIVE 0

static int hid_init(void)
{
    void *h = NULL;
    if (g_ready >= 0) return g_ready;
    g_ready = 0;

#ifdef __APPLE__
    /* 宿主进程（SpringBoard）已加载 IOKit，私有符号可直接从默认命名空间取 */
    p_create   = (fn_client_create)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    p_create2  = (fn_client_create2)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    p_finger   = (fn_finger)dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
    p_dispatch = (fn_dispatch)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
    p_setint   = (fn_setint)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
#endif

    if (!p_create && !p_create2) {
        h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (h) {
            if (!p_create)  p_create  = (fn_client_create)dlsym(h, "IOHIDEventSystemClientCreate");
            if (!p_create2) p_create2 = (fn_client_create2)dlsym(h, "IOHIDEventSystemClientCreateWithType");
            if (!p_finger)  p_finger  = (fn_finger)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
            if (!p_dispatch)p_dispatch= (fn_dispatch)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
            if (!p_setint)  p_setint  = (fn_setint)dlsym(h, "IOHIDEventSetIntegerValue");
        }
    }
    if ((!p_create && !p_create2) || !p_finger || !p_dispatch) {
        printf("[葫芦侠] HID 私有 API 不可用：缺少 IOHIDEventSystemClient 符号\n");
        return g_ready = 0;
    }
    if (p_create2) g_client = p_create2(kCFAllocatorDefault, HX_CLIENT_TYPE_PASSIVE, NULL);
    if (!g_client && p_create) g_client = p_create(kCFAllocatorDefault);
    if (!g_client) {
        printf("[葫芦侠] IOHIDEventSystemClientCreate 失败，请确认已签 hid entitlement\n");
        return g_ready = 0;
    }
    return g_ready = 1;
}

static IOHIDEventRef make_finger(double x, double y, uint32_t mask)
{
    /* 19 参数签名，iOS 13~17 通用：
       alloc, timeStamp, index, identity, eventMask,
       x, y, z, tipPressure, twist, minorRadius, majorRadius,
       quality, density, irregularity, range, field, options, eventType */
    return p_finger(kCFAllocatorDefault,
                    mach_absolute_time(),
                    0,              /* index */
                    1,              /* identity */
                    mask,           /* eventMask */
                    x, y, 0.0,      /* position */
                    0.0,            /* tipPressure */
                    0.0,            /* twist */
                    0.0, 0.0,       /* minor / major radius */
                    0.0, 0.0, 0.0,  /* quality / density / irregularity */
                    0.0,            /* range */
                    0.0,            /* field */
                    0, 0);
}

static void send_event(uint32_t mask, double x, double y)
{
    IOHIDEventRef ev;
    if (!hid_init()) return;
    ev = make_finger(x, y, mask);
    if (!ev) { printf("[葫芦侠] HID 事件创建失败\n"); return; }
    if (p_setint) p_setint(ev, 0x000D0001u, 1);   /* DigitizerClickCount */
    p_dispatch(g_client, ev);
    CFRelease(ev);
}

static void usleep_ms(int ms)
{
    if (ms > 0) usleep((useconds_t)ms * 1000);
}

int hx_touch_down(double x, double y)
{
    send_event(HX_HID_RANGE | HX_HID_TOUCH | HX_HID_POSITION, x, y);
    return 0;
}

int hx_touch_move(double x, double y)
{
    send_event(HX_HID_RANGE | HX_HID_TOUCH | HX_HID_POSITION, x, y);
    return 0;
}

int hx_touch_up(double x, double y)
{
    send_event(HX_HID_RANGE, x, y);
    return 0;
}

int hx_touch_tap(double x, double y)
{
    hx_touch_down(x, y);
    usleep_ms(30);
    hx_touch_up(x, y);
    printf("[葫芦侠] tap(%.0f, %.0f)\n", x, y);
    return 0;
}

int hx_touch_swipe(double x1, double y1, double x2, double y2, int ms, int steps)
{
    int i;
    if (steps < 2) steps = 2;
    if (ms < 10) ms = 10;
    hx_touch_down(x1, y1);
    for (i = 1; i <= steps; i++) {
        double t = (double)i / (double)steps;
        hx_touch_move(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        usleep_ms(ms / steps);
    }
    hx_touch_up(x2, y2);
    printf("[葫芦侠] swipe(%.0f,%.0f -> %.0f,%.0f, %dms)\n", x1, y1, x2, y2, ms);
    return 0;
}

int hx_touch_long(double x, double y, int ms)
{
    hx_touch_down(x, y);
    usleep_ms(ms);
    hx_touch_up(x, y);
    printf("[葫芦侠] longClick(%.0f, %.0f, %dms)\n", x, y, ms);
    return 0;
}
TOUCH_C_EOF

    # ---------------- HXServer.c（dylib 内 loopback HTTP + 面板桥接） ----------------
    cat > "$d/core/HXServer.c" <<'SERVER_C_EOF'
/* ==========================================================================
 * HXServer.c —— dylib 内置 HTTP 服务（只监听 127.0.0.1）
 *  · /          返回 HTML 面板，并注入宿主 API 桥接脚本
 *  · /api?c=..  执行一条修改器命令，返回文本
 * WKWebView 里用同步 XHR 调用，所以原 HTML 面板里
 * h5gg.searchNumber(...) / parent.h5gg / gg.click(...) 全部照原样可用
 * ========================================================================== */
#include "HXEngine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <ctype.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define HX_DEFAULT_PORT 8080

/* UI 面板路径：rootful / rootless(/var/jb) / roothide(随机 .jbroot) 三种越狱
   装的位置各不相同，这里依次探测，第一个存在的就用它。
   放在 /var/mobile 下最稳 —— 该目录在三种越狱里都可写、路径不变。 */
/* 内嵌 UI：单体 dylib（TrollFool 注入用）会把 ui.html 直接编进二进制。
   用弱符号 —— core 单独编译时没有这个符号，自动走外部文件。 */
extern const unsigned char hx_embedded_ui[] __attribute__((weak));
extern const unsigned int  hx_embedded_ui_len __attribute__((weak));

static const char *UI_CANDIDATES[] = {
    "/var/mobile/Library/HuluXia/ui.html",
    "/var/jb/usr/share/huluxia/ui.html",
    "/usr/share/huluxia/ui.html",
    "/var/jb/var/mobile/Library/HuluXia/ui.html",
    "/var/mobile/huluxia_theos/Resources/ui.html",
    NULL
};

/* -------------------------------------------------- 注入到页面的桥接脚本 */
static const char *SHIM =
"<script>\n"
"(function(){\n"
"function api(c){var x=new XMLHttpRequest();x.open('GET','/api?c='+encodeURIComponent(c),false);"
"try{x.send(null);}catch(e){return '';}return x.responseText||'';}\n"
"function num(s){var m=String(s).match(/-?[0-9]+/);return m?parseInt(m[0],10):0;}\n"
"function parseList(s){var out=[],L=String(s).split('\\n');"
"for(var i=1;i<L.length;i++){var m=L[i].match(/^(0x[0-9a-fA-F]+)\\s+(\\S+)\\s+(.*)$/);"
"if(m)out.push({address:m[1],addr:m[1],type:m[2],value:m[3]});}return out;}\n"
"var Host={};\n"
"Host.searchNumber=function(v,t,f,to){var c='search '+v+' '+(t||'I32');"
"if(f&&String(f).indexOf('0x')===0)c+=' --from '+f;"
"if(to&&String(to).indexOf('0x')===0)c+=' --to '+to;api(c);return num(api('count'));};\n"
"Host.getResultsCount=function(){return num(api('count'));};\n"
"Host.getResults=function(n,off){return parseList(api('list '+(off||0)+' '+(n||100)));};\n"
"Host.editAll=function(v,t){return num(api('editall '+v+' '+(t||'I32')));};\n"
"Host.setValue=function(a,v,t){api('write '+a+' '+v+' '+(t||'I32'));return true;};\n"
"Host.getValue=function(a,t){return api('read '+a+' '+(t||'I32'));};\n"
"Host.clearResults=function(){api('clear');return true;};\n"
"Host.readMemory=Host.getValue;Host.writeMemory=Host.setValue;\n"
"Host.getProcesses=function(){return api('ps');};\n"
"Host.selectProcess=function(p){return api('sel '+p);};\n"
"var gg={\n"
" TYPE_BYTE:'U8',TYPE_WORD:'U16',TYPE_DWORD:'I32',TYPE_QWORD:'I64',\n"
" TYPE_FLOAT:'F32',TYPE_DOUBLE:'F64',TYPE_XOR:'I32',TYPE_UTF8:'UTF8',\n"
" searchNumber:function(v,t){return Host.searchNumber(v,t);},\n"
" getResults:function(n,off){return Host.getResults(n,off);},\n"
" getResultsCount:function(){return Host.getResultsCount();},\n"
" editAll:function(v,t){return Host.editAll(v,t);},\n"
" addListItems:function(list){var n=0;for(var i=0;i<list.length;i++){api('freeze add '+list[i].address+' '+list[i].value+' '+(list[i].type||'I32'));n++;}return n;},\n"
" clearResults:function(){return Host.clearResults();},\n"
" toast:function(m){try{window.webkit.messageHandlers.hxToast.postMessage(String(m));}catch(e){alert(m);}},\n"
" alert:function(m){alert(m);},\n"
" choice:function(items,title){var s=items.join('\\n');return prompt(title||'选择',items[0]);},\n"
" prompt:function(t,d){return prompt(t,d||'');},\n"
" sleep:function(ms){var t=Date.now();while(Date.now()-t<ms){}return true;},\n"
" click:function(x,y){api('tap '+x+' '+y);return true;},\n"
" swipe:function(a,b,c,d,ms){api('swipe '+a+' '+b+' '+c+' '+d+' '+(ms||300));return true;},\n"
" longClick:function(x,y,ms){api('long '+x+' '+y+' '+(ms||1000));return true;},\n"
" touchDown:function(x,y){api('down '+x+' '+y);return true;},\n"
" touchMove:function(x,y){api('move '+x+' '+y);return true;},\n"
" touchUp:function(x,y){api('up '+x+' '+y);return true;}\n"
"};\n"
"function toast(m){gg.toast(m);}\n"
"function getTargetInfo(){var s=api('target'),o={};"
"var L=s.split('\\n');for(var i=0;i<L.length;i++){var p=L[i].split('=');if(p.length>1)o[p[0]]=p[1];}"
"return {name:o.name||'',pid:parseInt(o.pid||'0',10),packageName:o.package||''};}\n"
"function exitHtmlRunner(){try{window.webkit.messageHandlers.hxClose.postMessage('1');}catch(e){history.back();}}\n"
"window.h5gg=Host;window.h5=Host;window.host=Host;window.gg=gg;\n"
"window.toast=toast;window.log=function(m){console.log(m);};\n"
"window.getTargetInfo=getTargetInfo;window.exitHtmlRunner=exitHtmlRunner;\n"
"window.click=function(x,y){return gg.click(x,y);};\n"
"window.swipe=function(a,b,c,d,ms){return gg.swipe(a,b,c,d,ms);};\n"
"window.longClick=function(x,y,ms){return gg.longClick(x,y,ms);};\n"
"window.touchDown=function(x,y){return gg.touchDown(x,y);};\n"
"window.touchMove=function(x,y){return gg.touchMove(x,y);};\n"
"window.touchUp=function(x,y){return gg.touchUp(x,y);};\n"
"window.hxApi=api;\n"
"})();\n"
"</script>\n";

/* ------------------------------------------------------------ 服务状态 */
static int         g_srv_fd  = -1;
static int         g_srv_run = 0;
static int         g_use_embedded = 0;   /* 1 = 用编进二进制的内嵌 UI（TrollFool 注入场景） */
static pthread_t   g_srv_th;
static int         g_port    = HX_DEFAULT_PORT;

int hx_server_port(void) { return g_port; }

static char *read_file_alloc(const char *path, size_t *len)
{
    FILE *f;
    char *buf;
    long sz;
    f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return NULL; }
    buf[sz] = 0;
    fclose(f);
    if (len) *len = (size_t)sz;
    return buf;
}

static void url_decode(char *d, const char *s)
{
    char hex[3];
    while (*s) {
        if (*s == '%' && s[1] && s[2]) {
            hex[0] = s[1]; hex[1] = s[2]; hex[2] = 0;
            *d++ = (char)strtoul(hex, NULL, 16);
            s += 3;
        } else if (*s == '+') {
            *d++ = ' '; s++;
        } else {
            *d++ = *s++;
        }
    }
    *d = 0;
}

static void http_write(int fd, const char *data, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, len - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
}

static void http_response(int fd, const char *ctype, const char *body, size_t len)
{
    char head[320];
    int n = snprintf(head, sizeof(head),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "Cache-Control: no-store\r\n"
        "Access-Control-Allow-Origin: *\r\n\r\n", ctype, len);
    http_write(fd, head, (size_t)n);
    if (len) http_write(fd, body, len);
}

static char *build_page(const char *uipath, size_t *len)
{
    char *html, *out;
    size_t hlen, slen = strlen(SHIM);
    const char *anchor;

    if (g_use_embedded && hx_embedded_ui && hx_embedded_ui_len > 0) {
        /* 用编进二进制的那份 HTML —— TrollFool 注入的 IPA 里没有外部文件 */
        hlen = (size_t)hx_embedded_ui_len;
        html = (char *)malloc(hlen + 1);
        if (!html) return NULL;
        memcpy(html, hx_embedded_ui, hlen);
        html[hlen] = 0;
    } else {
        html = read_file_alloc(uipath, &hlen);
        if (!html) return NULL;
    }
    out = (char *)malloc(hlen + slen + 64);
    if (!out) { free(html); return NULL; }
    anchor = strstr(html, "</head>");
    if (!anchor) anchor = strstr(html, "</HEAD>");
    if (anchor) {
        size_t pos = (size_t)(anchor - html);
        memcpy(out, html, pos);
        memcpy(out + pos, SHIM, slen);
        memcpy(out + pos + slen, html + pos, hlen - pos);
        *len = hlen + slen;
    } else {
        memcpy(out, html, hlen);
        memcpy(out + hlen, SHIM, slen);
        *len = hlen + slen;
    }
    free(html);
    return out;
}

static void handle_client(int fd, const char *uipath)
{
    char req[65536];
    size_t got = 0;
    char method[16], path[4096];
    const char *q;
    char cparam[4096];

    while (got < sizeof(req) - 1) {
        ssize_t r = read(fd, req + got, sizeof(req) - 1 - got);
        if (r <= 0) break;
        got += (size_t)r;
        req[got] = 0;
        if (strstr(req, "\r\n\r\n")) break;
    }
    if (got == 0) return;
    method[0] = 0; path[0] = 0;
    if (sscanf(req, "%15s %4095s", method, path) != 2) return;
    q = strchr(path, '?');
    cparam[0] = 0;
    if (q) {
        const char *p = q + 1;
        while (*p) {
            if (!strncmp(p, "c=", 2)) {
                const char *e = strchr(p, '&');
                size_t n = e ? (size_t)(e - (p + 2)) : strlen(p + 2);
                if (n > sizeof(cparam) - 1) n = sizeof(cparam) - 1;
                memcpy(cparam, p + 2, n);
                cparam[n] = 0;
                break;
            }
            p = strchr(p, '&');
            if (!p) break;
            p++;
        }
    }
    if (cparam[0]) {
        char cmd[4096];
        const char *out;
        url_decode(cmd, cparam);
        out = hx_run(cmd);
        http_response(fd, "text/plain; charset=utf-8", out, strlen(out));
        return;
    }
    {
        char *page;
        size_t plen = 0;
        page = build_page(uipath, &plen);
        if (!page) {
            char buf[1024];
            int i, n;
            if (g_use_embedded) {
                n = snprintf(buf, sizeof(buf),
                    "UI 面板数据异常（内嵌模式）\n");
                http_response(fd, "text/plain; charset=utf-8", buf, (size_t)n);
                return;
            }
            n = snprintf(buf, sizeof(buf),
                "UI 面板文件不存在\n\n已尝试:\n");
            for (i = 0; UI_CANDIDATES[i] && n < 900; i++) {
                n += snprintf(buf + n, sizeof(buf) - (size_t)n, "  %s\n", UI_CANDIDATES[i]);
            }
            n += snprintf(buf + n, sizeof(buf) - (size_t)n,
                "\n修复: cp 你的面板.html /var/mobile/Library/HuluXia/ui.html");
            http_response(fd, "text/plain; charset=utf-8", buf, (size_t)n);
            return;
        }
        http_response(fd, "text/html; charset=utf-8", page, plen);
        free(page);
    }
}

static void *server_thread(void *arg)
{
    const char *ui = (const char *)arg;
    signal(SIGPIPE, SIG_IGN);
    while (g_srv_run) {
        int c = accept(g_srv_fd, NULL, NULL);
        if (c < 0) continue;
        handle_client(c, ui);
        close(c);
    }
    return NULL;
}

int hx_server_start(int port, const char *uipath)
{
    int one = 1;
    struct sockaddr_in a;
    static char ui_buf[512];

    if (g_srv_run) return 0;

    /* 单体 dylib：内嵌 UI 优先。注入 IPA 后设备上没有 html 文件，
       只能靠编进二进制的那份。有内嵌就直接用，不再去找外部文件。 */
    if (hx_embedded_ui && hx_embedded_ui_len > 0) {
        g_use_embedded = 1;
    } else {
        g_use_embedded = 0;
        if (!uipath || access(uipath, R_OK) != 0) {
            int i;
            uipath = NULL;
            for (i = 0; UI_CANDIDATES[i]; i++) {
                if (access(UI_CANDIDATES[i], R_OK) == 0) { uipath = UI_CANDIDATES[i]; break; }
            }
            if (!uipath) uipath = UI_CANDIDATES[0];
        }
        strncpy(ui_buf, uipath, sizeof(ui_buf) - 1);
        ui_buf[sizeof(ui_buf) - 1] = 0;
    }

    g_port = port > 0 ? port : HX_DEFAULT_PORT;
    g_srv_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_srv_fd < 0) return 1;
    setsockopt(g_srv_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)g_port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   /* 仅本机，不对外暴露 */
    if (bind(g_srv_fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        close(g_srv_fd);
        g_srv_fd = -1;
        return 1;
    }
    if (listen(g_srv_fd, 16) < 0) {
        close(g_srv_fd);
        g_srv_fd = -1;
        return 1;
    }
    g_srv_run = 1;
    pthread_create(&g_srv_th, NULL, server_thread, ui_buf);
    printf("[葫芦侠] 面板服务已启动 http://127.0.0.1:%d/\n", g_port);
    return 0;
}

void hx_server_stop(void)
{
    if (!g_srv_run) return;
    g_srv_run = 0;
    if (g_srv_fd >= 0) { shutdown(g_srv_fd, SHUT_RDWR); close(g_srv_fd); g_srv_fd = -1; }
}
SERVER_C_EOF

    # ---------------- HXCore.h / HXCore.m（OC 封装） ----------------
    cat > "$d/core/HXCore.h" <<'CORE_H_EOF'
#import <Foundation/Foundation.h>
#import "HXEngine.h"

@interface HXCore : NSObject
+ (instancetype)shared;
- (NSString *)run:(NSString *)cmd;
- (void)ensureServer;
- (void)startServer:(int)port;
- (void)stopServer;
- (int)serverPort;
@end
CORE_H_EOF

    cat > "$d/core/HXCore.m" <<'CORE_M_EOF'
#import "HXCore.h"

@implementation HXCore

+ (instancetype)shared
{
    static HXCore *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[HXCore alloc] init]; });
    return inst;
}

- (NSString *)run:(NSString *)cmd
{
    const char *r = hx_run([cmd UTF8String]);
    return r ? [NSString stringWithUTF8String:r] : @"";
}

- (void)ensureServer
{
    if (hx_server_port() <= 0) [self startServer:8080];
}

- (void)startServer:(int)port
{
    hx_server_start(port, NULL);
}

- (void)stopServer
{
    hx_server_stop();
}

- (int)serverPort
{
    return hx_server_port();
}

@end
CORE_M_EOF

    # ---------------- ui（面板库，单独成 dylib，避免 CLI 被迫加载 UIKit） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'LIBRARY_NAME = HuluXiaUI\n'
        printf 'HuluXiaUI_FILES = HXPanel.m\n'
        printf 'HuluXiaUI_INSTALL_PATH = /usr/lib\n'
        printf 'HuluXiaUI_CFLAGS = -I../core -O2 -Wall -Wno-unused-parameter -fobjc-arc\n'
        printf 'HuluXiaUI_FRAMEWORKS = Foundation UIKit WebKit CoreGraphics\n'
        printf 'HuluXiaUI_LDFLAGS = -L$(THEOS_STAGING_DIR)/usr/lib -lHuluXia -Wl,-rpath,/usr/lib\n'
        printf 'ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\n'
        printf 'HuluXiaUI_LDFLAGS += -lroothide -Wl,-rpath,@loader_path/.jbroot/usr/lib\n'
        printf 'endif\n'
        printf 'HuluXiaUI_CODESIGN_FLAGS = -S../ent.plist\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/library.mk\n'
    } > "$d/ui/Makefile"


    # ---------------- ui/HXPanel（悬浮球 + 可复用面板 VC） ----------------
    cat > "$d/ui/HXPanel.h" <<'PANEL_H_EOF'
#import <UIKit/UIKit.h>

@interface HXPanel : NSObject
+ (instancetype)shared;

/* 越狱 App 场景：返回一个自带 WebView 的 VC，push / present 都行 */
- (UIViewController *)makePanelViewController;

/* 注入场景：独立 window 全屏显示 */
- (void)showPanel;
- (void)hidePanel;
- (void)toggle;

/* 悬浮球 —— 默认关闭，需用户主动开启（OLED 防烧屏） */
- (void)installBall;
- (void)removeBall;
- (void)setBallEnabled:(BOOL)on;
- (BOOL)ballEnabled;

- (void)toast:(NSString *)msg;
@end
PANEL_H_EOF

    cat > "$d/ui/HXPanel.m" <<'PANEL_M_EOF'
#import "HXPanel.h"
#import "HXCore.h"
#import "HXEngine.h"
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

typedef void (^HXCloseBlock)(void);

@interface HXPanel () <WKScriptMessageHandler, WKNavigationDelegate>
@property (nonatomic, copy)   HXCloseBlock onClose;
@property (nonatomic, strong) UIWindow   *ballWin;
@property (nonatomic, assign) BOOL        ballOn;      /* 悬浮球总开关，默认 NO */
@property (nonatomic, strong) NSTimer    *fadeTimer;   /* 防烧屏：静置后淡出 */
@property (nonatomic, assign) BOOL        ballFaded;
@property (nonatomic, strong) UIButton   *ball;
@property (nonatomic, strong) UIWindow   *panelWin;
@property (nonatomic, strong) WKWebView  *web;
@property (nonatomic, strong) UILabel    *toastLabel;
@property (nonatomic, assign) CGPoint     ballCenter;
@end

@implementation HXPanel

+ (instancetype)shared
{
    static HXPanel *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[HXPanel alloc] init]; });
    return inst;
}

/* 悬浮球图片候选位置 —— 覆盖有根 / 无根 / 隐根三种越狱 */
+ (NSArray *)ballImagePaths
{
    return @[
        @"/var/mobile/Library/HuluXia/ball.png",
        @"/var/jb/usr/share/huluxia/ball.png",
        @"/usr/share/huluxia/ball.png",
        @"/var/mobile/huluxia_theos/Resources/ball.png",
    ];
}

+ (UIImage *)ballImage
{
    static UIImage *cached = nil;
    static BOOL tried = NO;
    if (tried) return cached;
    tried = YES;

    for (NSString *n in @[@"ball.png", @"ball@3x.png"]) {
        NSString *p = [[NSBundle mainBundle] pathForResource:n ofType:nil];
        if (p) {
            UIImage *im = [UIImage imageWithContentsOfFile:p];
            if (im) { cached = im; return cached; }
        }
    }
    for (NSString *p in [self ballImagePaths]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            UIImage *im = [UIImage imageWithContentsOfFile:p];
            if (im) { cached = im; return cached; }
        }
    }
    return nil;
}

static void HXAttachScene(UIWindow *w)
{
    if (!w) return;
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive &&
                [sc isKindOfClass:[UIWindowScene class]]) {
                w.windowScene = (UIWindowScene *)sc;
                return;
            }
        }
    }
}

#pragma mark - WebView 面板（App / 注入两种场景共用）

- (WKWebView *)buildWebView
{
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"hxToast"];
    [ucc addScriptMessageHandler:self name:@"hxClose"];
    cfg.userContentController = ucc;
    cfg.allowsInlineMediaPlayback = YES;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    wv.navigationDelegate = self;
    wv.opaque = NO;
    wv.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
    wv.scrollView.bounces = NO;
    self.web = wv;
    return wv;
}

- (void)loadPanelInto:(WKWebView *)wv
{
    [[HXCore shared] ensureServer];
    int port = hx_server_port();
    if (port <= 0) port = 8080;
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/", port]];
    [wv loadRequest:[NSURLRequest requestWithURL:u
                                   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                               timeoutInterval:20.0]];
}

/* 供越狱 App 使用：拿到 VC 后 push 或 present */
- (UIViewController *)makePanelViewController
{
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"葫芦侠";
    vc.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];

    WKWebView *wv = [self buildWebView];
    wv.frame = vc.view.bounds;
    wv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:wv];

    /* App 场景的关闭：有导航就 pop，否则 dismiss */
    __weak typeof(vc) weakVC = vc;
    self.onClose = ^{
        UIViewController *v = weakVC;
        if (!v) return;
        if (v.navigationController) {
            [v.navigationController popViewControllerAnimated:YES];
        } else if (v.presentingViewController) {
            [v dismissViewControllerAnimated:YES completion:nil];
        }
    };

    [self loadPanelInto:wv];
    return vc;
}

#pragma mark - 独立 window 面板（注入场景）

- (void)toggle
{
    if (self.panelWin && !self.panelWin.hidden) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[HXCore shared] ensureServer];
        if (self.panelWin) { self.panelWin.hidden = NO; return; }

        CGRect b = [UIScreen mainScreen].bounds;
        self.panelWin = [[UIWindow alloc] initWithFrame:b];
        self.panelWin.windowLevel = UIWindowLevelStatusBar + 200.0f;
        self.panelWin.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
        HXAttachScene(self.panelWin);

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 46)];
        bar.backgroundColor = [UIColor colorWithRed:0.11 green:0.37 blue:0.13 alpha:1.0];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, b.size.width - 120, 30)];
        title.text = @"葫芦侠 · 私有 API 版";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        [bar addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
        close.frame = CGRectMake(b.size.width - 74, 8, 64, 30);
        close.backgroundColor = [UIColor colorWithRed:0.85 green:0.21 blue:0.21 alpha:1.0];
        close.layer.cornerRadius = 6;
        [close setTitle:@"✕ 收起" forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:close];
        [vc.view addSubview:bar];

        WKWebView *wv = [self buildWebView];
        wv.frame = CGRectMake(0, 46, b.size.width, b.size.height - 46);
        [vc.view addSubview:wv];

        self.onClose = ^{ [self hidePanel]; };

        self.panelWin.rootViewController = vc;
        self.panelWin.hidden = NO;
        [self loadPanelInto:wv];
    });
}

- (void)hidePanel
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.panelWin.hidden = YES;
    });
}

#pragma mark - 悬浮球

- (BOOL)ballEnabled
{
    return self.ballOn;
}

/* 悬浮球默认关闭 —— 只有用户主动开启才出现，避免 OLED 长期固定显示烧屏 */
- (void)setBallEnabled:(BOOL)on
{
    self.ballOn = on;
    if (on) {
        [self installBall];
    } else {
        [self removeBall];
    }
}

- (void)installBall
{
    /* 开关没开就不装 —— 这是防烧屏的关键 */
    if (!self.ballOn) return;
    if (self.ballWin) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [UIScreen mainScreen].bounds;
        CGFloat size = 54.0;
        CGRect fr = CGRectMake(b.size.width - size - 8, b.size.height * 0.42, size, size);
        self.ballWin = [[UIWindow alloc] initWithFrame:fr];
        self.ballWin.windowLevel = UIWindowLevelStatusBar + 100.0f;
        self.ballWin.backgroundColor = [UIColor clearColor];
        self.ballWin.userInteractionEnabled = YES;
        HXAttachScene(self.ballWin);

        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        self.ballWin.rootViewController = vc;

        self.ball = [UIButton buttonWithType:UIButtonTypeCustom];
        self.ball.frame = vc.view.bounds;
        self.ball.backgroundColor = [UIColor colorWithRed:0.30 green:0.69 blue:0.31 alpha:0.96];
        self.ball.layer.cornerRadius = size / 2.0;
        self.ball.layer.shadowColor = [UIColor blackColor].CGColor;
        self.ball.layer.shadowOpacity = 0.45;
        self.ball.layer.shadowOffset = CGSizeMake(0, 2);
        self.ball.layer.shadowRadius = 6;
        self.ball.layer.borderColor = [UIColor colorWithRed:0.63 green:0.90 blue:0.64 alpha:1.0].CGColor;
        self.ball.layer.borderWidth = 1.5;
        UIImage *ballImg = [HXPanel ballImage];
        if (ballImg) {
            [self.ball setImage:ballImg forState:UIControlStateNormal];
            self.ball.imageView.contentMode = UIViewContentModeScaleAspectFill;
            self.ball.backgroundColor = [UIColor clearColor];
            self.ball.layer.borderWidth = 0;
            self.ball.layer.shadowOpacity = 0.35;
        } else {
            [self.ball setTitle:@"\U0001F383" forState:UIControlStateNormal];
            self.ball.titleLabel.font = [UIFont systemFontOfSize:24];
        }
        self.ball.alpha = 0.92;

        [self.ball addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self.ball addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
        lp.minimumPressDuration = 1.2;
        [self.ball addGestureRecognizer:lp];

        [vc.view addSubview:self.ball];
        self.ballWin.hidden = NO;
        self.ballCenter = self.ballWin.center;
        self.ballFaded = NO;
        [self restartFadeTimer];
    });
}

#pragma mark - 防烧屏（OLED 长期固定像素会留残影）

/* 静置 6 秒后把球淡到 0.22，几乎看不见；碰一下立刻恢复 */
- (void)restartFadeTimer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
        self.ballFaded = NO;
        [UIView animateWithDuration:0.25 animations:^{
            self.ball.alpha = 0.92;
        }];
        self.fadeTimer = [NSTimer scheduledTimerWithTimeInterval:6.0
                                                          target:self
                                                        selector:@selector(fadeBall)
                                                        userInfo:nil
                                                         repeats:NO];
    });
}

- (void)fadeBall
{
    if (!self.ballOn || !self.ball) return;
    self.ballFaded = YES;
    [UIView animateWithDuration:1.2 animations:^{
        self.ball.alpha = 0.22;
    }];
}

- (void)removeBall
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
        self.ballWin.hidden = YES;
        self.ballWin = nil;
        self.ball = nil;
    });
}

- (void)onTap
{
    [self restartFadeTimer];
    [self toggle];
}

- (void)onLong:(UILongPressGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) {
        [[HXCore shared] run:@"autolock off"];
        [self toast:@"已停止自动锁定"];
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g
{
    if (!self.ballWin) return;
    if (g.state == UIGestureRecognizerStateBegan) [self restartFadeTimer];
    CGPoint t = [g translationInView:self.ballWin];
    CGPoint c = self.ballCenter;
    c.x += t.x; c.y += t.y;
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat half = self.ballWin.bounds.size.width / 2.0;
    c.x = MAX(half, MIN(b.size.width - half, c.x));
    c.y = MAX(half + 20, MIN(b.size.height - half - 10, c.y));
    self.ballWin.center = c;
    if (g.state == UIGestureRecognizerStateEnded) self.ballCenter = c;
    [g setTranslation:CGPointZero inView:self.ballWin];
}

#pragma mark - toast

- (void)toast:(NSString *)msg
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = self.panelWin;
        if (!host || host.hidden) host = [[[UIApplication sharedApplication] windows] firstObject];
        if (!host) return;
        if (!self.toastLabel) {
            self.toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
            self.toastLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.78];
            self.toastLabel.textColor = [UIColor whiteColor];
            self.toastLabel.font = [UIFont systemFontOfSize:13];
            self.toastLabel.textAlignment = NSTextAlignmentCenter;
            self.toastLabel.numberOfLines = 0;
            self.toastLabel.layer.cornerRadius = 8;
            self.toastLabel.layer.masksToBounds = YES;
        }
        [self.toastLabel removeFromSuperview];
        CGRect b = host.bounds;
        CGFloat w = MIN(b.size.width - 60, 300);
        self.toastLabel.frame = CGRectMake((b.size.width - w) / 2, b.size.height - 140, w, 42);
        self.toastLabel.text = msg;
        self.toastLabel.alpha = 0;
        [host addSubview:self.toastLabel];
        [UIView animateWithDuration:0.2 animations:^{ self.toastLabel.alpha = 1; } completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ self.toastLabel.alpha = 0; } completion:^(BOOL g) {
                    [self.toastLabel removeFromSuperview];
                }];
            });
        }];
    });
}

#pragma mark - JS 桥接

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)msg
{
    if ([msg.name isEqualToString:@"hxClose"]) {
        if (self.onClose) self.onClose();
        else [self hidePanel];
        return;
    }
    if ([msg.name isEqualToString:@"hxToast"]) {
        [self toast:msg.body ? [NSString stringWithFormat:@"%@", msg.body] : @""];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error
{
    NSString *html = [NSString stringWithFormat:
        @"<html><body style='background:#121212;color:#7ee787;font:14px -apple-system;padding:20px'>"
        @"<h3>面板加载失败</h3><p>%@</p>"
        @"<p>请确认 /usr/share/huluxia/ui.html 存在。</p></body></html>",
        [error localizedDescription]];
    [webView loadHTMLString:html baseURL:nil];
}

@end
PANEL_M_EOF

    # ---------------- 越狱 App（/Applications/HuluXia.app） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'APPLICATION_NAME = HuluXia\n'
        printf 'HuluXia_FILES = main.m HXAppDelegate.m\n'
        printf 'HuluXia_CFLAGS = -I../core -I../ui -O2 -Wall -Wno-unused-parameter -fobjc-arc\n'
        printf 'HuluXia_FRAMEWORKS = UIKit Foundation WebKit CoreGraphics\n'
        printf 'HuluXia_LDFLAGS = -L$(THEOS_STAGING_DIR)/usr/lib -lHuluXia -lHuluXiaUI -Wl,-rpath,/usr/lib\n'
        printf 'ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\n'
        printf 'HuluXia_LDFLAGS += -lroothide -Wl,-rpath,@loader_path/.jbroot/usr/lib\n'
        printf 'endif\n'
        printf '# -I 指定 bundle id；ent.plist 里的私有权限一并签入\n'
        printf 'HuluXia_CODESIGN_FLAGS = -S../ent.plist -Icom.huluxia.ios\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/application.mk\n'
    } > "$d/app/Makefile"

    cat > "$d/app/Info.plist" <<'INFO_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>葫芦侠</string>
    <key>CFBundleExecutable</key><string>HuluXia</string>
    <key>CFBundleIdentifier</key><string>com.huluxia.ios</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>HuluXia</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>3.0</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>14.0</string>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchStoryboardName</key><string></string>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
    <key>UIStatusBarStyle</key><string>UIStatusBarStyleLightContent</string>
    <key>UIViewControllerBasedStatusBarAppearance</key><false/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
                <string>AppIcon76x76</string>
                <string>AppIcon83.5x83.5</string>
                <string>AppIcon40x40</string>
                <string>AppIcon29x29</string>
            </array>
            <key>CFBundleIconName</key><string>AppIcon</string>
            <key>UIPrerenderedIcon</key><false/>
        </dict>
    </dict>
</dict>
</plist>
INFO_EOF

    cat > "$d/app/main.m" <<'APP_MAIN_EOF'
#import <UIKit/UIKit.h>
#import "HXAppDelegate.h"

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([HXAppDelegate class]));
    }
}
APP_MAIN_EOF

    cat > "$d/app/HXAppDelegate.h" <<'APP_H_EOF'
#import <UIKit/UIKit.h>

@interface HXAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
APP_H_EOF

    cat > "$d/app/HXAppDelegate.m" <<'APP_M_EOF'
#import "HXAppDelegate.h"
#import <unistd.h>
#import "HXCore.h"
#import "HXPanel.h"
#import "HXEngine.h"

@interface HXAppDelegate ()
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UIButton *ballBtn;
@end

@implementation HXAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];

    UIViewController *home = [self makeHomeVC];
    self.nav = [[UINavigationController alloc] initWithRootViewController:home];
    self.nav.navigationBar.barStyle = UIBarStyleBlack;
    self.nav.navigationBar.tintColor = [UIColor whiteColor];
    self.nav.navigationBar.barTintColor = [UIColor colorWithRed:0.11 green:0.37 blue:0.13 alpha:1.0];
    self.nav.navigationBar.translucent = NO;

    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];

    /* 启动 HTTP 服务，面板靠它调引擎 */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[HXCore shared] ensureServer];
    });

    /* 恢复用户上次的选择（默认关） */
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HXBallEnabled"]) {
        [[HXPanel shared] setBallEnabled:YES];
    }

    [self refreshStatus];
    return YES;
}

#pragma mark - 主页

- (UIViewController *)makeHomeVC
{
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"葫芦侠";
    vc.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];

    CGFloat w = vc.view.bounds.size.width;

    /* 顶部图标区 */
    UIImageView *icon = [[UIImageView alloc] initWithImage:[self appIcon]];
    icon.frame = CGRectMake((w - 90) / 2, 30, 90, 90);
    icon.layer.cornerRadius = 20;
    icon.layer.masksToBounds = YES;
    [vc.view addSubview:icon];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, 130, w, 26)];
    name.text = @"葫芦侠 · 私有 API 版";
    name.textColor = [UIColor colorWithRed:0.63 green:0.90 blue:0.64 alpha:1.0];
    name.font = [UIFont boldSystemFontOfSize:17];
    name.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:name];

    /* 状态 */
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 168, w - 32, 46)];
    self.statusLabel.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.55 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [vc.view addSubview:self.statusLabel];

    /* 按钮 */
    UIButton *open = [self bigButton:@"🎃 打开控制面板" y:232
                              bg:[UIColor colorWithRed:0.18 green:0.55 blue:0.20 alpha:1.0]];
    [open addTarget:self action:@selector(openPanel) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:open];

    UIButton *procs = [self bigButton:@"📱 刷新进程列表" y:292
                               bg:[UIColor colorWithRed:0.12 green:0.35 blue:0.60 alpha:1.0]];
    [procs addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:procs];

    UIButton *help = [self bigButton:@"📖 使用说明" y:352
                               bg:[UIColor colorWithRed:0.25 green:0.25 blue:0.25 alpha:1.0]];
    [help addTarget:self action:@selector(showHelp) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:help];

    /* 悬浮球开关 —— 默认关闭，避免 OLED 长期固定显示烧屏 */
    self.ballBtn = [self bigButton:@"" y:412
                                bg:[UIColor colorWithRed:0.35 green:0.35 blue:0.15 alpha:1.0]];
    [self.ballBtn addTarget:self action:@selector(toggleBall) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:self.ballBtn];
    [self refreshBallBtn];

    /* 提示 */
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 478, w - 32, 96)];
    tip.textColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.45 alpha:1.0];
    tip.font = [UIFont systemFontOfSize:11];
    tip.numberOfLines = 0;
    tip.text = @"提示：\n"
               @"· 面板里先点『选进程』再搜索；本 App 以 root 运行，可读改其他进程内存\n"
               @"· 若提示 task_for_pid 失败，改用注入模式：把 tweak plist 改成目标 App，面板里执行 sel 0";
    [vc.view addSubview:tip];

    return vc;
}

- (UIButton *)bigButton:(NSString *)title y:(CGFloat)y bg:(UIColor *)bg
{
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(24, y, w - 48, 50);
    b.backgroundColor = bg;
    b.layer.cornerRadius = 10;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    return b;
}

- (UIImage *)appIcon
{
    /* 优先用 bundle 内图标文件 */
    NSArray *names = @[@"AppIcon60x60@3x.png", @"AppIcon60x60@2x.png", @"AppIcon1024.png"];
    for (NSString *n in names) {
        NSString *p = [[NSBundle mainBundle] pathForResource:n ofType:nil];
        if (p) { UIImage *im = [UIImage imageWithContentsOfFile:p]; if (im) return im; }
    }
    return nil;
}

#pragma mark - 动作

- (void)openPanel
{
    UIViewController *panel = [[HXPanel shared] makePanelViewController];
    [self.nav pushViewController:panel animated:YES];
}

- (void)refreshStatus
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *info = [[HXCore shared] run:@"info"];
        NSArray *procs = [[[HXCore shared] run:@"ps app"] componentsSeparatedByString:@"\n"];
        NSUInteger n = procs.count > 4 ? procs.count - 4 : 0;
        BOOL root = (geteuid() == 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *first = info.length > 120 ? [info substringToIndex:120] : info;
            NSString *perm = root ? @"✅ 已获 root（可读写其他进程）"
                                  : @"⚠️ 非 root，只能操作自身进程";
            self.statusLabel.text = [NSString stringWithFormat:@"%@\n%@\nApp 进程约 %lu 个",
                                     perm, first ?: @"", (unsigned long)n];
            self.statusLabel.textColor = root
                ? [UIColor colorWithRed:0.49 green:0.91 blue:0.53 alpha:1.0]
                : [UIColor colorWithRed:0.90 green:0.65 blue:0.40 alpha:1.0];
        });
    });
}

- (void)refreshBallBtn
{
    BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:@"HXBallEnabled"];
    [self.ballBtn setTitle:on ? @"🎃 悬浮球：开（点此关闭）" : @"🎃 悬浮球：关（点此开启）"
                  forState:UIControlStateNormal];
    self.ballBtn.backgroundColor = on
        ? [UIColor colorWithRed:0.18 green:0.55 blue:0.20 alpha:1.0]
        : [UIColor colorWithRed:0.35 green:0.35 blue:0.15 alpha:1.0];
}

- (void)toggleBall
{
    BOOL on = ![[NSUserDefaults standardUserDefaults] boolForKey:@"HXBallEnabled"];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"HXBallEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[HXPanel shared] setBallEnabled:on];
    [self refreshBallBtn];
    [self toast:on ? @"悬浮球已开启（静置会自动淡出防烧屏）" : @"悬浮球已关闭"];
}

- (void)toast:(NSString *)msg
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [self.nav presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)showHelp
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"使用说明"
        message:@"1. 点『打开控制面板』\n"
                @"2. 面板里选进程（或 sel 0 选自身）\n"
                @"3. 输入数值 → 首搜 → 改值后『再搜』→ 全部修改\n"
                @"4. 加入锁定后开『自动锁定』持续生效\n\n"
                @"注入用法：编辑 tweak/HuluXiaTweak.plist 的 Filter，"
                @"把 bundle id 改成目标 App，重装即可在游戏里弹出悬浮球"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self.nav presentViewController:ac animated:YES completion:nil];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    [self refreshStatus];
}

@end
APP_M_EOF
    # ---------------- tweak（注入 SpringBoard 或目标 App） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'TWEAK_NAME = HuluXiaTweak\n'
        printf 'HuluXiaTweak_FILES = HuluXiaTweak.m\n'
        printf 'HuluXiaTweak_CFLAGS = -I../core -I../ui -O2 -Wall -Wno-unused-parameter -fobjc-arc\n'
        printf 'HuluXiaTweak_FRAMEWORKS = Foundation UIKit\n'
        printf 'HuluXiaTweak_LDFLAGS = -L$(THEOS_STAGING_DIR)/usr/lib -lHuluXia -lHuluXiaUI -Wl,-rpath,/usr/lib\n'
        printf 'ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\n'
        printf 'HuluXiaTweak_LDFLAGS += -lroothide -Wl,-rpath,@loader_path/.jbroot/usr/lib\n'
        printf 'endif\n'
        printf 'HuluXiaTweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries\n'
        printf 'HuluXiaTweak_CODESIGN_FLAGS = -S../ent.plist\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/tweak.mk\n'
    } > "$d/tweak/Makefile"

    cat > "$d/tweak/HuluXiaTweak.m" <<'TWEAK_M_EOF'
/* ==========================================================================
 * HuluXiaTweak.m —— 注入入口
 * 注入 SpringBoard：全局悬浮球 + 面板
 * 注入某个 App：面板直接在该 App 内弹出，此时 `sel 0` 走 mach_task_self()，
 *               读写自身内存不需要 task_for_pid，权限问题最少
 * ========================================================================== */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "HXCore.h"
#import "HXPanel.h"

__attribute__((constructor))
static void HuluXiaInit(void)
{
    /* 等宿主 UI 就绪再挂悬浮窗 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            [[HXCore shared] ensureServer];
            /* 注入场景：用户是主动注入这个 App 的，所以默认开球。
               但球会在静置 6 秒后淡出到几乎透明，避免 OLED 烧屏。
               长按球可彻底关掉。 */
            [[HXPanel shared] setBallEnabled:YES];
            NSLog(@"[葫芦侠] 已注入 %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)");
        }
    });

    /* 切回前台时保证悬浮球还在 */
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        /* 只有用户开过才重新挂，尊重用户选择 */
        if ([[HXPanel shared] ballEnabled]) [[HXPanel shared] installBall];
    }];
}
TWEAK_M_EOF

    # ---------------- cli（可选命令行，root 下权限最全） ----------------
    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'TOOL_NAME = huluxia\n'
        printf 'huluxia_FILES = main.m\n'
        printf 'huluxia_CFLAGS = -I../core -O2 -Wall -Wno-unused-parameter -fobjc-arc\n'
        printf 'huluxia_FRAMEWORKS = Foundation\n'
        printf 'huluxia_LDFLAGS = -L$(THEOS_STAGING_DIR)/usr/lib -lHuluXia -Wl,-rpath,/usr/lib\n'
        printf 'ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\n'
        printf 'huluxia_LDFLAGS += -lroothide -Wl,-rpath,@loader_path/.jbroot/usr/lib\n'
        printf 'endif\n'
        printf 'huluxia_INSTALL_PATH = /usr/bin\n'
        printf 'huluxia_CODESIGN_FLAGS = -S../ent.plist\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/tool.mk\n'
    } > "$d/cli/Makefile"

    cat > "$d/cli/main.m" <<'CLI_M_EOF'
#import <Foundation/Foundation.h>
#import "HXCore.h"

static void cli_help(void)
{
    printf("葫芦侠 CLI v2.0 (私有 API)\n\n");
    printf("  huluxia                       进入交互模式\n");
    printf("  huluxia ps [app]              进程列表\n");
    printf("  huluxia sel <pid|名|0>        选择目标（0 = 自身）\n");
    printf("  huluxia search 1000 I32       首次搜索\n");
    printf("  huluxia refine 999 I32 smaller  二次搜索\n");
    printf("  huluxia list 0 50             结果列表\n");
    printf("  huluxia editall 9999 I32      批量修改\n");
    printf("  huluxia write 0x... 9999 I32  写地址\n");
    printf("  huluxia freeze add 0x... 9999 I32   加入锁定\n");
    printf("  huluxia daemon 200            守护持续写回\n");
    printf("  huluxia tap 200 400           点击 / swipe / long\n");
    printf("  huluxia serve 8080            启动面板服务\n");
    printf("  huluxia help                  全部命令\n\n");
    printf("提示: 以 root 运行且二进制已签 ent.plist，task_for_pid 才可用\n");
}

static void cli_menu(HXCore *core)
{
    char line[512];
    printf("\n葫芦侠交互模式（输入 help 看命令，quit 退出）\n");
    for (;;) {
        printf("huluxia> ");
        fflush(stdout);
        if (!fgets(line, sizeof(line), stdin)) break;
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        if (!strcmp(line, "quit") || !strcmp(line, "exit")) break;
        NSString *out = [core run:[NSString stringWithUTF8String:line]];
        printf("%s", [out UTF8String]);
        fflush(stdout);
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        HXCore *core = [HXCore shared];
        if (argc <= 1) { cli_menu(core); return 0; }
        if (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h")) { cli_help(); return 0; }
        NSMutableString *cmd = [NSMutableString string];
        for (int i = 1; i < argc; i++) {
            [cmd appendFormat:@"%s%s", (i > 1 ? " " : ""), argv[i]];
        }
        NSString *out = [core run:cmd];
        printf("%s", [out UTF8String]);
        fflush(stdout);
    }
    return 0;
}
CLI_M_EOF

    # ---------------- 桌面图标 ----------------
    icon_src=""
    if [ -n "$3" ] && [ -f "$3" ]; then
        icon_src="$3"
    else
        for f in ./*.png ./*.jpg ./*.jpeg ./icon*.png ../icon*.png; do
            if [ -f "$f" ]; then icon_src="$f"; break; fi
        done
    fi
    if [ -n "$icon_src" ]; then
        printf '图标: 使用 %s\n' "$icon_src"
    else
        printf '图标: 未找到图片，使用内置葫芦侠图标\n'
    fi
    hx_make_icon "$icon_src" "$d/Resources/AppIcon" \
        && printf '图标: 已生成 %s 个尺寸\n' "$(ls "$d/Resources/AppIcon" 2>/dev/null | wc -l | tr -d ' ')" \
        || printf '图标: 生成失败（不影响编译，可稍后 sh huluxia.sh icon <图片> 补上）\n'

    # 悬浮球图标：单独存一份 ball.png 随 deb 装到设备，
    # 这样桌面 App 和注入 dylib 的悬浮球都显示你指定的图
    hx_make_ball "$icon_src" "$d/Resources" \
        && printf '悬浮球图标: 已生成 ball.png\n' \
        || printf '悬浮球图标: 生成失败（将回退到内置图形）\n'

    # ---------------- 控制面板 UI ----------------
    if [ -n "$ui_file" ] && [ -f "$ui_file" ]; then
        cp "$ui_file" "$d/Resources/ui.html"
        cp "$ui_file" "$d/layout/usr/share/huluxia/ui.html"
        printf 'UI: 使用指定面板 %s\n' "$ui_file"
    else
        found=0
        for f in ./*.html ./葫芦侠*.html ../*.html ../../*.html; do
            if [ -f "$f" ]; then
                cp "$f" "$d/Resources/ui.html"
                cp "$f" "$d/layout/usr/share/huluxia/ui.html"
                printf 'UI: 已采用现有面板 %s\n' "$f"
                found=1
                break
            fi
        done
        if [ "$found" != "1" ]; then
            ui_fallback > "$d/Resources/ui.html"
            cp "$d/Resources/ui.html" "$d/layout/usr/share/huluxia/ui.html"
            printf 'UI: 已生成内置面板（手机适配版）\n'
        fi
    fi

    # ---------------- mono：单体自包含 dylib（TrollFool / 注入 IPA 用） ----------------
    # 这个 dylib 把 引擎+面板+自启逻辑 全部编进一个文件，
    # 并且把 ui.html 以字节数组内嵌进二进制 —— 注入任何 IPA 都能独立工作，
    # 不依赖设备上有没有 /usr/share/huluxia/ui.html，也不需要 MobileSubstrate。
    mkdir -p "$d/mono"

    {
        printf 'include $(THEOS)/makefiles/common.mk\n'
        printf '\n'
        printf 'LIBRARY_NAME = HuluXiaInject\n'
        printf 'HuluXiaInject_FILES = HuluXiaInject.m embedded_ui.c ../core/HXEngine.c ../core/HXEngineTouch.c ../core/HXServer.c ../ui/HXPanel.m\n'
        printf 'HuluXiaInject_CFLAGS = -I../core -I../ui -O2 -Wall -Wno-unused-parameter -fobjc-arc -fno-objc-arc-exceptions\n'
        printf 'HuluXiaInject_FRAMEWORKS = UIKit Foundation WebKit CoreGraphics QuartzCore\n'
        printf 'HuluXiaInject_PRIVATE_FRAMEWORKS = IOKit\n'
        printf 'HuluXiaInject_LDFLAGS = -lpthread -Wl,-undefined,dynamic_lookup\n'
        printf 'HuluXiaInject_INSTALL_PATH = /usr/lib\n'
        printf '\n'
        printf 'include $(THEOS_MAKE_PATH)/library.mk\n'
    } > "$d/mono/Makefile"

    cat > "$d/mono/HuluXiaInject.m" <<'MONO_M_EOF'
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import "HXEngine.h"
#import "HXPanel.h"

/* ==========================================================================
   葫芦侠 · 单体注入 dylib
   用途：用 TrollFool / 其他注入工具塞进任意 IPA，做成自带修改器。

   特点：
   1. 自包含 —— 引擎、面板、UI 页面全在这一个文件里
   2. 自启动 —— constructor 自动跑，不用 MobileSubstrate，不用 filter plist
   3. 自包含 UI —— 控制面板页面以字节数组内嵌，不读外部文件
   4. 自身进程 —— 直接 mach_task_self()，注入到哪个 App 就改哪个 App
   ========================================================================== */

__attribute__((constructor))
static void HuluXiaInjectEntry(void)
{
    @autoreleasepool {
        /* 延迟到主线程，等 App 界面就绪再挂悬浮球 */
        dispatch_async(dispatch_get_main_queue(), ^{
            /* 直接选自身进程：注入到谁就改谁，不需要 task_for_pid 权限 */
            hx_run("sel 0");

            /* 启动面板服务（会用内嵌的 UI） */
            hx_server_start(8080, NULL);

            /* 悬浮球：默认开，但静置会自动淡出防烧屏，长按可关 */
            [[HXPanel shared] setBallEnabled:YES];

            NSLog(@"[葫芦侠] 已注入并启动 -> %@",
                  [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)");
        });
    }
}
MONO_M_EOF

    # 内嵌 UI：把 html 转成 C 字节数组
    if [ -f "$d/Resources/ui.html" ]; then
        hx_embed_ui "$d/Resources/ui.html" "$d/mono/embedded_ui.c" \
            && printf '内嵌 UI: 已生成 mono/embedded_ui.c\n' \
            || printf '内嵌 UI: 生成失败（将回退到外部 ui.html）\n'
    else
        printf 'const unsigned char hx_embedded_ui[] = {0};\n' > "$d/mono/embedded_ui.c"
        printf 'const unsigned int hx_embedded_ui_len = 0;\n' >> "$d/mono/embedded_ui.c"
    fi

    printf '单体 dylib: mono/HuluXiaInject.dylib（TrollFool 注入 IPA 用）\n'

    # 悬浮球图标随 deb 装到设备（App 与 dylib 都能读到）
    if [ -f "$d/Resources/ball.png" ]; then
        mkdir -p "$d/layout/usr/share/huluxia"
        cp -f "$d/Resources/ball.png" "$d/layout/usr/share/huluxia/ball.png"
        printf '悬浮球图标: 已打包进 deb\n'
    fi

    # ---------------- GitHub Actions 云端编译（没电脑也能编） ----------------
    mkdir -p "$d/.github/workflows"
    cat > "$d/.github/workflows/build.yml" <<'YAML_EOF'
name: 编译葫芦侠

on:
  push:
    branches: [ main, master ]
  workflow_dispatch:
    inputs:
      scheme:
        description: '选择越狱类型（你是 RootHide 就选 roothide）'
        required: true
        default: 'roothide'
        type: choice
        options:
          - roothide
          - rootless
          - rootful
          - all

jobs:
  build:
    runs-on: macos-latest
    strategy:
      fail-fast: false
      matrix:
        scheme: ${{ fromJSON(github.event.inputs.scheme == 'all' && '["roothide","rootless","rootful"]' || format('["{0}"]', github.event.inputs.scheme || 'roothide')) }}

    steps:
      - name: 检出代码
        uses: actions/checkout@v4

      - name: 安装 theos + SDK + ldid
        uses: waruhachi/theos-action@v2.6.5
        with:
          theos-src: 'roothide/theos'
          theos-branch: 'master'
          sdks-src: 'theos/sdks'
          sdks-branch: 'master'

      - name: 编译 (${{ matrix.scheme }})
        run: |
          export THEOS=~/theos
          make clean || true
          make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=${{ matrix.scheme }}

      - name: 收集 deb
        run: |
          mkdir -p out
          find . -name "*.deb" -exec cp {} out/ \; 2>/dev/null || true
          ls -la out/

      - name: 上传产物
        uses: actions/upload-artifact@v4
        with:
          name: 葫芦侠-${{ matrix.scheme }}
          path: out/*.deb
          if-no-files-found: warn
YAML_EOF
    printf '云端编译: 已生成 .github/workflows/build.yml\n'

    # ---------------- README ----------------
    cat > "$d/README.md" <<'RD_EOF'
# 葫芦侠 iOS 越狱版 v3.0

**一次编译，产出两种形态：**

| 形态 | 产物 | 位置 |
|---|---|---|
| A. 越狱软件 | `HuluXia.app` | `/Applications/HuluXia.app` 桌面图标，点开即用 |
| B. 注入 dylib | `HuluXiaTweak.dylib` + plist | `/Library/MobileSubstrate/DynamicLibraries/` |

附加：`HuluXia.dylib`（引擎）、`HuluXiaUI.dylib`（面板）、`/usr/bin/huluxia`（命令行）

私有 / 系统级 API：

| 能力 | 接口 |
|---|---|
| 跨进程内存搜索·修改·锁定 | `task_for_pid` + `vm_read_overwrite` / `vm_write` / `vm_protect` |
| 内存区域枚举 | `vm_region_64`（VM_REGION_BASIC_INFO_64） |
| 进程列表 | `sysctl(KERN_PROC_ALL)` + `proc_pidpath` |
| 模块基址 / 偏移 | `task_info(TASK_DYLD_INFO)` + `dyld_all_image_infos` |
| 触摸模拟 | IOKit 私有 `IOHIDEventSystemClient` + `IOHIDEventCreateDigitizerFingerEvent` |
| 面板 | dylib 内 loopback HTTP + WKWebView，原 HTML 面板零改动复用 |

## 编译安装

```sh
sh huluxia.sh doctor      # 查环境 + 自动识别越狱类型
make package              # 出 deb
dpkg -i debs/*.deb
sbreload                  # 或 killall -9 SpringBoard
```

### RootHide（隐根）越狱必读

roothide 的 jbroot 是**随机路径**，必须让 theos 知道：

```sh
# 自动生成时已按你的环境写入 THEOS_PACKAGE_SCHEME，确认一下：
grep THEOS_PACKAGE_SCHEME Makefile       # 应显示 roothide

# 若不对，手动切换（切换后必须先 clean）
sh huluxia.sh scheme roothide
make clean && make package
```

或临时指定：`make package THEOS_PACKAGE_SCHEME=roothide`

**常见坑：**
- `theos-dependencies` 只是依赖包，**还要单独装 theos 本体**（Sileo 搜 theos）
- control 的 Architecture 必须是 `iphoneos-arm64e`
- postinst 里必须跑 `uicache -a`，否则系统 App 未注册、安装失败
- 只需 `make package`，theos 会自动把文件装到正确的 jbroot 下

### UI 面板放哪

装到 `/var/mobile/Library/HuluXia/ui.html` —— 该目录在 rootful / rootless /
roothide 三种越狱下路径一致且可写。引擎会依次探测以下位置：

```
/var/mobile/Library/HuluXia/ui.html          ← 首选（postinst 自动部署到这里）
/var/jb/usr/share/huluxia/ui.html            ← rootless
/usr/share/huluxia/ui.html                   ← rootful
```

换面板：
```sh
cp 我的面板.html /var/mobile/Library/HuluXia/ui.html
```
不用重装，重开面板即生效。

## 形态 A：桌面 App

装完桌面出现葫芦图标，打开 → 点「打开控制面板」→ 选进程 → 搜索修改。

App 在 deb 安装时被设为 **setuid root**，所以 `task_for_pid` 可用，能读改别的进程。

## 形态 B：注入 dylib（推荐，权限问题最少）

把 dylib 注入目标 App，面板里执行 `sel 0` 选自身进程，
内存读写走 `mach_task_self()`，**完全不需要 `task_for_pid`**。

一行改注入目标：

```sh
sh huluxia.sh inject com.example.game     # 换成你的游戏包名
make package && dpkg -i debs/*.deb
```

或直接编辑 `tweak/HuluXiaTweak.plist`：

```
{ Filter = { Bundles = ( "com.example.game" ); }; }
```

多个 App 一起注入：

```
{ Filter = { Bundles = ( "com.a.game", "com.b.game" ); }; }
```

只想要 dylib 不要 deb：`make`，然后

```sh
find .theos -name "HuluXiaTweak.dylib"
find .theos -name "*.dylib"
```

## 换图标 / 换面板

```sh
sh huluxia.sh icon /var/mobile/我的图标.png    # 重新生成各尺寸图标
sh huluxia.sh ui   /var/mobile/我的面板.html    # 换控制面板（不用重装）
```

## 命令速查

类型 `I8 I16 I32 I64 U8 U16 U32 U64 F32 F64 UTF8`
模式 `exact bigger smaller changed unchanged fuzzy range joint any`

```
ps app / sel <pid|名|0> / target / info
search <值> [类型] [模式]       首搜
refine <值> [类型] [模式]       二次搜索
count / list [off] [n]          结果
read <addr> [类型] / write <addr> <值> [类型]
editall <值> [类型] [条数]
freeze add <addr> <值> [类型]   锁定
autolock on [ms] / off / status 自动锁定（后台持续写回）
tick                            写回一次
modules / offset                模块基址与偏移
tap / swipe / long / down move up   触摸模拟
```

## 面板里的宿主 API（原 HTML 零改动可用）

```js
h5gg.searchNumber("1000","I32") / h5gg.getResults(100) / h5gg.editAll("9999","I32")
gg.TYPE_DWORD / gg.click(x,y) / gg.swipe(...) / gg.longClick(...)
parent.h5gg / parent.h5 / parent.host / parent.gg / parent.toast()
window.hxApi("ps app")          执行任意命令
```
`parent === window`，所以原 HTML 里 `window.parent.h5gg.xxx` 的写法照常生效。
RD_EOF

    cp "$0" "$d/huluxia.sh" 2>/dev/null
    chmod 0755 "$d/huluxia.sh" 2>/dev/null

    printf '\n========== 工程已生成: %s ==========\n' "$d"
    printf '下一步（手机上）:\n'
    printf '  export THEOS=/var/theos\n'
    printf '  cd %s && make package && dpkg -i debs/*.deb\n' "$d"
    printf '\n想改成注入某个游戏:\n'
    printf '  sh %s/huluxia.sh inject com.example.game\n' "$d"
}

# ============================================================================
#  图标生成（Python/PIL 优先，其次 sips / convert）
# ============================================================================
hx_make_icon() {
    src="$1"
    out="$2"
    mkdir -p "$out"

    if command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" 2>/dev/null; then
        python3 - "$src" "$out" <<'PY_ICON'
import sys, os
from PIL import Image, ImageDraw

src_path = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ""
out_dir  = sys.argv[2]
W = H = 1024
GREEN = (0, 194, 95)
WHITE = (255, 255, 255)
DARK  = (65, 65, 65)

def builtin():
    """内置葫芦侠图标：绿上白下 + 平缓弧线 + 左上白圆角 + 左下黑竖线"""
    im = Image.new('RGB', (W, H), WHITE)
    base = int(H * 0.46)
    amp  = int(H * 0.07)
    pts = [(0, 0), (W, 0)]
    for x in range(W, -1, -1):
        t = 2.0 * x / W - 1.0
        y = int(base + amp * (1.0 - t * t))
        pts.append((x, y))
    mask = Image.new('L', (W, H), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    im.paste(Image.new('RGB', (W, H), GREEN), (0, 0), mask)

    d = ImageDraw.Draw(im)
    d.rounded_rectangle([70, 70, 250, 250], radius=34, fill=WHITE)
    d.rounded_rectangle([78, H - 250, 108, H - 80], radius=14, fill=DARK)
    return im

def from_source(path):
    """用用户图片，内缩到安全区（iOS 会叠圆角遮罩），背景用边缘色延展"""
    src = Image.open(path).convert('RGB')
    scale = 0.84
    sw = int(W * scale)
    rz = src.resize((sw, sw), Image.LANCZOS)
    top = src.getpixel((src.width // 2, 3))
    bot = src.getpixel((src.width // 2, src.height - 3))
    canvas = Image.new('RGB', (W, H))
    dd = ImageDraw.Draw(canvas)
    dd.rectangle([0, 0, W, H // 2], fill=top)
    dd.rectangle([0, H // 2, W, H], fill=bot)
    canvas.paste(rz, ((W - sw) // 2, (H - sw) // 2))
    return canvas

try:
    im = from_source(src_path) if src_path and os.path.exists(src_path) else builtin()
except Exception:
    im = builtin()

sizes = {
    'AppIcon29x29@2x.png':     58,
    'AppIcon29x29@3x.png':     87,
    'AppIcon40x40@2x.png':     80,
    'AppIcon40x40@3x.png':    120,
    'AppIcon60x60@2x.png':    120,
    'AppIcon60x60@3x.png':    180,
    'AppIcon76x76@2x.png':    152,
    'AppIcon83.5x83.5@2x.png': 167,
    'AppIcon1024.png':        1024,
}
for name, s in sizes.items():
    im.resize((s, s), Image.LANCZOS).save(os.path.join(out_dir, name))
print("icon-ok")
PY_ICON
        [ $? -eq 0 ] && return 0
    fi

    if [ -n "$src" ] && [ -f "$src" ]; then
        for spec in "58:AppIcon29x29@2x.png" "87:AppIcon29x29@3x.png" "80:AppIcon40x40@2x.png" \
                    "120:AppIcon40x40@3x.png" "120:AppIcon60x60@2x.png" "180:AppIcon60x60@3x.png" \
                    "152:AppIcon76x76@2x.png" "167:AppIcon83.5x83.5@2x.png"; do
            sz="${spec%%:*}"
            nm="${spec##*:}"
            if command -v sips >/dev/null 2>&1; then
                sips -z "$sz" "$sz" "$src" --out "$out/$nm" >/dev/null 2>&1
            elif command -v convert >/dev/null 2>&1; then
                convert "$src" -resize "${sz}x${sz}" "$out/$nm" >/dev/null 2>&1
            else
                return 1
            fi
        done
        return 0
    fi

    return 1
}

# ============================================================================
#  悬浮球图标（ball.png）—— 桌面 App 与注入 dylib 共用
# ============================================================================
hx_make_ball() {
    src="$1"
    out="$2"
    mkdir -p "$out"

    if command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" 2>/dev/null; then
        python3 - "$src" "$out" <<'PY_BALL'
import sys, os
from PIL import Image, ImageDraw

src_path = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else ""
out_dir  = sys.argv[2]
SIZE = 180          # 悬浮球实际显示 54pt，@3x 用 180 足够清晰
GREEN = (0, 194, 95)
WHITE = (255, 255, 255)
DARK  = (65, 65, 65)

def builtin():
    """内置图形：绿上白下 + 平缓弧线 + 左上白圆角 + 左下黑竖线"""
    im = Image.new('RGB', (SIZE, SIZE), WHITE)
    base = int(SIZE * 0.46)
    amp  = int(SIZE * 0.07)
    pts = [(0, 0), (SIZE, 0)]
    for x in range(SIZE, -1, -1):
        t = 2.0 * x / SIZE - 1.0
        y = int(base + amp * (1.0 - t * t))
        pts.append((x, y))
    mask = Image.new('L', (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    im.paste(Image.new('RGB', (SIZE, SIZE), GREEN), (0, 0), mask)
    d = ImageDraw.Draw(im)
    r = SIZE / 1024.0
    d.rounded_rectangle([70*r, 70*r, 250*r, 250*r], radius=34*r, fill=WHITE)
    d.rounded_rectangle([78*r, SIZE-250*r, 108*r, SIZE-80*r], radius=14*r, fill=DARK)
    return im

def from_source(path):
    src = Image.open(path).convert('RGB')
    return src.resize((SIZE, SIZE), Image.LANCZOS)

try:
    im = from_source(src_path) if src_path and os.path.exists(src_path) else builtin()
except Exception:
    im = builtin()

im.save(os.path.join(out_dir, 'ball.png'))
print("ball-ok")
PY_BALL
        [ $? -eq 0 ] && return 0
    fi

    if [ -n "$src" ] && [ -f "$src" ]; then
        if command -v sips >/dev/null 2>&1; then
            sips -z "$SIZE" "$SIZE" "$src" --out "$out/ball.png" >/dev/null 2>&1 && return 0
        fi
        if command -v convert >/dev/null 2>&1; then
            convert "$src" -resize 180x180 "$out/ball.png" >/dev/null 2>&1 && return 0
        fi
    fi

    return 1
}

# ============================================================================
#  手机端内置面板（找不到原 HTML 时使用）
# ============================================================================
ui_fallback() {
    cat <<'UI_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,user-scalable=no,viewport-fit=cover">
<title>葫芦侠 iOS</title>
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;padding:8px;background:#121212;color:#e0e0e0;font:14px -apple-system,Arial}
h1{font-size:16px;margin:2px 0 8px;color:#81c784;text-align:center}
.card{background:#1e1e1e;border:1px solid #333;border-radius:10px;padding:10px;margin-bottom:9px}
.t{font-size:12px;color:#81c784;font-weight:bold;margin-bottom:7px}
.row{display:flex;gap:5px;flex-wrap:wrap;margin-bottom:6px;align-items:center}
input,select{flex:1;min-width:56px;background:#0d1117;border:1px solid #444;color:#e0e0e0;border-radius:6px;padding:8px;font-size:14px}
textarea{width:100%;height:64px;background:#0d1117;border:1px solid #444;color:#7ee787;border-radius:6px;padding:8px;font:12px monospace}
button{background:linear-gradient(180deg,#4caf50,#2e7d32);border:0;color:#fff;padding:9px 11px;border-radius:6px;font-size:13px;font-weight:bold}
button.alt{background:linear-gradient(180deg,#1f6feb,#1158c7)}
button.red{background:linear-gradient(180deg,#da3633,#a41e1b)}
button:active{transform:scale(.95);opacity:.85}
pre{background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:8px;font:11px monospace;color:#7ee787;
    max-height:170px;overflow:auto;white-space:pre-wrap;word-break:break-all;min-height:38px}
#bar{background:#1b5e20;border-radius:8px;padding:8px;font-size:12px;margin-bottom:8px;text-align:center}
</style>
</head>
<body>
<h1>🎃 葫芦侠 iOS · 私有 API</h1>
<div id="bar">目标: 未连接</div>

<div class="card">
  <div class="t">🎯 目标进程</div>
  <div class="row">
    <select id="procs"></select>
    <button onclick="doSel()">选择</button>
    <button class="alt" onclick="loadPs()">刷新</button>
  </div>
  <div class="row"><button class="alt" onclick="cmd('sel 0')">选自身进程(推荐)</button></div>
</div>

<div class="card">
  <div class="t">🔍 内存搜索</div>
  <div class="row">
    <input id="val" placeholder="值" value="1000">
    <select id="type">
      <option>I32</option><option>I64</option><option>F32</option><option>F64</option>
      <option>U8</option><option>U16</option><option>U32</option><option>U64</option>
      <option>I8</option><option>I16</option><option>UTF8</option>
    </select>
    <select id="mode">
      <option value="exact">精确</option><option value="bigger">变大</option>
      <option value="smaller">变小</option><option value="changed">变化</option>
      <option value="unchanged">不变</option><option value="fuzzy">模糊</option>
      <option value="range">范围</option>
    </select>
  </div>
  <div class="row">
    <button onclick="doSearch()">首搜</button>
    <button class="alt" onclick="doRefine()">再搜</button>
    <button onclick="doList()">结果</button>
    <button class="red" onclick="cmd('clear')">清空</button>
  </div>
</div>

<div class="card">
  <div class="t">✏️ 修改 / 锁定</div>
  <div class="row">
    <input id="nval" placeholder="新值" value="9999">
    <button onclick="doEdit()">全部修改</button>
    <button class="alt" onclick="doFreeze()">首条锁定</button>
  </div>
  <div class="row">
    <button class="alt" onclick="cmd('freeze list')">锁定列表</button>
    <button class="alt" onclick="cmd('tick')">写回一次</button>
    <button class="red" onclick="cmd('freeze clear')">清空锁定</button>
  </div>
  <div class="row">
    <button onclick="cmd('autolock on 300')">▶ 自动锁定</button>
    <button class="red" onclick="cmd('autolock off')">■ 停止</button>
    <button class="alt" onclick="cmd('autolock status')">状态</button>
  </div>
</div>

<div class="card">
  <div class="t">👆 触摸模拟（IOKit HID 私有）</div>
  <div class="row">
    <input id="x1" placeholder="x1" value="200" style="max-width:66px">
    <input id="y1" placeholder="y1" value="400" style="max-width:66px">
    <input id="x2" placeholder="x2" value="200" style="max-width:66px">
    <input id="y2" placeholder="y2" value="900" style="max-width:66px">
  </div>
  <div class="row">
    <button onclick="cmd('tap '+v('x1')+' '+v('y1'))">点击</button>
    <button class="alt" onclick="cmd('swipe '+v('x1')+' '+v('y1')+' '+v('x2')+' '+v('y2')+' 300')">滑动</button>
    <button class="alt" onclick="cmd('long '+v('x1')+' '+v('y1')+' 1000')">长按</button>
  </div>
</div>

<div class="card">
  <div class="t">🛠️ 工具</div>
  <div class="row">
    <button class="alt" onclick="cmd('regions')">内存区域</button>
    <button class="alt" onclick="cmd('modules')">模块基址</button>
    <button class="alt" onclick="cmd('info')">设备信息</button>
  </div>
</div>

<div class="card">
  <div class="t">📜 命令（每行一条）</div>
  <textarea id="script" spellcheck="false">target</textarea>
  <div class="row"><button onclick="runScript()">执行</button></div>
</div>

<div class="card">
  <div class="t">📤 输出</div>
  <pre id="out">就绪</pre>
  <div class="row"><button class="red" onclick="exitHtmlRunner()">✕ 收起面板</button></div>
</div>

<script>
function api(c){try{return window.hxApi?window.hxApi(c):sync(c);}catch(e){return '';}}
function sync(c){var x=new XMLHttpRequest();x.open('GET','/api?c='+encodeURIComponent(c),false);x.send(null);return x.responseText||'';}
function v(id){return document.getElementById(id).value;}
function out(s){document.getElementById('out').textContent=s;}
function cmd(c){var r=api(c);out('$ '+c+'\n'+r);return r;}
function loadPs(){
  var s=api('ps app'),L=s.split('\n'),sel=document.getElementById('procs');
  sel.innerHTML='';
  for(var i=1;i<L.length;i++){
    var p=L[i].trim().split(/\s+/);
    if(p.length<2||!p[0]||isNaN(parseInt(p[0],10)))continue;
    var o=document.createElement('option');
    o.value=p[0];o.textContent=p[0]+' · '+(p[1]||'');
    sel.appendChild(o);
  }
  if(!sel.options.length){var o2=document.createElement('option');o2.textContent='(无进程)';sel.appendChild(o2);}
}
function doSel(){var p=document.getElementById('procs').value;cmd('sel '+p);loadBar();}
function loadBar(){var s=api('target'),o={};
  s.split('\n').forEach(function(l){var q=l.split('=');if(q.length>1)o[q[0]]=q[1];});
  document.getElementById('bar').textContent='目标: '+(o.name||'未连接')+'  pid='+(o.pid||'-')+'  '+(o.package||'');}
function doSearch(){cmd('search '+v('val')+' '+v('type')+' '+v('mode'));}
function doRefine(){cmd('refine '+v('val')+' '+v('type')+' '+v('mode'));}
function doList(){cmd('list 0 60');}
function doEdit(){cmd('editall '+v('nval')+' '+v('type'));}
function doFreeze(){
  var s=api('list 0 1'),m=s.split('\n')[1];
  if(!m){out('无结果');return;}
  var a=m.trim().split(/\s+/)[0];
  cmd('freeze add '+a+' '+v('nval')+' '+v('type'));
}
function runScript(){
  var L=document.getElementById('script').value.split('\n'),r='';
  for(var i=0;i<L.length;i++){var c=L[i].trim();if(!c)continue;r+='$ '+c+'\n'+api(c)+'\n';}
  out(r);
}
loadPs();loadBar();
</script>
</body>
</html>
UI_EOF
}

# ============================================================================
#  设备端动作
# ============================================================================
pick_theos() {
    if [ -n "$THEOS" ] && [ -d "$THEOS" ]; then return; fi
    for t in "$THEOS" "$HOME/theos" /var/mobile/theos /var/jb/var/theos /var/jb/theos /var/theos /usr/theos; do
        if [ -d "$t" ]; then
            THEOS="$t"
            export THEOS
            printf '使用 theos: %s\n' "$THEOS"
            return
        fi
    done
}

resolve_dir() {
    if [ -n "$1" ] && [ "$1" != "-" ]; then printf '%s' "$1"; return; fi
    if [ -f "$PWD/Makefile" ] || [ -d "$PWD/core" ] || [ -d "$PWD/tweak" ]; then
        printf '%s' "$PWD"; return
    fi
    printf '%s' "$DEF_DIR"
}

do_scheme() {
    cur="$(detect_jb)"
    if [ -n "$1" ]; then
        case "$1" in
            roothide|rootless|rootful) ;;
            *) printf '用法: sh huluxia.sh scheme [roothide|rootless|rootful]\n'; exit 1 ;;
        esac
        d="$(resolve_dir "")"
        mf="$d/Makefile"
        if [ ! -f "$mf" ]; then printf '找不到 Makefile: %s\n' "$mf"; exit 1; fi
        if [ "$1" = "rootful" ]; then
            sed -i.bak 's|^THEOS_PACKAGE_SCHEME ?=.*|THEOS_PACKAGE_SCHEME ?= |' "$mf"
        else
            sed -i.bak "s|^THEOS_PACKAGE_SCHEME ?=.*|THEOS_PACKAGE_SCHEME ?= $1|" "$mf"
        fi
        rm -f "$mf.bak"
        printf '已设置 THEOS_PACKAGE_SCHEME=%s\n' "$1"
        printf '下一步: make clean && make package\n'
        return
    fi
    printf '当前越狱类型: %s\n' "$cur"
    printf '手动指定: sh huluxia.sh scheme roothide|rootless|rootful\n'
}

do_build() {
    d="$(resolve_dir "${1:-}")"
    if [ ! -d "$d" ]; then
        printf '工程不存在: %s（先执行: sh huluxia.sh gen）\n' "$d"
        exit 1
    fi
    pick_theos
    cd "$d" || exit 1
    if command -v make >/dev/null 2>&1; then
        make package
    else
        printf '没有 make，请先安装（apt-get install make ldid dpkg）\n'
        exit 1
    fi
}

do_install() {
    d="$(resolve_dir "${1:-}")"
    deb=""
    for f in "$d"/debs/*.deb "$d"/packages/*.deb; do
        [ -f "$f" ] && deb="$f" && break
    done
    if [ -z "$deb" ]; then
        printf '没找到 deb，先执行: sh huluxia.sh build\n'
        exit 1
    fi
    printf '安装 %s\n' "$deb"
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -i "$deb"
    else
        printf '请手动用 Filza / Sileo 安装该 deb\n'
    fi
}

do_inject() {
    d=""
    bids=""
    for a in "$@"; do
        case "$a" in
            -d|--dir) d="__next__"; continue ;;
            *) if [ "$d" = "__next__" ]; then d="$a"; else bids="$bids $a"; fi ;;
        esac
    done
    if [ -z "$d" ] || [ "$d" = "__next__" ]; then d="$(resolve_dir "")"; fi
    bids="$(printf '%s' "$bids" | sed 's/^ //')"
    if [ -z "$bids" ]; then
        printf '用法: sh huluxia.sh inject <bundle.id> [更多 id...]\n'
        printf '例如: sh huluxia.sh inject com.tencent.xin\n'
        exit 1
    fi
    if [ ! -d "$d/tweak" ]; then
        printf '工程不存在: %s/tweak（先执行 gen）\n' "$d"
        exit 1
    fi
    plist="$d/tweak/HuluXiaTweak.plist"
    line='{ Filter = { Bundles = ( '
    first=1
    for b in $bids; do
        if [ "$first" = "1" ]; then line="$line\"$b\""; first=0
        else line="$line, \"$b\""; fi
    done
    line="$line ); }; }"
    printf '%s\n' "$line" > "$plist"
    cat "$plist"
    printf '\n注入目标已写入。重新编译安装生效:\n'
    printf '  cd %s && make package && dpkg -i debs/*.deb\n' "$d"
}

do_icon() {
    src="$1"
    d="$(resolve_dir "${2:-}")"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        printf '用法: sh huluxia.sh icon <图片> [工程目录]\n'
        exit 1
    fi
    if [ ! -d "$d/Resources" ]; then
        printf '工程不存在: %s\n' "$d"
        exit 1
    fi
    if hx_make_icon "$src" "$d/Resources/AppIcon"; then
        printf '图标已生成 → %s/Resources/AppIcon/\n' "$d"
        printf '重新 make package 安装后生效\n'
    else
        printf '图标生成失败：需要 python3+PIL，或 sips(Mac)，或 ImageMagick\n'
        printf '  安装: apt-get install python3 python3-pip && pip3 install pillow\n'
        exit 1
    fi
}

do_ui() {
    src="$1"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        printf '用法: sh huluxia.sh ui <文件.html>\n'
        exit 1
    fi
    cp "$src" "$UI_DST" && printf '面板已替换: %s\n' "$UI_DST"
    d="${2:-$DEF_DIR}"
    [ -d "$d/Resources" ] && cp "$src" "$d/Resources/ui.html"
    [ -d "$d/layout/usr/share/huluxia" ] && cp "$src" "$d/layout/usr/share/huluxia/ui.html"
    printf '重新打开面板即可，无需重启\n'
}

do_respring() {
    if [ "$(id -u)" = "0" ]; then
        if command -v sbreload >/dev/null 2>&1; then sbreload; return; fi
        killall -9 SpringBoard 2>/dev/null || killall backboardd 2>/dev/null
        printf '已执行 respring\n'
    else
        printf '需要 root 权限（su 后重试）\n'
    fi
}

# ============================================================================
#  入口
# ============================================================================
case "${1:-}" in
    gen|g|generate)
        shift
        gen_project "${1:-$DEF_DIR}" "${2:-}" "${3:-}"
        ;;
    doctor|doc)
        doctor
        ;;
    scheme)
        shift
        do_scheme "$1"
        ;;
    build|b|make)
        shift
        do_build "${1:-$DEF_DIR}"
        ;;
    install|i)
        shift
        do_install "${1:-$DEF_DIR}"
        ;;
    inject|inj)
        shift
        do_inject "$@"
        ;;
    icon)
        shift
        do_icon "$1" "${2:-}"
        ;;
    ui)
        shift
        do_ui "$1" "$2"
        ;;
    respring|rs)
        do_respring
        ;;
    ui-default)
        ui_fallback
        ;;
    help|-h|--help|"")
        usage
        ;;
    *)
        usage
        ;;
esac
