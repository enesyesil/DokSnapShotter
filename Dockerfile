FROM ruby:3.2-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    gpg \
    tar \
    gzip \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -r -s /bin/false -u 1000 doksnap && \
    mkdir -p /app && \
    chown -R doksnap:doksnap /app

# Set working directory
WORKDIR /app

# Copy Gemfile and install dependencies
COPY Gemfile ./
RUN bundle install

# Copy application code
COPY . .
RUN chown -R doksnap:doksnap /app

# Make executable
RUN chmod +x bin/doksnap

# Switch to non-root user
USER doksnap

# Expose status server port
EXPOSE 4567

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4567/health || exit 1

# Run the application
CMD ["bin/doksnap", "config.yaml"]
