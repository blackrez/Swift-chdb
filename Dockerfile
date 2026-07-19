# Swift-chDB — Linux test environment
#
# Build:
#   docker build -t swift-chdb .
#
# Run benchmarks:
#   docker run --rm -it swift-chdb swift run chdb-clickbench --parquet --quick
#
# Interactive shell:
#   docker run --rm -it --entrypoint bash swift-chdb

FROM swift:6.3-jammy AS build

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Run setup script (downloads libchdb for Linux amd64)
COPY setup.sh .
RUN bash setup.sh --linux-amd64 && \
    cp libchdb.so /usr/lib/libchdb.so && \
    cp chdb.h /usr/include/chdb.h && \
    ldconfig

# Create pkg-config file so SwiftPM can find libchdb
RUN mkdir -p /usr/lib/pkgconfig && \
    cat > /usr/lib/pkgconfig/chdb.pc << 'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: chdb
Description: ClickHouse embedded database library
Version: 1.0.0
Libs: -L${libdir} -lchdb
Cflags: -I${includedir}
EOF

# Copy the entire project
WORKDIR /app
COPY . .

# Download test dataset
RUN bash setup.sh --dataset

# Build everything
RUN swift build --disable-sandbox -c release

# Default: run the benchmark
CMD ["swift", "run", "-c", "release", "--disable-sandbox", "chdb-clickbench", "--parquet", "--quick"]
