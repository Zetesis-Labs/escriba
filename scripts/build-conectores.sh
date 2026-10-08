#!/bin/sh
set -eu
cd "$(dirname "$0")/../packages/conectores"
npm ci --ignore-scripts
npm test
npm run build
npm pack ../../Sources/EscribaJSC/Resources/conectores --pack-destination dist --quiet
