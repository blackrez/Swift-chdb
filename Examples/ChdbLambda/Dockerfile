# Build stage: compile Swift Lambda with chDB + native format support

FROM swift:6.0-amazonlinux2 AS builder

ARG TARGETARCH=arm64

# Install build dependencies
RUN yum install -y curl tar gzip

# Download libchdb.so for the target architecture
RUN mkdir -p /tmp/chdb && \
    if [ "$TARGETARCH" = "arm64" ]; then \
        CHDB_URL="https://github.com/chdb-io/chdb-core/releases/download/v26.5.0/linux-aarch64-libchdb.tar.gz"; \
    else \
        CHDB_URL="https://github.com/chdb-io/chdb-core/releases/download/v26.5.0/linux-x86_64-libchdb.tar.gz"; \
    fi && \
    curl -fsSL "$CHDB_URL" -o /tmp/chdb.tar.gz && \
    tar xzf /tmp/chdb.tar.gz -C /tmp/chdb && \
    cp /tmp/chdb/libchdb.so /usr/lib/ && \
    cp /tmp/chdb/chdb.h /usr/include/ && \
    rm -rf /tmp/chdb.tar.gz /tmp/chdb

# ── Copy entire project (Lambda needs parent Swift-chdb via path dep) ──
WORKDIR /app
COPY . .

# Build the Lambda target from inside its directory
WORKDIR /app/Examples/ChdbLambda
RUN swift package resolve
RUN swift build -c release --static-swift-stdlib

# ── Runtime stage: minimal Amazon Linux 2023 ──
FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal AS runtime

RUN mkdir -p /var/task/lib

# Copy libchdb.so from builder
COPY --from=builder /usr/lib/libchdb.so /var/task/lib/

# Copy the Swift executable
COPY --from=builder /app/Examples/ChdbLambda/.build/release/ChdbLambda /var/task/

# Lambda bootstrap
COPY --from=builder /app/Examples/ChdbLambda/.build/release/ChdbLambda /var/task/bootstrap

# Library path for libchdb.so
ENV LD_LIBRARY_PATH=/var/task/lib

WORKDIR /var/task
ENTRYPOINT ["/var/task/bootstrap"]
