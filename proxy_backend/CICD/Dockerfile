# ── V2V proxy image (private POC) ─────────────────────────────────────────────
# The proxy plus the built web app, which the proxy serves itself (WEBAPP_DIR):
# there is no CloudFront or S3 in the POC. The proxy serves HTTPS on port 8443
# with a certificate it creates at start-up (SERVER_TLS=self-signed), so the
# load balancer -> task connection is encrypted too.
#
# BUILD CONTEXT = REPOSITORY ROOT, because the web app lives outside
# proxy_backend. From the repository root:
#   docker buildx build --platform linux/arm64 \
#     --file proxy_backend/CICD/Dockerfile \
#     --tag <ecr-repository-url>:<tag> --push .
# What is sent to the build is limited by Dockerfile.dockerignore (next to this
# file), so Terraform variables and other folders never reach the builder.
#
# On an x86 build machine, the one RUN step in the final (ARM64) stage needs
# QEMU emulation. Set it up once per machine first (the pipeline does this):
#   docker run --privileged --rm tonistiigi/binfmt --install arm64

# ── Base image ────────────────────────────────────────────────────────────────
# Pinned to an immutable SHA-256 digest so a silent upstream tag update can
# never swap in a different image between builds (supply-chain hardening).
# The digest is the multi-platform index (amd64 + arm64): the build stages run
# on the build machine, the final image runs on ARM64 Fargate.
#
# HOW TO UPDATE (do this regularly to pick up Node and Alpine security fixes):
#   docker buildx imagetools inspect node:24-alpine \
#     --format '{{json .Manifest}}' | jq -r '.digest'
# Replace the default below, or pass --build-arg NODE_IMAGE_DIGEST=<digest>.
# The digest must be a Node 24 image: once a digest is given, the tag in FROM is
# only a label.
#
# Current default: node:24.22.2-alpine3.24 (checked 2026-11-03).
ARG NODE_IMAGE_DIGEST=sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85

# ── Stage 1: proxy dependencies ───────────────────────────────────────────────
# Plain JavaScript packages, so they install on the build machine's
# architecture and are copied into the ARM64 image without emulation.
# --ignore-scripts blocks npm lifecycle hooks; --omit=dev keeps runtime only.
FROM --platform=$BUILDPLATFORM node:24-alpine@${NODE_IMAGE_DIGEST} AS deps
WORKDIR /app
COPY proxy_backend/package.json proxy_backend/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ── Stage 2: build the web app ────────────────────────────────────────────────
# Produces static files only (webapp/dist), so it also runs on the build
# machine's architecture. Nothing from this stage except dist/ reaches the
# final image.
FROM --platform=$BUILDPLATFORM node:24-alpine@${NODE_IMAGE_DIGEST} AS webapp
WORKDIR /webapp
COPY webapp/package.json webapp/package-lock.json ./
RUN npm ci --ignore-scripts
COPY webapp/ ./
RUN npm run build

# ── Stage 3: production image ─────────────────────────────────────────────────
FROM node:24-alpine@${NODE_IMAGE_DIGEST}

# PORT and SERVER_TLS match the ECS task definition (Terraform sets the same
# values), so the image is consistent on its own as well.
ENV NODE_ENV=production \
    PORT=8443 \
    SERVER_TLS=self-signed \
    WEBAPP_DIR=/app/public
WORKDIR /app

# OCI standard labels: trace any running container back to its git commit and
# pipeline build without shelling into the container.
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_TAG=unknown
LABEL org.opencontainers.image.title="v2v-proxy-backend" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.base.name="node:24-alpine"

# Remove the package managers. The proxy never runs npm, npx, corepack or yarn,
# and the npm copy bundled in the base image carries HIGH findings in its own
# packages (brace-expansion, undici; Trivy, 2026-11-03) that would fail the
# pipeline's image scan. Paths as installed by the official node image.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
      /opt/yarn-v* /usr/local/bin/yarn /usr/local/bin/yarnpkg

# Files stay owned by root and the process runs as the unprivileged "node"
# user, so the running service cannot change its own code or the web app.
# ECS also mounts the root filesystem read-only.
COPY --from=deps /app/node_modules ./node_modules
COPY proxy_backend/package.json ./
COPY proxy_backend/src ./src
COPY --from=webapp /webapp/dist ./public

USER node

# 8443: above 1024 because the proxy does not run as root.
EXPOSE 8443

# HTTPS call to the task itself, so its own self-signed certificate is not
# checked. On ECS the task definition's health check (same command) is used.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "require('https').get({host:'127.0.0.1',port:8443,path:'/healthz',rejectUnauthorized:false,timeout:4000},(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"

# No tini: the ECS task definition sets initProcessEnabled = true, which runs
# an init process as PID 1 (docker run --init) that forwards SIGTERM to Node
# and reaps zombie processes.
CMD ["node", "src/index.js"]
