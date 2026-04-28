#!/bin/bash

while true; do
    PHASE=$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "[$(date)] NooBaa phase: ${PHASE:-Unknown}"

    if [ "$PHASE" = "Ready" ]; then
        echo "NooBaa is Ready - exiting loop"
        break
    fi

    sleep 30
done

echo "The MCG standalone instance is ready..."
