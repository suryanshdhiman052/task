#!/usr/bin/env bash
set -euo pipefail

# Build app/ and push an immutable tag to the stack's ECR repo.
# Run after the root terraform apply has created the repository.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
TAG="${1:-$(git -C "$ROOT" rev-parse --short HEAD)}"

REPO_URL="$(terraform -chdir="$ROOT" output -raw ecr_repository_url)"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${REPO_URL%%/*}"

docker build -t "${REPO_URL}:${TAG}" "$ROOT/app"
docker push "${REPO_URL}:${TAG}"
echo "Pushed ${REPO_URL}:${TAG}"
echo "Set container_image to that URI, container_command = [], health_path = \"/healthz\", then terraform apply."
