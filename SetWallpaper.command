#!/bin/bash
# Sets SisyphusImage10.png as the desktop wallpaper on all screens
DIR="$( cd "$(dirname "$0")" && pwd )"
IMAGE="$DIR/SisyphusImage10.png"

osascript <<EOF
tell application "System Events"
    set theDesktops to every desktop
    repeat with aDesktop in theDesktops
        set picture of aDesktop to "$IMAGE"
    end repeat
end tell
EOF

echo "Wallpaper set to SisyphusImage10.png"
