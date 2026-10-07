#!/bin/bash

THRESHOLD=224084

while true; do
    # Get available or free memory in MB (using available / column 7, or free / column 4)
    FREE_MEM=$(free -m | awk '/^Mem:/ {print $4}')
    
    # Use standard bash arithmetic evaluation
    if (( FREE_MEM < THRESHOLD )); then
        echo "$(date): Free memory (${FREE_MEM}MB) is below threshold (${THRESHOLD}MB). Dropping caches..."
        sync
        echo 3 > /proc/sys/vm/drop_caches
        echo "$(date): Cache dropped successfully."
    else
        echo "$(date): Memory normal. Free: ${FREE_MEM}MB (Threshold: ${THRESHOLD}MB)"
    fi
    
    sleep 10
done
