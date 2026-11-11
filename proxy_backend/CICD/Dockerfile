ARG NODE_IMAGE_DIGEST=sha256:8a32c8cf649a49915a66e81e7a609223c708d0adabf288ee3f4077d765542f85

# Stage 1 - Install Proxy Dependencies
FROM --platform=$BUILDPLATFORM node:24-alpine@${NODE_IMAGE_DIGEST} AS deps

WORKDIR /app

COPY proxy_backend/package.json proxy_backend/package-lock.json ./

RUN npm ci --omit=dev --ignore-scripts && \
    npm cache clean --force

# Stage 2 - Build Web Application
FROM --platform=$BUILDPLATFORM node:24-alpine@${NODE_IMAGE_DIGEST} AS webapp

WORKDIR /webapp

COPY webapp/package.json webapp/package-lock.json ./

RUN npm ci --ignore-scripts

COPY webapp/ ./

RUN npm run build

# Stage 3 - Runtime Image
FROM node:24-alpine@${NODE_IMAGE_DIGEST}

ENV NODE_ENV=production \
    PORT=8443 \
    SERVER_TLS=self-signed \
    WEBAPP_DIR=/app/public

WORKDIR /app

ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown
ARG IMAGE_TAG=unknown

LABEL org.opencontainers.image.title="v2v-proxy-backend" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.base.name="node:24-alpine"

# Remove package managers to reduce image size and vulnerabilities
RUN rm -rf \
    /usr/local/lib/node_modules/npm \
    /usr/local/lib/node_modules/corepack \
    /usr/local/bin/npm \
    /usr/local/bin/npx \
    /usr/local/bin/corepack \
    /opt/yarn-v* \
    /usr/local/bin/yarn \
    /usr/local/bin/yarnpkg

COPY --from=deps /app/node_modules ./node_modules
COPY proxy_backend/package.json ./
COPY proxy_backend/src ./src
COPY --from=webapp /webapp/dist ./public

USER node

EXPOSE 8443

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
CMD node -e "require('https').get({host:'127.0.0.1',port:8443,path:'/healthz',rejectUnauthorized:false,timeout:4000},(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1))"

CMD ["node", "src/index.js"]