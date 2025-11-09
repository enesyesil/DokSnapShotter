# DokSnapShotter - Backup System for Dokploy Apps

DokSnapShotter is a Ruby-based backup daemon that periodically archives your Dokploy app data (directories or Docker volumes) and pushes encrypted/compressed snapshots to S3.

## Features

- **Automated Backups**: Cron-like scheduling for periodic backups
- **Multiple Sources**: Backup Docker volumes or directories
- **Encryption**: GPG (recommended) or AES-256 encryption support
- **Cloud Storage**: Upload to AWS S3
- **Retention Policies**: Configurable count-based and time-based retention
- **Pre/Post Hooks**: Execute commands before and after backups
- **Status API**: Sinatra web server with health checks, metrics, and backup history
- **Docker Ready**: Containerized for easy deployment

## Architecture

- **Ruby-based**: Simple YAML configuration and clean scripting
- **Daemon Mode**: Long-running process with internal cron-like scheduler
- **Status Endpoint**: Optional Sinatra web server for monitoring
- **Containerized**: Works seamlessly with Dokploy's Dockerized apps

## Installation

### Prerequisites

- Ruby 3.2+ (or use Docker)
- GPG (for GPG encryption) or OpenSSL (for AES-256)
- AWS S3 account
- Access to Docker volumes or directories you want to backup

### Using Docker (Recommended)

1. Clone the repository:
```bash
git clone https://github.com/yourusername/DokSnapShotter.git
cd DokSnapShotter
```

2. Copy and configure the example files:
```bash
cp config.yaml.example config.yaml
cp .env.example .env
```

3. Edit `config.yaml` with your app configurations
4. Edit `.env` with your credentials

5. Build and run with Docker Compose:
```bash
docker-compose up -d
```

### Manual Installation

1. Install dependencies:
```bash
bundle install
```

2. Configure:
```bash
cp config.yaml.example config.yaml
# Edit config.yaml with your settings
```

3. Set environment variables:
```bash
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export GPG_PUBLIC_KEY="$(cat your-public-key.asc)"
```

4. Run:
```bash
bin/doksnap config.yaml
```

## Configuration

### Configuration File (`config.yaml`)

```yaml
s3:
  endpoint: s3.amazonaws.com
  bucket: my-backups
  region: us-east-1

encryption:
  method: gpg  # or aes256

status_server:
  enabled: true
  port: 4567
  bind: 0.0.0.0

apps:
  - name: myapp
    type: volume
    source: /var/lib/docker/volumes/myapp_data
    schedule: "0 2 * * *"  # Daily at 2 AM
    retention:
      keep_last: 7
      daily: 7
      weekly: 4
      monthly: 12
    hooks:
      pre_backup: "docker stop myapp"
      post_backup: "docker start myapp"
```

### Environment Variables

- `AWS_ACCESS_KEY_ID`: S3 access key
- `AWS_SECRET_ACCESS_KEY`: S3 secret key
- `GPG_PUBLIC_KEY`: GPG public key (for GPG encryption)
- `ENCRYPTION_PASSWORD`: Password (for AES-256 encryption)
- `DOKSNAP_API_KEY`: API key for status server authentication (optional, only needed if `require_auth: true`)

### App Configuration

Each app in the `apps` section requires:

- **name**: Unique identifier for the app
- **type**: `volume` or `directory`
- **source**: Path to the volume or directory
- **schedule**: Cron expression (e.g., `"0 2 * * *"` for daily at 2 AM)
- **retention**: Retention policy (all fields optional)
  - `keep_last`: Always keep the last N backups
  - `daily`: Keep daily backups for N days
  - `weekly`: Keep weekly backups for N weeks
  - `monthly`: Keep monthly backups for N months
- **hooks**: Optional pre/post backup commands

## Retention Policies

Retention policies work together:

1. **keep_last**: Always preserves the most recent N backups
2. **daily**: For backups older than N days, keeps only the latest per day
3. **weekly**: For backups older than N weeks, keeps only the latest per week
4. **monthly**: For backups older than N months, keeps only the latest per month

Example: With `keep_last: 7, daily: 7, weekly: 4, monthly: 12`:
- Last 7 backups: all kept
- Days 8-14: one backup per day
- Weeks 3-4: one backup per week
- Months 2-12: one backup per month

## Status API

The status server provides several endpoints for monitoring backups. By default, authentication is **disabled** for hobby use. Enable it only if your server is exposed to the internet.

### Authentication (Optional)

**When to enable:**
- Server is exposed to the internet
- Shared network where others might access it
- Production environment

**When NOT needed:**
- Localhost only (`bind: 127.0.0.1`)
- Private network (behind firewall)
- Hobby/personal server

To enable authentication:
1. Set `require_auth: true` in `config.yaml`
2. Generate an API key: `openssl rand -base64 32`
3. Set environment variable: `export DOKSNAP_API_KEY=your_key_here`
4. Use in requests: `curl -H "X-API-Key: your_key" http://localhost:4567/status`

### Endpoints

#### Health Check
```bash
curl http://localhost:4567/health
```

#### App Status
```bash
curl http://localhost:4567/status
# With auth: curl -H "X-API-Key: your_key" http://localhost:4567/status
```

#### Metrics
```bash
curl http://localhost:4567/metrics
# With auth: curl -H "X-API-Key: your_key" http://localhost:4567/metrics
```

#### Backup History
```bash
# All apps
curl http://localhost:4567/history

# Specific app
curl http://localhost:4567/history?app=myapp

# With auth: add ?api_key=your_key or use X-API-Key header
```

#### List Backups
```bash
curl http://localhost:4567/backups/myapp
# With auth: curl -H "X-API-Key: your_key" http://localhost:4567/backups/myapp
```

## Encryption

### GPG Encryption (Recommended)

1. Generate a GPG key pair:
```bash
gpg --gen-key
```

2. Export the public key:
```bash
gpg --armor --export your-email@example.com > public-key.asc
```

3. Set the environment variable:
```bash
export GPG_PUBLIC_KEY="$(cat public-key.asc)"
```

### AES-256 Encryption

Set a strong password:
```bash
export ENCRYPTION_PASSWORD=your_strong_password_here
```

## Docker Volume Backup

To backup Docker volumes, ensure the container has access to:
- `/var/lib/docker/volumes` (for volume data)
- `/var/run/docker.sock` (for Docker commands in hooks)

Example docker-compose volume mounts:
```yaml
volumes:
  - /var/lib/docker/volumes:/var/lib/docker/volumes:ro
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

## Scheduling

Schedules use standard cron format:
- `"0 2 * * *"` - Daily at 2 AM
- `"0 */6 * * *"` - Every 6 hours
- `"0 0 * * 0"` - Weekly on Sunday at midnight
- `"0 0 1 * *"` - Monthly on the 1st at midnight

## Troubleshooting

### Backup Fails

1. Check logs: `docker logs doksnapshotter`
2. Verify source path exists and is accessible
3. Check S3 credentials and permissions
4. Verify encryption keys are set correctly

### Status Server Not Responding

1. Check if enabled in config: `status_server.enabled: true`
2. Verify port is not in use: `netstat -tuln | grep 4567`
3. Check firewall rules

### GPG Encryption Issues

1. Ensure GPG is installed: `gpg --version`
2. Verify public key is imported: `gpg --list-keys`
3. Check key format in environment variable

## Development

### Running Tests

```bash
bundle exec rspec  # If tests are added
```

### Project Structure

```
DokSnapShotter/
├── bin/
│   └── doksnap              # Main executable
├── lib/
│   ├── doksnap.rb           # Main orchestrator
│   ├── config.rb             # Configuration parser
│   ├── backup.rb             # Backup executor
│   ├── encryption.rb         # Encryption handlers
│   ├── s3_uploader.rb        # S3 upload
│   ├── retention.rb          # Retention policies
│   ├── scheduler.rb          # Cron scheduler
│   └── status_server.rb      # Sinatra API
├── config.yaml.example       # Example config
├── Dockerfile                # Container image
└── docker-compose.yml        # Compose setup
```

## License

MIT License - see LICENSE file for details

## Contributing

Contributions welcome! Please open an issue or submit a pull request.

## Support

For issues and questions, please open a GitHub issue.
