#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${YELLOW}[*] $1${NC}"
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

# Function to print error messages
print_error() {
    echo -e "${RED}[-] $1${NC}"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a port is in use
port_in_use() {
    lsof -i:"$1" >/dev/null 2>&1
}

# Function to cleanup on failure
cleanup() {
    print_status "Cleaning up..."
    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR"
    fi
    if [ -f "/etc/nginx/sites-enabled/jira-chatgpt" ]; then
        rm -f "/etc/nginx/sites-enabled/jira-chatgpt"
    fi
    if [ -f "/etc/nginx/sites-available/jira-chatgpt" ]; then
        rm -f "/etc/nginx/sites-available/jira-chatgpt"
    fi
}

# Set up trap for cleanup on script failure
trap 'cleanup' ERR

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Welcome message
print_status "Starting Jira ChatGPT Plugin installation..."
print_status "This script will install all necessary dependencies and set up the plugin."

# Check if port 3000 is available
if port_in_use 3000; then
    print_error "Port 3000 is already in use. Please free up this port before continuing."
    exit 1
fi

# Update system packages
print_status "Updating system packages..."
apt update && apt upgrade -y || {
    print_error "Failed to update system packages"
    exit 1
}
print_success "System packages updated"

# Install Node.js 18.x and npm
print_status "Installing Node.js 18.x and npm..."
if ! command_exists node || ! command_exists npm; then
    # Remove any existing nodejs installations
    apt-get remove -y nodejs npm &>/dev/null || true
    apt-get purge -y nodejs* npm* &>/dev/null || true
    apt-get autoremove -y &>/dev/null || true
    
    # Install curl if not present
    if ! command_exists curl; then
        apt-get install -y curl || {
            print_error "Failed to install curl"
            exit 1
        }
    fi
    
    # Add NodeSource repository
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - || {
        print_error "Failed to setup Node.js repository"
        exit 1
    }
    
    # Install Node.js and npm
    apt-get install -y nodejs || {
        print_error "Failed to install Node.js"
        exit 1
    }
    
    # Verify installation and version
    if ! command_exists node || ! command_exists npm; then
        print_error "Node.js or npm installation failed"
        exit 1
    fi
    
    node_version=$(node -v | cut -d 'v' -f2)
    if [[ "${node_version%%.*}" -lt 18 ]]; then
        print_error "Node.js version must be 18.x or higher"
        exit 1
    fi
    
    print_success "Node.js and npm installed"
    print_status "Node.js version: $(node -v)"
    print_status "npm version: $(npm -v)"
else
    node_version=$(node -v | cut -d 'v' -f2)
    if [[ "${node_version%%.*}" -lt 18 ]]; then
        print_error "Node.js version must be 18.x or higher"
        exit 1
    fi
    print_status "Node.js and npm are already installed"
    print_status "Node.js version: $(node -v)"
    print_status "npm version: $(npm -v)"
fi

# Install Git if not present
if ! command_exists git; then
    print_status "Installing Git..."
    apt-get install -y git || {
        print_error "Failed to install Git"
        exit 1
    }
    print_success "Git installed"
else
    print_status "Git is already installed"
fi

# Install build essentials (required for some npm packages)
print_status "Installing build essentials..."
apt-get install -y build-essential || {
    print_error "Failed to install build essentials"
    exit 1
}
print_success "Build essentials installed"

# Install PM2 globally
print_status "Installing PM2..."
npm install -g pm2 || {
    print_error "Failed to install PM2"
    exit 1
}
print_success "PM2 installed"

# Install Nginx
if ! command_exists nginx; then
    print_status "Installing Nginx..."
    apt-get install -y nginx || {
        print_error "Failed to install Nginx"
        exit 1
    }
    print_success "Nginx installed"
else
    print_status "Nginx is already installed"
fi

# Create application directory
APP_DIR="/opt/jira-chatgpt"
print_status "Creating application directory..."
if [ -d "$APP_DIR" ]; then
    print_status "Directory already exists. Backing up..."
    mv "$APP_DIR" "${APP_DIR}.backup-$(date +%Y%m%d%H%M%S)"
fi
mkdir -p $APP_DIR || {
    print_error "Failed to create application directory"
    exit 1
}

# Create application files
print_status "Creating application files..."

# Create package.json
cat > $APP_DIR/package.json << EOL
{
  "name": "jira-chatgpt-integration",
  "version": "1.0.0",
  "description": "Jira Cloud ChatGPT Integration",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "body-parser": "^1.20.2",
    "dotenv": "^16.0.3",
    "@openai/ai": "^1.0.0",
    "cors": "^2.8.5"
  }
}
EOL

# Create app.js
cat > $APP_DIR/app.js << EOL
require('dotenv').config();
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const { OpenAI } = require('@openai/ai');

const app = express();
const port = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());

// Initialize OpenAI
const openai = new OpenAI({
    apiKey: process.env.OPENAI_API_KEY
});

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'ok' });
});

// ChatGPT endpoint
app.post('/api/chatgpt', async (req, res) => {
    try {
        const { text, action, language, customPrompt } = req.body;
        
        if (!text || !action) {
            return res.status(400).json({ error: 'Missing required parameters' });
        }

        const completion = await openai.chat.completions.create({
            model: "gpt-4-turbo",
            messages: [
                { 
                    role: "system", 
                    content: "You are a helpful assistant that provides clear and concise responses." 
                },
                { 
                    role: "user", 
                    content: text 
                }
            ],
            max_tokens: 1000
        });

        res.json({
            success: true,
            response: completion.choices[0].message.content,
            tokenUsage: completion.usage.total_tokens
        });
    } catch (error) {
        console.error('Error:', error);
        res.status(500).json({ 
            error: 'Failed to process request',
            message: error.message 
        });
    }
});

app.listen(port, () => {
    console.log(\`Server running on port \${port}\`);
});
EOL

# Create .env file
print_status "Creating environment configuration..."
cat > $APP_DIR/.env << EOL
NODE_ENV=production
PORT=3000
HOST=$(hostname -f)
OPENAI_API_KEY=your-openai-api-key
EOL

# Create static directory and files
mkdir -p $APP_DIR/static
cat > $APP_DIR/static/index.html << EOL
<!DOCTYPE html>
<html>
<head>
    <title>Jira ChatGPT Integration</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .status { padding: 20px; border-radius: 5px; margin: 20px 0; }
        .success { background-color: #e7f7e7; }
        .error { background-color: #ffebee; }
    </style>
</head>
<body>
    <h1>Jira ChatGPT Integration</h1>
    <div class="status success">
        Server is running successfully!
    </div>
</body>
</html>
EOL

# Install application dependencies
print_status "Installing application dependencies..."
cd $APP_DIR
npm install || {
    print_error "Failed to install application dependencies"
    cleanup
    exit 1
}

# Backup existing Nginx configuration if it exists
if [ -f "/etc/nginx/sites-available/jira-chatgpt" ]; then
    print_status "Backing up existing Nginx configuration..."
    mv /etc/nginx/sites-available/jira-chatgpt "/etc/nginx/sites-available/jira-chatgpt.backup-$(date +%Y%m%d%H%M%S)"
fi

# Set up Nginx configuration
print_status "Configuring Nginx..."
cat > /etc/nginx/sites-available/jira-chatgpt << EOL
server {
    listen 80;
    server_name $(hostname -f);

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Remove default Nginx site if it exists
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    print_status "Removing default Nginx site..."
    rm -f /etc/nginx/sites-enabled/default
fi

# Enable the Nginx site
ln -sf /etc/nginx/sites-available/jira-chatgpt /etc/nginx/sites-enabled/ || {
    print_error "Failed to enable Nginx site"
    cleanup
    exit 1
}

# Test Nginx configuration
nginx -t || {
    print_error "Nginx configuration test failed"
    cleanup
    exit 1
}

# Restart Nginx
systemctl restart nginx || {
    print_error "Failed to restart Nginx"
    cleanup
    exit 1
}

# Set up PM2 to run the application
print_status "Setting up PM2..."
cd $APP_DIR
if [ ! -f "app.js" ]; then
    print_error "app.js not found in the repository"
    cleanup
    exit 1
}

pm2 start app.js --name jira-chatgpt || {
    print_error "Failed to start application with PM2"
    cleanup
    exit 1
}

# Save PM2 configuration
pm2 save || {
    print_error "Failed to save PM2 configuration"
    cleanup
    exit 1
}

# Set up PM2 to start on boot
pm2 startup || {
    print_error "Failed to set up PM2 startup"
    cleanup
    exit 1
}

# Install Certbot for SSL
print_status "Installing Certbot..."
apt-get install -y certbot python3-certbot-nginx || {
    print_error "Failed to install Certbot"
    exit 1
}

# Set correct permissions
print_status "Setting correct permissions..."
chown -R www-data:www-data $APP_DIR
chmod -R 755 $APP_DIR

print_success "Installation completed successfully!"
echo
echo -e "${GREEN}Next steps:${NC}"
echo "1. Edit $APP_DIR/.env and set your OpenAI API key"
echo "2. Set up SSL certificate by running: sudo certbot --nginx -d your-domain.com"
echo "3. Access the application at: http://$(hostname -f)"
echo
echo -e "${YELLOW}For support, please visit: https://github.com/yourusername/jira-chatgpt-integration${NC}"

# Ask for OpenAI API key
echo
read -p "Would you like to enter your OpenAI API key now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter your OpenAI API key: " api_key
    sed -i "s/your-openai-api-key/$api_key/" $APP_DIR/.env
    print_success "API key has been set"
fi

# Ask for domain name and set up SSL
echo
read -p "Would you like to set up SSL with Certbot now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter your domain name: " domain_name
    certbot --nginx -d $domain_name || {
        print_error "Failed to set up SSL certificate"
        exit 1
    }
    print_success "SSL certificate has been set up"
fi

print_status "Installation process completed. The plugin is now ready to use!" 