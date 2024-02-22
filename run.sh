#!/usr/bin/sh

watchexec -r -e hs "sleep $1 && stack run -- $1"
