# Wisecow Application Dockerfile
# Multi-stage build for optimized image size

FROM ubuntu:22.04 AS builder

# Set non-interactive mode for apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Update package lists and install dependencies
RUN apt-get update && \
    apt-get install -y \
    fortune-mod \
    cowsay \
    netcat-traditional \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Production stage
FROM ubuntu:22.04

# Set non-interactive mode for apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y \
    fortune-mod \
    cowsay \
    netcat-traditional \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Set environment variables
ENV PATH="/usr/games:$PATH"
ENV SRVPORT=4499

# Create application directory
WORKDIR /app

# Copy the wisecow script
COPY wisecow.sh /app/wisecow.sh

# Make script executable
RUN chmod +x /app/wisecow.sh

# Create non-root user for security
RUN groupadd -r wisecow && useradd -r -g wisecow wisecow

# Change ownership of application directory
RUN chown -R wisecow:wisecow /app

# Switch to non-root user
USER wisecow

# Expose port
EXPOSE 4499

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:4499/ || exit 1

# Run the application
CMD ["/app/wisecow.sh"]
