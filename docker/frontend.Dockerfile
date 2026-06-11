# Frontend image: builds the Vue app and serves it with nginx.
# Build from the REPO ROOT:  docker build -f docker/frontend.Dockerfile -t <user>/cloudradar-frontend:v1 .

# Stage 1: build the Vue app
FROM node:20-alpine AS builder
WORKDIR /build
COPY app/frontend/package*.json ./
RUN npm ci
COPY app/frontend/ ./
RUN npm run build

# Stage 2: serve with nginx
FROM nginx:1.27-alpine
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /build/dist /usr/share/nginx/html
EXPOSE 80
