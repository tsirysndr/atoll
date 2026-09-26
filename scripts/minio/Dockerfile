FROM golang:1.24.7-alpine AS build
RUN apk add --no-cache git ca-certificates
WORKDIR /src
ADD https://github.com/minio/minio/archive/refs/tags/RELEASE.2025-09-07T16-13-09Z.tar.gz /tmp/minio.tar.gz
RUN tar -xzf /tmp/minio.tar.gz --strip-components=1 -C /src
RUN CGO_ENABLED=0 go build -trimpath -o /minio .

FROM alpine:3.21
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /minio /usr/local/bin/minio
ENTRYPOINT ["minio"]
