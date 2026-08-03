#!/bin/bash

ACTION="$1"

if playerctl -l | grep -qx "spotify"; then
    playerctl -p spotify "$ACTION"
else
    playerctl "$ACTION"
fi
