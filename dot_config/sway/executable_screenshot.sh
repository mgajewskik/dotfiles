#!/usr/bin/env bash

OUTPUT_DIR="${HOME}/pictures/screenshots"
mkdir -p "$OUTPUT_DIR"

pkill slurp || grim -g "$(slurp -d)" - |
    satty --filename - \
        --output-filename "$OUTPUT_DIR/screenshot-$(date +'%Y-%m-%d_%H-%M-%S').png" \
        --early-exit \
        --actions-on-enter save-to-clipboard \
        --save-after-copy \
        --copy-command wl-copy
