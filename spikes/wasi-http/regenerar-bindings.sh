#!/bin/bash
# Regenera Sources/CWasiHttp/{include/probe.h,probe.c} desde wit/ con wit-bindgen.
set -euo pipefail
cd "$(dirname "$0")"
wit-bindgen c --world probe --out-dir Sources/CWasiHttp wit
mv -f Sources/CWasiHttp/probe.h Sources/CWasiHttp/include/probe.h
rm -f Sources/CWasiHttp/probe_component_type.o
