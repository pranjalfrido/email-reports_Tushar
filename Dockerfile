FROM node:20-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY lib/        ./lib/
COPY sql/        ./sql/
COPY email-cancelled-no-refund.mjs \
     email-uc-sync-audit.mjs \
     email-uc-order-not-closed.mjs \
     server.mjs ./

ENV PORT=8080
CMD ["node", "server.mjs"]
