#!/bin/bash

TEMP_DIR="temp"
LIBVPX_DIR="libvpx"
VPX_FRAMEWORK="vpx.framework"

echo "Cloning libvpx"
mkdir $TEMP_DIR
cd $TEMP_DIR
git clone --branch v1.4.0 --depth 1 https://git.chromium.org/webm/libvpx.git $LIBVPX_DIR
cd $LIBVPX_DIR
git apply ../../iosbuild-diff
cd ../..

if [ -d "$VPX_FRAMEWORK" ]; then
    echo "Removing $VPX_FRAMEWORK"
    rm -rf "$VPX_FRAMEWORK"
fi

echo "Building VPX"
$TEMP_DIR/$LIBVPX_DIR/build/make/iosbuild.sh

echo "Moving headers from $VPX_FRAMEWORK/Headers/vpx/ to $VPX_FRAMEWORK/Headers/"
mv $VPX_FRAMEWORK/Headers/vpx/* $VPX_FRAMEWORK/Headers/
rm -rf $VPX_FRAMEWORK/Headers/vpx

echo "Removing $TEMP_DIR directory"
rm -rf $TEMP_DIR

echo "Done"
