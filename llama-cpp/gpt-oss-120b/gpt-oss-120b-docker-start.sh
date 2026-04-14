#!/bin/bash

#####################################
# Container Name varible
CONTAINER_NAME="llama-cpp-gpt-oss-120b-mxfp4"

if sudo docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "Stopping container: $CONTAINER_NAME"
  sudo docker stop "$CONTAINER_NAME"
fi

if sudo docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "Removing container: $CONTAINER_NAME"
  sudo docker rm "$CONTAINER_NAME"
fi

sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --device /dev/dri \
  -p 8125:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -v /llm-models:/models \
  cr.ringen.cloud:5000/llama.cpp:server-vulkan-8067-ff4affb4c \
  --model /models/gpt-oss-120b-mxfp4/gpt-oss-120b-mxfp4-00001-of-00003.gguf \
  --gpu-layers -1 \
  --parallel 1 \
  --ctx-size 32768 \
  --batch-size 1024 \
  --ubatch-size 256 \
  --cont-batching \
  --flash-attn on \
  --metrics \
  --host :: \
  --port 8080

################################################################
# Verify container startup and health (if a HEALTHCHECK exists)
echo "Verifying container status..."
MAX_ATTEMPTS=24
SLEEP_SECONDS=5

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
  RUNNING_STATE=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
  HEALTH_STATE=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

  if [[ "$RUNNING_STATE" != "true" ]]; then
    echo "Container is not running (attempt $attempt/$MAX_ATTEMPTS)."
  elif [[ "$HEALTH_STATE" == "healthy" || "$HEALTH_STATE" == "none" ]]; then
    echo "Container verification passed (running, health=$HEALTH_STATE)."
    exit 0
  else
    echo "Container is running but health=$HEALTH_STATE (attempt $attempt/$MAX_ATTEMPTS)."
  fi

  sleep "$SLEEP_SECONDS"
done

echo "Container failed startup verification."
echo "Last container logs:"
docker logs --tail 20 "$CONTAINER_NAME" || true
exit 1
