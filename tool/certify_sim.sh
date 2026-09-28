#!/usr/bin/env bash
# Run the whole certification in AERA's bridge on this PC, with the
# interactive checks scripted, and print the results. The report JSON lands
# in build/xdg/aera-flutter/downloads/aera-cert-latest.json.
#
#   tool/certify_sim.sh            quick run (about a minute)
#   AERA_CERT_QUICK=0 tool/certify_sim.sh   full-length scenes
#
# Frame times here come from Mesa's CPU renderer and say nothing about the
# phone; the functional checks and the leak check are what the simulator
# certifies.
set -euo pipefail
cd "$(dirname "$0")/.."
export AERA_CERT_QUICK=${AERA_CERT_QUICK:-1} AERA_CERT_EXIT=1 XDG_DATA_HOME=$PWD/build/xdg
export GALLIUM_DRIVER=${GALLIUM_DRIVER:-llvmpipe}
tool/aera.sh sim --until 300000 --timeout 300 \
    --tap 180,370@1500 --tap 180,370@2500 --tap 180,370@3500 \
    --key a@5000 --key e@5200 --key r@5400 --key a@5600 --key enter@6000 \
    --back 8000 2>&1 | grep 'aera-cert'
