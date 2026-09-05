#!/bin/bash
set -euo pipefail
SITE="${NEXA_SITE:-https://terrydavisthe2nd.github.io}"
UPDATE_URL="$SITE/update.json"
APPLICATIONS="${NEXA_APPLICATIONS:-/Applications}"
ROBLOX_APP="$APPLICATIONS/Roblox.app"
ROBLOX_BIN="$ROBLOX_APP/Contents/MacOS/RobloxPlayer"
ROBLOX_PLIST="$ROBLOX_APP/Contents/Info.plist"
NEXA_APP="$APPLICATIONS/Nexa.app"
NEXA_DYLIB="$NEXA_APP/Contents/Resources/libNexa.dylib"
NEXA_PATCHER="$NEXA_APP/Contents/Resources/nexa-machopatch"
SUPPORT="$HOME/Library/Application Support/Nexa"
SUPPORT_GUI="$HOME/Library/Application Support/NexaGUI"
SCRIPTS="$HOME/Documents/Nexa"
BUNDLE_ID="com.nexa.executor.gui"
INSTALLER_APP="Contents/MacOS/RobloxPlayerInstaller.app"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nexa-install.XXXXXX")"
cleanup() { [ -n "${NEXA_KEEP_WORK:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT
if [ -t 1 ]; then
  B=$'\033[1m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  B=""; GRN=""; YEL=""; RED=""; DIM=""; RST=""
fi
step() { :; }
info() { :; }
ok()   { :; }
warn() { :; }
die()  { printf "error: %s\n" "$*" >&2; exit 1; }
# Uninstalling is reachable two ways because install.sh is normally piped into
# bash, where an argument has to be handed across the pipe explicitly:
#   curl -fsSL https://terrydavisthe2nd.github.io/install.sh | bash -s -- --uninstall
#   curl -fsSL https://terrydavisthe2nd.github.io/install.sh | NEXA_UNINSTALL=1 bash
UNINSTALL="${NEXA_UNINSTALL:-}"
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      --uninstall) UNINSTALL=1 ;;
      *) die "unknown option: $arg" ;;
    esac
  done
fi
step "Checking your Mac"
[ "$(uname -s)" = "Darwin" ] || die "Nexa is macOS only."
arch="$(uname -m)"
if [ "$arch" = "arm64" ]; then
  if ! /usr/bin/pgrep -q oahd && ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    warn "Roblox here is x86_64 and needs Rosetta 2 on Apple Silicon."
    info "Install it with:  softwareupdate --install-rosetta --agree-to-license"
    die "Rosetta 2 is required. Install it and re-run."
  fi
  info "Apple Silicon detected — the x86_64 client runs under Rosetta 2."
fi
for tool in curl unzip ditto plutil codesign xattr osascript sw_vers; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
[ -x /usr/libexec/PlistBuddy ] || die "missing /usr/libexec/PlistBuddy"
ok "macOS $(sw_vers -productVersion), $arch"
# Close Roblox before touching it - crash handler FIRST. Killing only the player
# lets RobloxCrashHandler respawn it (on the dylib we are about to replace) while
# we patch, and a player left on the old dylib no longer matches this release's
# rotated socket key - the "no acknowledgement after an update" bug. Same-user
# pkill needs no privileges, so it runs before the admin step.
pkill -9 -x RobloxCrashHandler 2>/dev/null || true
pkill -9 -f RobloxMenuBar 2>/dev/null || true
pkill -9 -x RobloxPlayer 2>/dev/null || true
jf() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
j()  { jf "$WORK/update.json" "$1"; }
verify_md5() {
  local file="$1" expected="$2" label="$3" got
  if [ -z "$expected" ]; then warn "no md5 published for $label; skipping integrity check"; return 0; fi
  got="$(/sbin/md5 -q "$file" 2>/dev/null || md5 -q "$file")"
  [ "$got" = "$expected" ] || die "$label failed md5 check (got $got, expected $expected)"
  ok "$label verified ($expected)"
}
download() {
  local url="$1" dest="$2" label="$3"
  info "downloading $label"
  curl -fsSL --retry 2 "$url" -o "$dest" || die "could not download $label from $url"
}
plist_version() {
  [ -f "$1" ] && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1" 2>/dev/null || true
}
# --uninstall puts the Mac back the way it was: Nexa gone, and the CURRENT Roblox
# in its place - signed by Roblox, unpatched, with its own RobloxPlayerInstaller.app
# still inside it, so the client goes back to updating itself. It deliberately
# never reads update.json: uninstalling has to keep working after the site does not.
do_uninstall() {
  step "Uninstalling Nexa"
  # The GUI's updater polls update.json every 30 s and re-runs install.sh the
  # moment it notices RobloxPlayer is unpatched - which is exactly the state this
  # is about to leave it in. It has to go first, or it reinstalls behind our back.
  pkill -9 -x Nexa 2>/dev/null || true
  pkill -9 -x NexaGUI 2>/dev/null || true
  # setup.rbxcdn.com/mac/version is NOT the current Mac client - that endpoint
  # still answers with a build from 2023. clientsettings is what Roblox's own
  # bootstrapper asks, and clientVersionUpload is the name the zip is filed under.
  step "Finding the current Roblox"
  local cv="$WORK/clientversion.json" host got=0
  for host in clientsettingscdn.roblox.com clientsettings.roblox.com; do
    if curl -fsSL --retry 2 --max-time 30 "https://$host/v2/client-version/MacPlayer" -o "$cv" 2>/dev/null \
       && plutil -convert xml1 -o /dev/null "$cv" 2>/dev/null; then
      got=1; break
    fi
  done
  [ "$got" = 1 ] || die "could not reach Roblox to find the current Mac client version"
  local upload player url stock staged_ver
  upload="$(jf "$cv" clientVersionUpload)"
  player="$(jf "$cv" version)"
  [ -n "$upload" ] || die "Roblox did not report a current Mac client version"
  url="https://setup.rbxcdn.com/mac/$upload-RobloxPlayer.zip"
  ok "current Roblox is ${player:-$upload}"
  # Downloaded and checked BEFORE anything is deleted: a download that fails here
  # must not leave the user with neither Nexa nor Roblox.
  echo "Downloading Roblox..."
  download "$url" "$WORK/roblox-stock.zip" "Roblox ${player:-$upload} (~140 MB)"
  mkdir -p "$WORK/roblox-stock"
  ditto -x -k "$WORK/roblox-stock.zip" "$WORK/roblox-stock" 2>/dev/null \
    || unzip -q "$WORK/roblox-stock.zip" -d "$WORK/roblox-stock"
  stock="$WORK/roblox-stock/RobloxPlayer.app"
  [ -d "$stock" ] || stock="$(/usr/bin/find "$WORK/roblox-stock" -maxdepth 1 -name '*.app' -type d | head -1)"
  [ -d "$stock" ] || die "the Roblox download did not contain an app bundle"
  staged_ver="$(plist_version "$stock/Contents/Info.plist")"
  if [ -n "$player" ] && [ "$staged_ver" != "$player" ]; then
    die "downloaded Roblox is $staged_ver, expected $player"
  fi
  # There is no published checksum for "whatever is current", so integrity rests
  # on TLS plus Roblox's own signature, verified on the installed copy below.
  [ -d "$stock/$INSTALLER_APP" ] || warn "this build has no $INSTALLER_APP; Roblox may not self-update"
  ok "staged stock Roblox $staged_ver"
  # Asked before the password prompt so both prompts arrive together, and asked
  # through osascript because install.sh normally arrives on a pipe: stdin is the
  # script itself, so `read` has nothing to read from. Cancelling or closing the
  # dialog makes osascript exit non-zero, which keeps the folder.
  local purge=0
  if [ -d "$SCRIPTS" ]; then
    if [ -n "${NEXA_ASSUME_PURGE:-}" ]; then
      purge=1
    elif [ -n "${NEXA_ASSUME_KEEP:-}" ]; then
      purge=0
    elif /usr/bin/osascript \
           -e 'display dialog "do you want to delete the Nexa folder in Documents? This contains your autoexec, and workspace folder." with title "Uninstall Nexa" buttons {"Keep", "Delete"} default button "Keep" with icon caution' \
           -e 'button returned of result' 2>/dev/null | grep -q '^Delete$'; then
      purge=1
    fi
  fi
  local owner priv
  owner="$(id -un):$(id -gn)"
  priv="$WORK/uninstall-privileged.sh"
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo "rm -rf \"$NEXA_APP\""
    echo "rm -rf \"$ROBLOX_APP\""
    # ditto, not cp: this bundle keeps Roblox's own signature, and ditto is the
    # copy that preserves every attribute the _CodeSignature seal covers.
    echo "ditto \"$stock\" \"$ROBLOX_APP\""
    # Everything install.sh does to Roblox is absent here on purpose - no
    # RobloxPlayerInstaller.app deletion, no --remove-signature, no machopatch,
    # no ad-hoc re-sign. The chown is not optional though: the updater runs as
    # the user and cannot write into a root-owned bundle.
    echo "chown -R '$owner' \"$ROBLOX_APP\""
  } > "$priv"
  chmod +x "$priv"
  echo "Reinstalling Roblox..."
  if [ -n "${NEXA_NO_ADMIN:-}" ]; then
    /bin/bash "$priv" >/dev/null 2>&1 || die "uninstall failed"
  else
    /usr/bin/osascript -e "do shell script \"/bin/bash '$priv'\" with administrator privileges with prompt \"Nexa needs permission to remove itself and reinstall Roblox.\"" >/dev/null 2>&1 \
      || die "uninstall was cancelled or failed at the password prompt"
  fi
  # Everything below is the user's own Library, so none of it needs the admin step.
  step "Removing Nexa's files"
  rm -rf "$SUPPORT" "$SUPPORT_GUI" 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist" 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID" \
         "$HOME/Library/WebKit/$BUNDLE_ID" \
         "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
         "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
         "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" 2>/dev/null || true
  # The only two leftovers that are per-user rather than per-$HOME: cfprefsd owns
  # the preferences domain and writes the plist back out of its cache unless the
  # domain is deleted through it, and the sockets sit at fixed /tmp paths. Both
  # would reach straight past a NEXA_APPLICATIONS sandbox into the real session,
  # so they only run when this is genuinely the system install.
  if [ "$APPLICATIONS" = "/Applications" ]; then
    /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f /tmp/nexa_executor.sock /tmp/nexa_executor.log /tmp/nexa_console.sock 2>/dev/null || true
  fi
  if [ "$purge" = 1 ]; then
    rm -rf "$SCRIPTS" 2>/dev/null || true
    ok "removed $SCRIPTS"
  elif [ -d "$SCRIPTS" ]; then
    info "kept your scripts in $SCRIPTS"
  fi
  step "Verifying"
  local final_rbx
  if [ -e "$NEXA_APP" ]; then die "could not remove $NEXA_APP"; fi
  if [ ! -d "$ROBLOX_APP" ]; then die "Roblox did not reinstall"; fi
  final_rbx="$(plist_version "$ROBLOX_PLIST")"
  if [ -n "$player" ] && [ "$final_rbx" != "$player" ]; then
    warn "Roblox reports $final_rbx, expected $player"
  fi
  if [ ! -d "$ROBLOX_APP/$INSTALLER_APP" ]; then
    warn "Roblox's own updater is missing from the bundle"
  fi
  # The check that actually proves the executor is out of the client: the patch
  # is a load command naming the dylib, so the name is in the binary or it is not.
  if grep -aq "libNexa.dylib" "$ROBLOX_BIN" 2>/dev/null; then
    die "the reinstalled RobloxPlayer still loads libNexa.dylib"
  fi
  codesign --verify --no-strict "$ROBLOX_APP" 2>/dev/null \
    || warn "Roblox's code signature did not verify after the copy"
  ok "Roblox $final_rbx reinstalled, updater intact"
  echo "Done! Nexa is removed and Roblox ${final_rbx:-} is back to stock - it updates itself again now."
}
if [ -n "$UNINSTALL" ]; then
  do_uninstall
  exit 0
fi
step "Fetching release info"
curl -fsSL --retry 2 "$UPDATE_URL" -o "$WORK/update.json" \
  || die "could not fetch $UPDATE_URL"
  plutil -convert xml1 -o /dev/null "$WORK/update.json" 2>/dev/null || die "update.json is not valid JSON"
RBX_VER="$(j roblox.version)"
RBX_PLAYER="$(j roblox.player)"
RBX_URL="$(j roblox.url)"
RBX_MD5="$(j roblox.md5)"
RBX_ARCHIVE_APP="$(j roblox.archive_app)"; RBX_ARCHIVE_APP="${RBX_ARCHIVE_APP:-RobloxPlayer.app}"
RBX_INSTALLER_APP="$(j roblox.installer_app)"; RBX_INSTALLER_APP="${RBX_INSTALLER_APP:-$INSTALLER_APP}"
EXE_VER="$(j executor.version)"
EXE_URL="$(j executor.app.url)"
EXE_MD5="$(j executor.app.md5)"
[ -n "$RBX_URL" ] && [ -n "$RBX_PLAYER" ] || die "update.json is missing roblox fields"
ok "executor ${EXE_VER:-?}, roblox pin $RBX_PLAYER ($RBX_VER)"
NEED_EXE=1; NEED_RBX=1
installed_exe="$(plist_version "$NEXA_APP/Contents/Info.plist")"
installed_rbx="$(plist_version "$ROBLOX_PLIST")"
if [ -n "$EXE_VER" ] && [ "$installed_exe" = "$EXE_VER" ] && [ -x "$NEXA_PATCHER" ]; then
  NEED_EXE=0
fi
rbx_patched=0
if [ -x "$NEXA_PATCHER" ] && [ -f "$ROBLOX_BIN" ]; then
  if "$NEXA_PATCHER" --status --binary "$ROBLOX_BIN" 2>/dev/null | grep -q "libNexa.dylib"; then
    rbx_patched=1
  fi
fi
if [ "$installed_rbx" = "$RBX_PLAYER" ] && [ "$rbx_patched" = 1 ]; then
  NEED_RBX=0
fi
# NEXA_FORCE=1 reinstalls Nexa and re-patches Roblox even when everything is
# already current - re-running the installer then always refreshes the executor
# (re-copies Nexa.app from the latest package and re-applies the RobloxPlayer
# patch), instead of detecting "up to date" and just opening the app. Roblox is
# only re-downloaded when its pin actually changed; NEXA_FORCE_ROBLOX=1 forces
# that heavier ~140 MB re-download too.
#   curl -fsSL https://terrydavisthe2nd.github.io/install.sh | NEXA_FORCE=1 bash
if [ -n "${NEXA_FORCE:-}" ]; then
  NEED_EXE=1
  [ -z "${NEXA_FORCE_ROBLOX:-}" ] || NEED_RBX=1
fi
if [ "$NEED_EXE" = 0 ] && [ "$NEED_RBX" = 0 ]; then
  [ -n "${NEXA_NO_LAUNCH:-}" ] || open "$NEXA_APP" 2>/dev/null || true
  echo "Done! open roblox and enjoy :) Join the discord server at https://discord.gg/GhaRabCynY"
  exit 0
fi
STAGED_NEXA=""; STAGED_RBX=""
if [ "$NEED_EXE" = 1 ]; then
  step "Preparing Nexa $EXE_VER"
  if [ -z "$EXE_URL" ]; then
    if [ -x "$NEXA_PATCHER" ]; then
      warn "no executor package published yet; keeping the installed Nexa"
      NEED_EXE=0
    else
      die "no executor package published yet (executor.app.url is empty) and none installed"
    fi
  else
    download "$EXE_URL" "$WORK/nexa.zip" "Nexa $EXE_VER"
    verify_md5 "$WORK/nexa.zip" "$EXE_MD5" "Nexa package"
    mkdir -p "$WORK/nexa"
    ditto -x -k "$WORK/nexa.zip" "$WORK/nexa" 2>/dev/null || unzip -q "$WORK/nexa.zip" -d "$WORK/nexa"
    STAGED_NEXA="$(/usr/bin/find "$WORK/nexa" -maxdepth 2 -name 'Nexa.app' -type d | head -1)"
    [ -n "$STAGED_NEXA" ] || die "the Nexa package did not contain Nexa.app"
    [ -x "$STAGED_NEXA/Contents/Resources/nexa-machopatch" ] || die "the Nexa package is missing its patcher"
    [ -f "$STAGED_NEXA/Contents/Resources/libNexa.dylib" ] || die "the Nexa package is missing its dylib"
    ok "staged $(basename "$STAGED_NEXA")"
  fi
fi
if [ "$NEED_RBX" = 1 ]; then
  step "Preparing Roblox $RBX_PLAYER"
  if [ -n "$installed_rbx" ] && [ "$installed_rbx" != "$RBX_PLAYER" ]; then
    info "installed Roblox is $installed_rbx — pinning down/upto $RBX_PLAYER"
  fi
  echo "Downloading Roblox..."
  download "$RBX_URL" "$WORK/roblox.zip" "Roblox $RBX_PLAYER (~140 MB)"
  verify_md5 "$WORK/roblox.zip" "$RBX_MD5" "Roblox package"
  mkdir -p "$WORK/roblox"
  ditto -x -k "$WORK/roblox.zip" "$WORK/roblox" 2>/dev/null || unzip -q "$WORK/roblox.zip" -d "$WORK/roblox"
  STAGED_RBX="$WORK/roblox/$RBX_ARCHIVE_APP"
  [ -d "$STAGED_RBX" ] || STAGED_RBX="$(/usr/bin/find "$WORK/roblox" -maxdepth 1 -name '*.app' -type d | head -1)"
  [ -d "$STAGED_RBX" ] || die "the Roblox package did not contain an app bundle"
  staged_ver="$(plist_version "$STAGED_RBX/Contents/Info.plist")"
  [ "$staged_ver" = "$RBX_PLAYER" ] || die "downloaded Roblox is $staged_ver, expected $RBX_PLAYER"
  ok "staged Roblox $staged_ver"
fi
PATCHER_SRC=""
if [ -n "$STAGED_NEXA" ]; then PATCHER_SRC="$NEXA_PATCHER"; elif [ -x "$NEXA_PATCHER" ]; then PATCHER_SRC="$NEXA_PATCHER"; fi
REAL_OWNER="$(id -un):$(id -gn)"
PRIV="$WORK/privileged.sh"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  if [ -n "$STAGED_NEXA" ]; then
    echo "rm -rf \"$NEXA_APP\""
    echo "/bin/cp -R \"$STAGED_NEXA\" \"$NEXA_APP\""
    echo "xattr -dr com.apple.quarantine \"$NEXA_APP\" 2>/dev/null || true"
  fi
  if [ -n "$STAGED_RBX" ]; then
    echo "rm -rf \"$ROBLOX_APP\""
    echo "/bin/cp -R \"$STAGED_RBX\" \"$ROBLOX_APP\""
  fi
  echo "rm -rf \"$ROBLOX_APP/$RBX_INSTALLER_APP\" 2>/dev/null || true"
  echo "xattr -dr com.apple.quarantine \"$ROBLOX_APP\" 2>/dev/null || true"
  echo "codesign --remove-signature \"$ROBLOX_BIN\" 2>/dev/null || true"
  echo "\"$NEXA_PATCHER\" --binary \"$ROBLOX_BIN\" --dylib \"$NEXA_DYLIB\" --quiet"
  # Ad-hoc re-sign the patched binary so it has a STABLE code identity. Stripping
  # the signature to patch leaves it "not signed at all", so macOS cannot remember
  # an "Always Allow" for Roblox's keychain item and re-prompts every launch. The
  # patcher's .unix-backup (a full copy of the binary) has to be moved out of
  # Contents/MacOS/ first: codesign treats a sibling Mach-O as unsigned nested code
  # and refuses to sign otherwise. install reinstalls a fresh Roblox each time, so
  # the backup is disposable here - drop it, which also saves ~120 MB in the app.
  echo "rm -f \"$ROBLOX_BIN.unix-backup\""
  echo "codesign -f -s - \"$ROBLOX_BIN\" 2>/dev/null || true"
  echo "chown -R '$REAL_OWNER' \"$NEXA_APP\" \"$ROBLOX_APP\" 2>/dev/null || true"
} > "$PRIV"
chmod +x "$PRIV"
if [ -n "$STAGED_NEXA" ]; then echo "Installing Nexa.."; fi
echo "Patching Roblox..."
if [ -n "${NEXA_NO_ADMIN:-}" ]; then
  /bin/bash "$PRIV" >/dev/null 2>&1 || die "installation failed"
else
  /usr/bin/osascript -e "do shell script \"/bin/bash '$PRIV'\" with administrator privileges with prompt \"Nexa needs permission to install Roblox and the executor.\"" >/dev/null 2>&1 \
    || die "installation was cancelled or failed at the password prompt"
fi
step "Verifying"
[ -x "$NEXA_PATCHER" ] || die "Nexa.app did not install"
"$NEXA_PATCHER" --status --binary "$ROBLOX_BIN" 2>/dev/null | grep -q "libNexa.dylib" \
  || die "RobloxPlayer did not end up patched"
final_rbx="$(plist_version "$ROBLOX_PLIST")"
[ "$final_rbx" = "$RBX_PLAYER" ] || warn "Roblox reports $final_rbx, expected $RBX_PLAYER"
mkdir -p "$SUPPORT" 2>/dev/null || true
printf '%s\n' "$RBX_PLAYER" > "$SUPPORT/roblox-pin.txt" 2>/dev/null || true
ok "Roblox $final_rbx pinned and patched"
ok "Nexa $(plist_version "$NEXA_APP/Contents/Info.plist") installed"
if [ -z "${NEXA_NO_LAUNCH:-}" ]; then
  open "$NEXA_APP" 2>/dev/null || true
fi
echo "Done! open roblox and enjoy :) Join the discord server at https://discord.gg/GhaRabCynY"
