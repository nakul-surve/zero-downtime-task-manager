#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════════════╗
║                                                   ║
║  Zero-Downtime Task Manager                       ║
║  EC2 Automated Setup Script                       ║
║                                                   ║
╚═══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    log_error "Please run as regular user, not root"
    exit 1
fi

echo ""
log_info "Starting EC2 setup process..."
echo ""

# Step 1: Update system
log_info "Step 1: Updating system packages..."
sudo apt update && sudo apt upgrade -y
log_success "System updated"
echo ""

# Step 2: Install Docker
log_info "Step 2: Installing Docker..."
if command -v docker &> /dev/null; then
    log_info "Docker already installed"
else
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
    log_success "Docker installed"
fi

# Add user to docker group
sudo usermod -aG docker $USER
log_success "User added to docker group"
echo ""

# Step 3: Install Docker Compose
log_info "Step 3: Installing Docker Compose..."
if command -v docker-compose &> /dev/null; then
    log_info "Docker Compose already installed"
else
    sudo apt install docker-compose -y
    log_success "Docker Compose installed"
fi
echo ""

# Step 4: Install Git
log_info "Step 4: Installing Git..."
if command -v git &> /dev/null; then
    log_info "Git already installed"
else
    sudo apt install git -y
    log_success "Git installed"
fi
echo ""

# Step 5: Install useful tools
log_info "Step 5: Installing useful tools..."
sudo apt install -y curl wget vim htop net-tools jq
log_success "Tools installed"
echo ""

# Step 6: Configure firewall (UFW)
log_info "Step 6: Configuring firewall..."
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS (for future SSL)
sudo ufw --force enable
log_success "Firewall configured"
echo ""

# Step 7: Optimize Docker settings
log_info "Step 7: Optimizing Docker settings..."
sudo mkdir -p /etc/docker
cat << EOF | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
log_success "Docker logging configured"
echo ""

# Step 8: Clone repository (if not already cloned)
log_info "Step 8: Setting up project..."
if [ -d "$HOME/zero-downtime-task-manager" ]; then
    log_info "Project directory already exists"
    cd $HOME/zero-downtime-task-manager
    git pull origin main
else
    read -p "Enter your GitHub repository URL: " REPO_URL
    git clone $REPO_URL $HOME/zero-downtime-task-manager
    cd $HOME/zero-downtime-task-manager
fi
log_success "Project ready"
echo ""

# Step 9: Make scripts executable
log_info "Step 9: Configuring scripts..."
chmod +x deploy.sh
chmod +x test.sh
log_success "Scripts configured"
echo ""

# Step 10: Setup completion
echo ""
log_success "╔════════════════════════════════════════════════╗"
log_success "║  EC2 Setup Complete!                           ║"
log_success "╚════════════════════════════════════════════════╝"
echo ""

echo -e "${YELLOW}IMPORTANT: You must log out and log back in for Docker permissions to take effect.${NC}"
echo ""
echo "Next steps:"
echo "  1. Log out: exit"
echo "  2. Log back in: ssh -i your-key.pem ubuntu@your-ec2-ip"
echo "  3. Start application: cd zero-downtime-task-manager && docker-compose up -d"
echo "  4. Test deployment: ./test.sh"
echo ""
echo "For GitHub Actions CI/CD setup, see QUICKSTART.md"
echo ""
