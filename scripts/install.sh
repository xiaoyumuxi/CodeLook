#!/bin/bash
# CodeLook installer — Quick Look previews with syntax highlighting for code and config files.
#
#   curl -fsSL https://github.com/xiaoyumuxi/CodeLook/releases/latest/download/install.sh | bash
#
# Options (when piping, pass them after `bash -s --`):
#   --version vX.Y.Z   install that release instead of the latest one
#   --zip PATH         install from a CodeLook.zip already on disk (e.g. from the Releases page)
#   --dir DIR          where CodeLook.app goes (default: where it is now, else ~/Applications)
#   --refresh          after editing config.yaml: claim its new extensions, re-register
#   --uninstall        remove CodeLook (config.yaml stays)
#
# The installed app carries this script: CodeLook.app/Contents/Resources/install.sh --refresh

set -euo pipefail

REPO="xiaoyumuxi/CodeLook"
EXT_IDS="dev.openres.CodeLook.Preview dev.openres.CodeLook.Fallback"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -t 2 ]; then b=$'\033[1m' y=$'\033[33m' r=$'\033[31m' n=$'\033[0m'; else b="" y="" r="" n=""; fi
say()  { printf '%s==>%s %s\n' "$b" "$n" "$*"; }
warn() { printf '%swarning:%s %s\n' "$y" "$n" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$r" "$n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
CodeLook 安装脚本

  curl -fsSL https://github.com/xiaoyumuxi/CodeLook/releases/latest/download/install.sh | bash
  curl -fsSL …/install.sh | bash -s -- [选项]

  --version vX.Y.Z   安装指定版本（默认最新）
  --zip PATH         从本地的 CodeLook.zip 安装（例如从 Releases 页面下载的）
  --dir DIR          安装目录（默认：已安装的位置，否则 ~/Applications）
  --refresh          改过 config.yaml 的扩展名后：重新认领并注册
  --uninstall        卸载（保留 ~/.config/codelook）
EOF
}

mode=install version="" zip="" dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version)   version="${2:?--version needs a tag, e.g. v0.1.0}"; shift 2 ;;
    --zip)       zip="${2:?--zip needs a path}"; shift 2 ;;
    --dir)       dir="${2:?--dir needs a directory}"; shift 2 ;;
    --refresh)   mode=refresh; shift ;;
    --uninstall) mode=uninstall; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "未知选项：$1（见 --help）" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "CodeLook 只支持 macOS"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "需要 macOS 13 或更高版本（这台 Mac：$(sw_vers -productVersion)）"

# Where the app is or goes: --dir, else an existing install, else ~/Applications.
if [ -z "$dir" ]; then
  dir="$HOME/Applications"
  if [ ! -d "$dir/CodeLook.app" ] && [ -d /Applications/CodeLook.app ]; then dir=/Applications; fi
fi
app="$dir/CodeLook.app"

reset_quicklook() {
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
}

unregister() {  # $1: an app bundle
  for ext in CodeLookPreview CodeLookFallback; do
    pluginkit -r "$1/Contents/PlugIns/$ext.appex" >/dev/null 2>&1 || true
  done
  "$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

# Claims this Mac's types and config.yaml's extensions, signs the bundle again (its Info.plists
# changed), registers it and turns the extensions on.
activate() {
  say "按这台 Mac 的文件类型和 ~/.config/codelook/config.yaml 认领文件"
  "$app/Contents/MacOS/CodeLook" --update-claims | sed 's/^/    /'
  # Ad-hoc signature, as the release is built; inner bundles first.
  for ext in CodeLookPreview CodeLookFallback; do
    codesign --force --sign - --preserve-metadata=identifier,entitlements,flags \
      "$app/Contents/PlugIns/$ext.appex" 2>/dev/null
  done
  codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$app" 2>/dev/null
  codesign --verify --deep --strict "$app" || die "重新签名后校验失败"

  say "注册 Quick Look 扩展"
  "$LSREGISTER" -f -R -trusted "$app"
  for ext in CodeLookPreview CodeLookFallback; do pluginkit -a "$app/Contents/PlugIns/$ext.appex"; done
  for id in $EXT_IDS; do pluginkit -e use -i "$id"; done
  reset_quicklook

  # Another registered copy (an old download, a source build) can win over this one. Only its
  # registration goes; the files stay, and LaunchServices may find it again if it is opened.
  # pluginkit prints resolved paths (/tmp is /private/tmp), so compare against ours resolved.
  others=$(for id in $EXT_IDS; do pluginkit -m -A -D -v -i "$id" 2>/dev/null; done \
    | awk -F'\t' '$NF ~ /\/Contents\/PlugIns\// {print $NF}' | sed 's#/Contents/PlugIns/.*##' \
    | sort -u | grep -vxF "$(cd "$app" && pwd -P)" || true)
  if [ -n "$others" ]; then
    warn "别的 CodeLook 副本也注册了扩展，会和这一份抢着处理预览，已取消它们的注册（文件没有删）："
    printf '%s\n' "$others" | while IFS= read -r other; do
      printf '    %s\n' "$other" >&2
      unregister "$other"
    done
    reset_quicklook
  fi
}

case "$mode" in
uninstall)
  [ -d "$app" ] || die "$dir 里没有 CodeLook.app（用 --dir 指定）"
  say "卸载 $app"
  for id in $EXT_IDS; do pluginkit -e ignore -i "$id" >/dev/null 2>&1 || true; done
  unregister "$app"
  rm -rf "$app"
  reset_quicklook
  say "已卸载。~/.config/codelook 里的设置没有删除。"
  exit 0
  ;;
refresh)
  [ -d "$app" ] || die "$dir 里没有 CodeLook.app（用 --dir 指定）"
  activate
  say "完成。"
  exit 0
  ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/codelook.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [ -n "$zip" ]; then
  [ -f "$zip" ] || die "找不到文件：$zip"
  cp "$zip" "$tmp/CodeLook.zip"
else
  # CODELOOK_RELEASE_URL: a mirror holding CodeLook.zip and CodeLook.zip.sha256.
  if [ -n "${CODELOOK_RELEASE_URL:-}" ]; then
    base="${CODELOOK_RELEASE_URL%/}"
  elif [ -n "$version" ]; then
    base="https://github.com/$REPO/releases/download/$version"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  say "下载 CodeLook ${version:-（最新版）}"
  curl -fL --retry 3 --progress-bar -o "$tmp/CodeLook.zip" "$base/CodeLook.zip" \
    || die "下载失败：$base/CodeLook.zip"
  curl -fsSL --retry 3 -o "$tmp/CodeLook.zip.sha256" "$base/CodeLook.zip.sha256" \
    || die "下载失败：$base/CodeLook.zip.sha256"
  (cd "$tmp" && shasum -a 256 -c CodeLook.zip.sha256 >/dev/null 2>&1) || die "校验和不对，请重新下载"
fi

ditto -x -k "$tmp/CodeLook.zip" "$tmp/x" || die "不是有效的 CodeLook.zip"
new="$tmp/x/CodeLook.app"
[ -x "$new/Contents/MacOS/CodeLook" ] || die "压缩包里没有 CodeLook.app"
file "$new/Contents/MacOS/CodeLook" | grep -q "$(uname -m)" \
  || die "这个包不含 $(uname -m) 架构：$(file -b "$new/Contents/MacOS/CodeLook")"
ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new/Contents/Info.plist" 2>/dev/null || echo "?")
# Browser downloads are quarantined, and Gatekeeper refuses an app that is not notarized.
xattr -dr com.apple.quarantine "$new" 2>/dev/null || true

mkdir -p "$dir"
if [ -d "$app" ]; then
  say "替换已安装的 $app"
  unregister "$app"
  rm -rf "$app"
fi
say "安装 CodeLook $ver 到 $app"
ditto "$new" "$app"

activate
cat <<EOF

CodeLook $ver 安装好了。在 Finder 里选中文件按空格即可预览。

  设置       ~/.config/codelook/config.yaml（可选，说明见 README）
  在 config.yaml 里新加了扩展名之后：
             "$app/Contents/Resources/install.sh" --refresh
  卸载       "$app/Contents/Resources/install.sh" --uninstall

如果预览没有变化：到“系统设置 › 通用 › 登录项与扩展 › 快速查看”里确认两个 CodeLook 扩展都已打开。
EOF
