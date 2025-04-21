#!/bin/bash
set -eo pipefail

# Configuration
APISERVER=https://kubernetes.default.svc
SERVICEACCOUNT=/var/run/secrets/kubernetes.io/serviceaccount
NAMESPACE=${WATCH_NAMESPACE:-default}
TOKEN=$(cat ${SERVICEACCOUNT}/token)
CACERT=${SERVICEACCOUNT}/ca.crt
AUTH_HEADER="Authorization: Bearer ${TOKEN}"
CURL_TIMEOUT=10

# Logging function
log() {
  local level=$1
  shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

# Signal handling
cleanup() {
  log "INFO" "Shutting down config watcher controller..."
  # Kill any remaining background processes
  jobs -p | xargs -r kill > /dev/null 2>&1
  exit 0
}

trap cleanup SIGTERM SIGINT

delete_pods_with_selector() {
  local selector=${1}

  log "INFO" "Deleting pods with selector: $selector"

  local pods=$(curl --cacert ${CACERT} --header "${AUTH_HEADER}" \
               --connect-timeout ${CURL_TIMEOUT} -s \
               "${APISERVER}/api/v1/namespaces/${NAMESPACE}/pods?labelSelector=$selector" | \
               jq -r '.items[].metadata.name')
  
  if [[ -z "$pods" ]]; then
    log "WARN" "No pods found matching selector: $selector"
    return
  fi

  for pod in $pods; do
    log "INFO" "Deleting pod: $pod"
    exit_code=$(curl --cacert ${CACERT} --header "${AUTH_HEADER}" \
                --connect-timeout ${CURL_TIMEOUT} -s -X DELETE -o /dev/null -w "%{http_code}" \
                "${APISERVER}/api/v1/namespaces/${NAMESPACE}/pods/$pod")
    
    if [[ $exit_code -eq 200 ]]; then
      log "INFO" "Successfully deleted pod: $pod"
    else
      log "ERROR" "Failed to delete pod $pod: HTTP $exit_code"
    fi
  done
}

start_event_loop() {
  log "INFO" "Starting config watcher controller in namespace: ${NAMESPACE}"
  
  # Single curl process to watch for events
  curl --cacert ${CACERT} --header "${AUTH_HEADER}" -N -s \
       --connect-timeout ${CURL_TIMEOUT} \
       "${APISERVER}/api/v1/namespaces/${NAMESPACE}/configmaps?watch=true" | \
  while read -r event; do
    # Process event in a cleaner way
    event=$(echo "$event" | tr '\r\n' ' ')
    
    # Parse event details with a single jq call
    event_data=$(echo "$event" | jq -r '{
      type: .type,
      name: .object.metadata.name,
      selector: (.object.metadata.annotations | 
                if . then 
                  .["k8s.nexon.com/pod-delete-selector"] // "" 
                else 
                  "" 
                end)
    }')
    
    type=$(echo "$event_data" | jq -r '.type')
    config_map=$(echo "$event_data" | jq -r '.name')
    pod_selector=$(echo "$event_data" | jq -r '.selector')
    
    log "INFO" "Event: $type -- ConfigMap: $config_map -- Selector: ${pod_selector:-none}"

    if [[ "$type" == "MODIFIED" && -n "$pod_selector" ]]; then
      delete_pods_with_selector "$pod_selector"
    fi
  done
  
  # If we get here, the curl command failed
  log "ERROR" "Event stream ended unexpectedly, restarting in 5 seconds..."
  sleep 5
  start_event_loop
}

# Main
start_event_loop
