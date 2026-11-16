#!/usr/bin/env bash
# Boots the test phone with our own commands so its output is kept as evidence
# (the runner action only prints to the job log, which the agent cannot read).
# Usage: boot.sh <image tag, e.g. google_apis or aosp_atd>
set -uo pipefail
TAG=${1:?image tag}
EVIDENCE=${EVIDENCE:?}
BOOT_LIMIT=${BOOT_LIMIT:-360}
SDK=${ANDROID_HOME:?}
BIN="$SDK/cmdline-tools/latest/bin"
IMAGE="system-images;android-34;$TAG;x86_64"
mkdir -p "$EVIDENCE"
t0=$(date +%s)
log() { echo "$(( $(date +%s) - t0 ))s $*" | tee -a "$EVIDENCE/boot.txt"; }

log "host: $(nproc) cpus, $(free -m | awk '/^Mem:/{print $2" MB ram, "$7" MB free"}'), kvm: $(ls -l /dev/kvm 2>&1)"
yes | "$BIN/sdkmanager" --licenses > /dev/null 2>&1
"$BIN/sdkmanager" emulator platform-tools > "$EVIDENCE/sdk-install.txt" 2>&1 || { log "FAIL install emulator"; exit 1; }
"$BIN/sdkmanager" "$IMAGE" >> "$EVIDENCE/sdk-install.txt" 2>&1 || { log "FAIL install $IMAGE"; exit 1; }
log "installed $IMAGE, emulator $("$SDK/emulator/emulator" -version 2>/dev/null | head -1)"
log "accel: $("$SDK/emulator/emulator" -accel-check 2>&1 | tr '\n' ' ' | cut -c1-200)"
echo no | "$BIN/avdmanager" create avd -n test -k "$IMAGE" -d pixel_6 --force > /dev/null 2>&1 || { log "FAIL create avd"; exit 1; }

# PIN_CPUS: keep the emulator on that many CPUs, to stand in for the 2-CPU private-repo runner.
PIN=()
if [ -n "${PIN_CPUS:-}" ]; then PIN=(taskset -c "0-$(( PIN_CPUS - 1 ))"); log "emulator pinned to $PIN_CPUS cpus"; fi
# -verbose and -show-kernel: emulator.log also holds the emulator's own steps and the phone's kernel console,
# which is the only record when the phone never gets far enough for adb.
"${PIN[@]}" "$SDK/emulator/emulator" -avd test -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -no-snapshot -camera-back none \
    -verbose -show-kernel > "$EVIDENCE/emulator.log" 2>&1 &
emu=$!
t1=$(date +%s)
log "emulator started"
mkdir -p "$EVIDENCE/shots"

# Where the phone is in its boot: each stage sets a property once it is done.
stage() {
    timeout 5 adb shell getprop 2>/dev/null | tr -d '\r' |
        grep -E '\[(init.svc.(servicemanager|surfaceflinger|zygote|bootanim)|sys.boot_completed|dev.bootcomplete|sys.sysctl.extra_free_kbytes)\]' |
        sed 's/[][]//g; s/: /=/' | tr '\n' ' '
}

# Every 30 s: boot stage, host load and the busiest host processes, and a screenshot once adb is up.
snapshot() {
    local t=$(( $(date +%s) - t1 ))
    log "adb=$(timeout 5 adb get-state 2>/dev/null || echo none) $(stage) load=$(cut -d' ' -f1-3 /proc/loadavg)"
    { echo "== ${t}s"; top -b -n1 -o %CPU | sed -n '7,12p'; } >> "$EVIDENCE/host.txt"
    timeout 10 adb exec-out screencap -p > "$EVIDENCE/shots/${t}s.png" 2>/dev/null || rm -f "$EVIDENCE/shots/${t}s.png"
}

logcat_started=0
last=0
while [ $(( $(date +%s) - t1 )) -lt "$BOOT_LIMIT" ]; do
    if ! kill -0 "$emu" 2>/dev/null; then
        wait "$emu"; log "FAIL emulator exited (code $?) after $(( $(date +%s) - t1 ))s; see emulator.log"
        exit 1
    fi
    if [ "$logcat_started" = 0 ] && [ "$(timeout 5 adb get-state 2>/dev/null)" = device ]; then
        # The phone keeps its log from the start of boot, so streaming it from here misses nothing.
        adb logcat -v time > "$EVIDENCE/logcat.txt" 2>&1 &
        logcat_started=1
        log "adb up, logcat streaming"
    fi
    if [ $(( $(date +%s) - last )) -ge 30 ]; then snapshot; last=$(date +%s); fi
    if [ "$(timeout 5 adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
        log "BOOTED in $(( $(date +%s) - t1 ))s after emulator start"
        snapshot
        log "webview: $(adb shell pm list packages 2>/dev/null | grep -i webview | tr -d '\r' | tr '\n' ' ')"
        adb shell dumpsys webviewupdate 2>/dev/null | head -20 > "$EVIDENCE/webview.txt"
        exit 0
    fi
    sleep 3
done
log "FAIL boot not completed ${BOOT_LIMIT}s after emulator start"
snapshot
{ echo "== dmesg"; sudo dmesg | tail -n 40; } >> "$EVIDENCE/host.txt"
exit 1
