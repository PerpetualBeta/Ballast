# Ballast — keep every app's loudness on an even keel.
#
# A macOS equivalent of Windows' Loudness Equalisation: a Core Audio process
# tap intercepts the system mix, an EBU R128 / BS.1770 loudness meter drives a
# slow automatic gain control (rides the level between tracks, no pumping), and
# a look-ahead limiter guards the peak ceiling.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. SPM project, embedded Sparkle, dual-ship
# (.zip + .pkg).

BUNDLE_NAME      := Ballast
BUNDLE_TYPE      := app
PRODUCT_NAME     := Ballast.app
BUNDLE_ID        := cc.jorviksoftware.Ballast
BUILD_SYSTEM     := spm
SPM_PRODUCT      := Ballast

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := Ballast.entitlements

include ../jorvik-release/release.mk
