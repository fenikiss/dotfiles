#!/bin/bash

track=$(playerctl -p spotify metadata --format '{{ artist }} - {{ title }}' 2>/dev/null)

if [ -n "$track" ]; then
    echo "♪ $track"
else
    echo ""
fi
