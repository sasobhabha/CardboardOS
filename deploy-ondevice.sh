#!/bin/sh
#
# Runs on the device after the deb has been installed (or on its own for
# `make doctor`). It exists because shell quoting across `make` -> ssh -> sh
# cannot express "find the dylib wherever Theos put it, then copy it to every
# directory a loader might read", and the failure mode of getting that wrong is
# an installed package that injects nothing.
#
# The package now carries three dylibs - CardboardOS (SpringBoard), CBBHIDDriver
# (backboardd) and CBBTouchRelay (every app) - and a loader installs a dylib only
# when its filter plist sits next to it under the same name, so all of them are
# handled per name here. A missing relay plist is the failure that looks like
# "in-app taps still do nothing", so the script copies both files every time.
#
# Usage: sh cbb_check.sh [--no-respring]
#
set -u

RESPRING=1
if [ "${1:-}" = "--no-respring" ]; then
    RESPRING=0
fi

PACKAGE=com.buffy.cardboardos
NAMES="CardboardOS CBBHIDDriver CBBTouchRelay"
DYN=/Library/MobileSubstrate/DynamicLibraries
TINJ=/usr/lib/TweakInject
STAGES=/var/mobile/Library/Preferences/com.buffy.cardboardos.stages

say() {
    echo "--- $*"
}

say package
dpkg -l | grep -i cardboard || echo "  $PACKAGE not installed"

say "dpkg payload"
PAYLOAD=$(dpkg -L "$PACKAGE" 2>/dev/null | grep -i -E 'dylib|plist')
if [ -n "$PAYLOAD" ]; then
    echo "$PAYLOAD"
else
    echo "  dpkg knows no dylib/plist for $PACKAGE"
fi

# Where is a given binary really? Ask the package first, then the filesystem. The
# deb built on this machine has installed itself into /usr/lib/TweakInject, then
# into neither directory, so nothing may be assumed.
install_one() {
    NAME=$1
    say "locate $NAME.dylib"
    FOUND=""
    for CANDIDATE in $PAYLOAD; do
        case "$CANDIDATE" in
            */"$NAME.dylib") FOUND="$CANDIDATE" ;;
        esac
    done
    if [ -z "$FOUND" ]; then
        for ROOT in /Library /usr/lib /usr/local/lib /var/jb /usr/share; do
            [ -d "$ROOT" ] || continue
            HIT=$(find "$ROOT" -name "$NAME.dylib" 2>/dev/null | head -1)
            if [ -n "$HIT" ]; then
                FOUND="$HIT"
                break
            fi
        done
    fi
    echo "  ${FOUND:-none}"

    if [ -z "$FOUND" ] || [ ! -f "$FOUND" ]; then
        echo "  NO $NAME.dylib FOUND - the package did not put a binary on disk."
        echo "  Check the dpkg output above for 'INSTALL FAILED' or a file conflict."
        return
    fi

    SRC_DIR=$(dirname "$FOUND")
    # The filter has to sit next to the dylib under the same name.
    SRC_PLIST="$SRC_DIR/$NAME.plist"
    echo "  plist: $SRC_PLIST"

    say "install $NAME into both injection directories"
    for DST in "$DYN" "$TINJ"; do
        mkdir -p "$DST"
        if [ "$DST" -ef "$SRC_DIR" ]; then
            echo "  $DST is the same directory as $SRC_DIR, nothing to copy"
            ls -l "$DST/$NAME.dylib" 2>/dev/null
            continue
        fi
        cp -f "$FOUND" "$DST/$NAME.dylib"
        if [ -f "$SRC_PLIST" ]; then
            cp -f "$SRC_PLIST" "$DST/$NAME.plist"
        else
            echo "  WARNING: no $NAME.plist in $SRC_DIR - the loader will ignore the dylib"
        fi
        ls -l "$DST/$NAME.dylib" 2>/dev/null
        ls -l "$DST/$NAME.plist" 2>/dev/null
    done
}

for NAME in $NAMES; do
    install_one "$NAME"
done

say frameworks
dpkg -l | grep -i -E 'sonar|substitute|substrate|libhooker|ellekit' || echo "  none declared"

# What the loader itself installed. If Sonar keeps a list of directories or a
# database of tweaks, it shows up here and explains why a dylib sitting in the
# conventional directory is ignored.
say "sonar files"
dpkg -L com.staturnz.sonar 2>/dev/null | head -20 || echo "  com.staturnz.sonar not installed under that name"

say "contents of $DYN"
ls -1 "$DYN" 2>/dev/null | head -20 || echo "  missing"

say "contents of $TINJ"
ls -1 "$TINJ" 2>/dev/null | head -20 || echo "  missing"

# The binary on disk is not proof the loader ran it. The build tag is compiled
# into each dylib, so grep it out of the file that is actually on the phone: a
# missing or old tag here means the device is running a stale build no matter
# what the working tree says.
say "build fingerprint of the dylibs on disk"
for NAME in $NAMES; do
    FOUND=""
    for DST in "$TINJ" "$DYN"; do
        if [ -f "$DST/$NAME.dylib" ]; then
            FOUND="$DST/$NAME.dylib"
            break
        fi
    done
    if [ -z "$FOUND" ]; then
        echo "  $NAME: no dylib on disk"
        continue
    fi
    ls -l "$FOUND"
    md5 "$FOUND" 2>/dev/null || echo "  no md5 tool on device"
    TAG=$(grep -a -o '2026-[0-9-]*[a-z][^"]*' "$FOUND" 2>/dev/null | head -1)
    echo "  $NAME tag in binary: ${TAG:-NOT FOUND - this is not the current build}"
done

# Sonar keeps loader logs here. They say outright whether it injected the
# dylib, skipped it, or watched the process die on it.
say "sonar loader logs"
if [ -d /Library/Sonar/Logs ]; then
    ls -lt /Library/Sonar/Logs 2>/dev/null | head -8
    NEWEST=$(ls -t /Library/Sonar/Logs/* 2>/dev/null | head -1)
    if [ -n "$NEWEST" ] && [ -f "$NEWEST" ]; then
        echo "  tail of $NEWEST:"
        tail -30 "$NEWEST" 2>/dev/null
    else
        echo "  log directory is empty"
    fi
else
    echo "  no /Library/Sonar/Logs on this device"
fi

# Breadcrumbs written by the tweak itself. iOS 12 on this device has no syslogd,
# so /var/log/syslog does not exist and NSLog output is lost: this file is the
# only evidence that the dylibs were loaded and how far setup got.
say "stages from the PREVIOUS run (deploy clears them below, then resprings)"
if [ -f "$STAGES" ]; then
    ls -l "$STAGES"
    cat "$STAGES"
else
    echo "  no breadcrumbs: the dylib was never loaded"
fi

say preferences
plutil -p /var/mobile/Library/Preferences/com.buffy.cardboardos.plist 2>/dev/null || echo "  no preferences written"

# A crash report is what ends "something crashed" debates: it names the faulting
# thread and the exact frame. Safe mode keeps these files around, so they are
# readable even when the tweak never loads.
say "newest crash report"
CRDIR=/var/mobile/Library/Logs/CrashReporter
if [ -d "$CRDIR" ]; then
    NEWEST_CRASH=$(ls -t "$CRDIR"/SpringBoard* "$CRDIR"/backboardd* 2>/dev/null | head -1)
    if [ -n "$NEWEST_CRASH" ] && [ -f "$NEWEST_CRASH" ]; then
        echo "  $NEWEST_CRASH"
        grep -a -E 'Exception Type|Exception Codes|Triggered by Thread|Crashed' "$NEWEST_CRASH" 2>/dev/null | head -8
        echo "  --- tail:"
        tail -40 "$NEWEST_CRASH" 2>/dev/null
    else
        echo "  no SpringBoard/backboardd crash files in $CRDIR"
        ls -lt "$CRDIR" 2>/dev/null | head -6
    fi
else
    echo "  no $CRDIR on this device"
fi

say log
grep -i cardboard /var/log/syslog 2>/dev/null | tail -15 || echo "  no syslog file on this device"

if [ "$RESPRING" -eq 1 ]; then
    # Stale preferences are the one failure that looks exactly like "the tweak
    # does not load": an earlier build wrote enabled = NO when a launch failed,
    # and checkBootGuard writes it after two early deaths. That value survives
    # reinstalling, so a fixed build can come up switched off forever. Clear it,
    # and let the defaults (stereo on) apply. `make doctor` does not do this.
    PREFS=/var/mobile/Library/Preferences/com.buffy.cardboardos.plist
    say "resetting preferences so this launch starts from defaults"
    if [ -f "$PREFS" ]; then
        rm -f "$PREFS"
        echo "  removed $PREFS"
        killall -9 cfprefsd 2>/dev/null
    else
        echo "  nothing on disk, defaults already apply"
    fi

    # Clear the breadcrumbs so the next run's stages are the only thing in the
    # file: `make doctor` afterwards shows this respring and nothing older.
    rm -f "$STAGES"
    say respring
    echo "  NOTE: the stages printed above are from BEFORE this respring."
    echo "  Run 'make doctor' after the phone is back to see this build's stages."
    sleep 1
    # Both halves have to be restarted: a plain respring only restarts
    # SpringBoard, and backboardd would keep running the previous driver dylib
    # (or none at all) while the SpringBoard half talks to a port nobody owns.
    # Killing backboardd takes the window server down with it, so SpringBoard
    # comes back as part of the same respring.
    killall -9 SpringBoard 2>/dev/null
    sleep 1
    killall -9 backboardd 2>/dev/null
    echo "  restarted SpringBoard and backboardd"
fi
