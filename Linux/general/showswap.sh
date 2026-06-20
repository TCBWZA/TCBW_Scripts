#!/bin/bash
echo "PID | COMMAND | SWAP (MB)"
echo "-------------------------"
for pid in /proc/[0-9]*; do
   pid_num=$(basename "$pid")
   comm=$(cat "$pid/comm" 2>/dev/null)
   swap=$(grep VmSwap "$pid/status" 2>/dev/null | awk '{sum += $2} END {print sum/1024}')
   if [[ "$swap" != "0" && -n "$swap" ]]; then
       echo "$pid_num | $comm | $swap"
   fi
done | sort -k3 -nr | head -n 10
