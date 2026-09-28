#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE_REPOSITORY:?CodeBuild must supply the ECR repository URI}"
: "${CODEBUILD_RESOLVED_SOURCE_VERSION:?Build must use a pinned Git revision}"
[[ "$CODEBUILD_RESOLVED_SOURCE_VERSION" =~ ^[0-9a-f]{40}$ ]]
revision="$CODEBUILD_RESOLVED_SOURCE_VERSION"
upstream_commit=$(jq -r .commit .xata/upstream.json)
base_image=${BUILD_BASE_IMAGE:-$(jq -r .image .xata/upstream.json)}
# Future upgrades must keep the dependency/runtime base in sync with source.
git fetch --depth 1 https://github.com/chatwoot/chatwoot.git "$upstream_commit"
git diff --exit-code "$upstream_commit" -- Gemfile Gemfile.lock package.json pnpm-lock.yaml db config/boot.rb config/application.rb
aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "${IMAGE_REPOSITORY%%/*}"
docker pull "$base_image"
# Protocol tests run without any network and use no production credentials.
docker run --rm --network none -v "$PWD:/source:ro" -w /source "$base_image" ruby test/m360/client_test.rb
image_tag="m360-${revision:0:12}-${CODEBUILD_BUILD_NUMBER}"
docker build -f Dockerfile.m360 --build-arg UPSTREAM_IMAGE="$base_image" --build-arg UPSTREAM_COMMIT="$upstream_commit" --build-arg SOURCE_COMMIT="$revision" -t "$IMAGE_REPOSITORY:$image_tag" .
bash .xata/smoke.sh "$IMAGE_REPOSITORY:$image_tag"
docker push "$IMAGE_REPOSITORY:$image_tag"
image_digest=$(aws ecr describe-images --repository-name "${IMAGE_REPOSITORY#*/}" --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)
jq -n --arg source "$revision" --arg upstream "$upstream_commit" --arg image "$IMAGE_REPOSITORY@$image_digest" --arg build "$CODEBUILD_BUILD_ID" '{sourceCommit:$source,upstreamCommit:$upstream,image:$image,buildId:$build}' > release.json
