FROM node:20.18-alpine

RUN addgroup -S app && adduser -S -G app -u 1000 app
WORKDIR /app
COPY server.js ./
USER app
EXPOSE 8080
CMD ["node", "server.js"]
