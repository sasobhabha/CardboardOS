# CardboardOS - system-wide stereoscopic display + single-button navigation.
#
# Builds a SpringBoard tweak. Requires Theos.
#
# iOS 12 note: A12+ devices run arm64e, but arm64e binaries for iOS 12-13.7 must
# be produced with the Xcode 11.7 toolchain (see theos.dev/docs/arm64e-deployment).
# A slice built for the wrong arm64e ABI does not load at all, and a dylib that
# does not load is indistinguishable from a tweak that was never installed, so
# this builds arm64 only by default: arm64 code runs fine inside an arm64e
# SpringBoard. Build universal with `make ARCHS="arm64 arm64e"` if you have a
# toolchain that emits the iOS 12 arm64e ABI.

# --- Locate Theos -----------------------------------------------------------
# THEOS normally comes from your shell rc file. A shell that never sourced it
# (new terminal, sudo, CI, some IDE terminals) leaves it empty, which used to
# surface as "/makefiles/common.mk: No such file". Fall back to the standard
# install locations instead.
ifeq ($(strip $(THEOS)),)
  ifneq ($(wildcard $(HOME)/theos/makefiles/common.mk),)
    export THEOS = $(HOME)/theos
  else ifneq ($(wildcard /opt/theos/makefiles/common.mk),)
    export THEOS = /opt/theos
  else ifneq ($(wildcard $(HOME)/.theos/makefiles/common.mk),)
    export THEOS = $(HOME)/.theos
  else ifneq ($(wildcard /usr/local/theos/makefiles/common.mk),)
    export THEOS = /usr/local/theos
  endif
endif

ifeq ($(strip $(THEOS)),)
  $(error Theos not found - install Theos or run make THEOS=/path/to/theos)
endif

ifeq ($(wildcard $(THEOS)/makefiles/common.mk),)
  $(error THEOS is set to $(THEOS) but that folder has no makefiles/common.mk - point THEOS at the Theos install root)
endif

TARGET ?= iphone:clang:latest:12.0
export TARGET

ARCHS ?= arm64

INSTALL_TARGET_PROCESSES = SpringBoard backboardd

include $(THEOS)/makefiles/common.mk

# Two dylibs, one package: the SpringBoard half draws the stereo view and knows
# where the reticle is, the backboardd half turns that reticle into a touch.
# They have to be separate binaries because they must not link the same
# frameworks - the backboardd one is Foundation-only so it can live in a daemon
# without dragging UIKit and Metal in with it.
TWEAK_NAME = CardboardOS CBBHIDDriver CBBTouchRelay

CardboardOS_FILES = Tweak.x \
	CBBController.m \
	CBBDisplayCapture.m \
	CBBStereoRenderer.m \
	CBBStereoHUD.m \
	CBBTouchInjector.m \
	CBBClickRecognizer.m \
	CBBMotionPointer.m \
	CBBHomeLandscape.m \
	CBBPrefs.m

CardboardOS_CFLAGS = -fobjc-arc -I.
CardboardOS_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics CoreVideo CoreMotion Metal MetalKit IOSurface
CardboardOS_PRIVATE_FRAMEWORKS = IOKit
# -dead_strip_dylibs drops libsubstrate.dylib from the load commands, because
# nothing in this tweak calls into it (see the note by CBB_INJECT_DIR). A dylib
# that asks dyld for a library the loader does not ship fails to load with no
# visible error, which is the classic "the tweak does nothing" on a framework
# other than the one it was built against. This keeps the binary dependent on
# system frameworks only.
CardboardOS_LDFLAGS = -framework IOKit -Wl,-dead_strip_dylibs

# Injection lives in backboardd, which is the process that owns the display and
# the touch pipeline. Runs on its own thread there and talks to SpringBoard over
# a CFMessagePort; see CBBHIDDriver.m for why SpringBoard cannot do it itself.
CBBHIDDriver_FILES = CBBHIDDriver.m
CBBHIDDriver_CFLAGS = -fobjc-arc -I.
CBBHIDDriver_FRAMEWORKS = Foundation
CBBHIDDriver_LDFLAGS = -Wl,-dead_strip_dylibs

# Loaded into every app (filter on UIApplication). A touch delivered to an app
# has to name that app's own window context, and only the app's process can: the
# backboardd half proved that an event dispatched into the HID system reaches no
# client at all on this build. UIKit + Foundation only, and it does nothing at
# all in a process that is not an app.
CBBTouchRelay_FILES = CBBTouchRelay.m
CBBTouchRelay_CFLAGS = -fobjc-arc -I.
CBBTouchRelay_FRAMEWORKS = UIKit Foundation
CBBTouchRelay_PRIVATE_FRAMEWORKS = IOKit
CBBTouchRelay_LDFLAGS = -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk

# Deploy exactly one package: this build's. packages/ is wiped first, because a
# stale deb left in the directory was once installed instead of the fresh build
# (`ls -t | head -1` picked 1.0.0 sitting next to the new 1.1.0), and then the
# device runs code several rounds behind the working tree. The tag gate below
# exists for the same reason one level deeper: the deb name says when it was
# packed, not what source went into it, so the payload is searched for the
# build tag before anything is copied to the phone.
CBB_IP = 100.88.174.24
CBB_SSH_PASSWORD ?= alpine
CBB_SSH_OPTS = -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o NumberOfPasswordPrompts=1

# The tweak only uses a single %ctor: there is no Logos %hook in it and no
# MSHook* call, so it does not link against libsubstrate at all. That makes it
# loader-agnostic, which matters here: Sonar does not have to provide the
# mobilesubstrate virtual package for this dylib to work, and requiring it in
# Depends only stops dpkg from installing the package.
#
# Where the tweak ends up is not something to assume. Substrate, Substitute and
# libhooker read /Library/MobileSubstrate/DynamicLibraries; Substitute-style and
# Sonar-style loaders read /usr/lib/TweakInject. On this device the deb installed
# into the second one while the first stayed empty, and on a later build into
# neither, so deploy-ondevice.sh finds the binary on disk (dpkg -L first, then a
# filesystem search) and copies it into both directories as real files.
CBB_ONDEVICE = deploy-ondevice.sh

deploy::
	@find packages -maxdepth 1 -name '*.deb' -delete
	@$(MAKE) --no-print-directory package
	@latest=$$(ls -t packages/*.deb | head -1); \
	if [ -z "$$latest" ]; then echo "no package built"; exit 1; fi; \
	tmp=$$(mktemp -d); dpkg-deb -x "$$latest" "$$tmp" >/dev/null || { echo "cannot unpack $$latest"; rm -rf "$$tmp"; exit 1; }; \
	tag=$$(grep -a -r -o '2026-[0-9-]*[a-z]' "$$tmp" 2>/dev/null | head -1); \
	rm -rf "$$tmp"; \
	if [ -z "$$tag" ]; then echo "BUILD STALE: $$latest has no build tag - the compile did not pick up the working tree. Run 'make clean package' and retry."; exit 1; fi; \
	echo "Installing $$latest (tag $$tag)"; \
	sshpass -p '$(CBB_SSH_PASSWORD)' scp -O $(CBB_SSH_OPTS) "$$latest" root@$(CBB_IP):/var/root/cbb_new.deb && \
	sshpass -p '$(CBB_SSH_PASSWORD)' scp -O $(CBB_SSH_OPTS) $(CBB_ONDEVICE) root@$(CBB_IP):/var/root/cbb_ondevice.sh && \
	sshpass -p '$(CBB_SSH_PASSWORD)' ssh $(CBB_SSH_OPTS) root@$(CBB_IP) \
		"dpkg -i /var/root/cbb_new.deb && echo 'INSTALL OK' || echo 'INSTALL FAILED - dpkg refused the package, the reason is above this line'; sh /var/root/cbb_ondevice.sh; rm -f /var/root/cbb_new.deb /var/root/cbb_ondevice.sh"

# Prints the same checks without installing anything. Use it after a deploy that
# said INSTALL OK but changed nothing on screen, to see whether the loader is
# looking where the package put the dylib.
doctor:
	@sshpass -p '$(CBB_SSH_PASSWORD)' scp -O $(CBB_SSH_OPTS) $(CBB_ONDEVICE) root@$(CBB_IP):/var/root/cbb_check.sh
	@sshpass -p '$(CBB_SSH_PASSWORD)' ssh $(CBB_SSH_OPTS) root@$(CBB_IP) "sh /var/root/cbb_check.sh --no-respring; echo '--- system'; uname -a; sw_vers 2>/dev/null; rm -f /var/root/cbb_check.sh; echo '--- done'"
