#!/bin/sh

xset b off
setxkbmap -option caps:swapescape
bluetooth off
xwallpaper --daemon --zoom $(find "$HOME/.local/share/wallpapers"  -type f -exec file {} \; | grep "image" | awk -F: '{print $1}' | shuf -n1)

redshift -l 41:29 -t 5700:3600 -g 0.8 -m randr -v &
xautolock -corner -000 -locker slock &
unclutter -grab -root -idle 1 &
picom     &
slstatus  &
sxhkd     &
dunst     &
udiskie   &
exec dwm
