#!/bin/bash

xsetroot -mod 1 1 -fg black -bg black
xrdb -merge ~/.Xresources

exec i3 -V --shmlog-size 26214400 > i3.log

