#!/bin/bash

KEYMAP="ku"
DESCRIPTION="Kurdish (Kurmanji)"
SOURCE_FILE="${KEYMAP}"
DEST_DIR="/usr/share/X11/xkb/symbols/"
EVDEV_XML="/usr/share/X11/xkb/rules/evdev.xml"
BASE_XML="/usr/share/X11/xkb/rules/base.xml"

sudo cp $SOURCE_FILE $DEST_DIR

DISTRO=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')

if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    XML_FILE=$EVDEV_XML
elif [[ "$DISTRO" == "fedora" || "$DISTRO" == "centos" ]]; then
    XML_FILE=$BASE_XML
else
    XML_FILE=$EVDEV_XML
fi  

LAYOUT_CHECK="\    <layout>\n      <configItem>\n        <name>$KEYMAP</name>\n        <shortDescription>ku</shortDescription>\n        <description>$DESCRIPTION</description>\n        <languageList>\n          <iso639Id>kur</iso639Id>\n        </languageList>\n      </configItem>\n    </layout>"

if ! grep -Fxq "$LAYOUT_CHECK" "$XML_FILE"; then
    sudo sed -i "/<\/layoutList>/i $LAYOUT_CHECK" "$XML_FILE"
    echo "Layout tevlî XML bû."
else
    echo "Layout jixwe di XML de heye."
fi


if [ "$XDG_SESSION_TYPE" == "wayland" ]; then
    sudo localectl set-x11-keymap $KEYMAP
else
    setxkbmap $KEYMAP
fi

echo "Klavye bi serkeftî hat sazkirin. Distro: $DISTRO"
