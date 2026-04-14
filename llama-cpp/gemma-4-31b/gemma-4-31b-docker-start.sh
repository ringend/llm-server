#!/bin/bash

###################################
# Stops the container if running.
# Removes the container if it exists.
# Starts the new container.
# Verifies the container is healthy.

#####################################
# Container Name varible
CONTAINER_NAME="llama-cpp-gemma-4-31b-q4k"

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
  -p 8130:8080 \
  -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
  -v /llm-models:/llm-models \
  ghcr.io/ggml-org/llama.cpp:server-vulkan-b8763@sha256:d2c65aa5d29e592f31db7f0d8158cdfc72a8fe9319ee0279772e270dd8a01ca1 \
  --model /llm-models/gemma4-q4_k.gguf \
  --gpu-layers -1 \
  --parallel 2 \
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
  RUNNING_STATE=$(sudo docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
  HEALTH_STATE=$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

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
sudo docker logs --tail 20 "$CONTAINER_NAME" || true
exit 1