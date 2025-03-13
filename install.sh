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

# Check if lsof is installed
if ! command_exists lsof; then
    print_status "Installing lsof..."
    apt-get install -y lsof || {
        print_error "Failed to install lsof"
        exit 1
    }
    print_success "lsof installed"
fi

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
    "openai": "^4.24.1",
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
const OpenAI = require('openai');
const path = require('path');

const app = express();
const port = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'static')));

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

        let systemPrompt = "You are a helpful assistant that provides clear and concise responses.";
        let userPrompt = text;

        // Customize prompt based on action
        switch (action) {
            case 'explain':
                systemPrompt = "You are a technical expert. Explain concepts clearly with examples.";
                userPrompt = \`Please explain the following text: \${text}\`;
                break;
            case 'summarize':
                systemPrompt = "You are a summarizer. Keep summaries concise and focused on key points.";
                userPrompt = \`Please summarize the following text: \${text}\`;
                break;
            case 'translate':
                systemPrompt = "You are a translator. Maintain the original meaning while translating.";
                userPrompt = \`Translate the following text to \${language || 'English'}: \${text}\`;
                break;
            case 'custom':
                userPrompt = \`\${customPrompt || 'Please analyze'}: \${text}\`;
                break;
        }

        const completion = await openai.chat.completions.create({
            model: "gpt-3.5-turbo",
            messages: [
                { 
                    role: "system", 
                    content: systemPrompt
                },
                { 
                    role: "user", 
                    content: userPrompt
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
mkdir -p $APP_DIR/static || {
    print_error "Failed to create static directory"
    cleanup
    exit 1
}

cat > $APP_DIR/static/index.html << EOL
<!DOCTYPE html>
<html>
<head>
    <title>Jira ChatGPT Integration</title>
    <style>
        body { 
            font-family: Arial, sans-serif; 
            margin: 0;
            padding: 20px;
            line-height: 1.6;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
        }
        .status { 
            padding: 20px; 
            border-radius: 5px; 
            margin: 20px 0; 
        }
        .success { 
            background-color: #e7f7e7; 
            border-left: 4px solid #28a745;
        }
        .error { 
            background-color: #ffebee; 
            border-left: 4px solid #dc3545;
        }
        .card {
            border: 1px solid #ddd;
            border-radius: 5px;
            padding: 20px;
            margin: 20px 0;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #0052CC;
        }
        .form-group {
            margin-bottom: 15px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
        }
        input, select, textarea {
            width: 100%;
            padding: 8px;
            border: 1px solid #ddd;
            border-radius: 4px;
            box-sizing: border-box;
        }
        textarea {
            min-height: 100px;
        }
        button {
            background-color: #0052CC;
            color: white;
            border: none;
            padding: 10px 15px;
            border-radius: 4px;
            cursor: pointer;
        }
        button:hover {
            background-color: #0043A4;
        }
        #response {
            white-space: pre-wrap;
            background-color: #f8f9fa;
            padding: 15px;
            border-radius: 4px;
            border: 1px solid #ddd;
            min-height: 100px;
            margin-top: 10px;
        }
        .hidden {
            display: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Jira ChatGPT Integration</h1>
        
        <div class="status success">
            Server is running successfully!
        </div>
        
        <div class="card">
            <h2>Test the API</h2>
            <div class="form-group">
                <label for="action">Action:</label>
                <select id="action">
                    <option value="explain">Explain</option>
                    <option value="summarize">Summarize</option>
                    <option value="translate">Translate</option>
                    <option value="custom">Custom Question</option>
                </select>
            </div>
            
            <div class="form-group language-group hidden">
                <label for="language">Language:</label>
                <select id="language">
                    <option value="English">English</option>
                    <option value="Spanish">Spanish</option>
                    <option value="French">French</option>
                    <option value="German">German</option>
                    <option value="Chinese">Chinese</option>
                    <option value="Japanese">Japanese</option>
                    <option value="Russian">Russian</option>
                </select>
            </div>
            
            <div class="form-group custom-group hidden">
                <label for="customPrompt">Custom Prompt:</label>
                <input type="text" id="customPrompt" placeholder="Enter your question...">
            </div>
            
            <div class="form-group">
                <label for="text">Text:</label>
                <textarea id="text" placeholder="Enter text to process..."></textarea>
            </div>
            
            <button id="submit">Submit</button>
            
            <div class="form-group">
                <label for="response">Response:</label>
                <div id="response"></div>
            </div>
            
            <div id="error" class="error hidden"></div>
        </div>
    </div>
    
    <script>
        document.addEventListener('DOMContentLoaded', function() {
            const actionSelect = document.getElementById('action');
            const languageGroup = document.querySelector('.language-group');
            const customGroup = document.querySelector('.custom-group');
            
            actionSelect.addEventListener('change', function() {
                if (this.value === 'translate') {
                    languageGroup.classList.remove('hidden');
                } else {
                    languageGroup.classList.add('hidden');
                }
                
                if (this.value === 'custom') {
                    customGroup.classList.remove('hidden');
                } else {
                    customGroup.classList.add('hidden');
                }
            });
            
            document.getElementById('submit').addEventListener('click', async function() {
                const action = actionSelect.value;
                const text = document.getElementById('text').value;
                const language = document.getElementById('language').value;
                const customPrompt = document.getElementById('customPrompt').value;
                const responseElement = document.getElementById('response');
                const errorElement = document.getElementById('error');
                
                if (!text) {
                    errorElement.textContent = 'Please enter text to process';
                    errorElement.classList.remove('hidden');
                    return;
                }
                
                errorElement.classList.add('hidden');
                responseElement.textContent = 'Loading...';
                
                try {
                    const response = await fetch('/api/chatgpt', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json'
                        },
                        body: JSON.stringify({
                            action,
                            text,
                            language,
                            customPrompt
                        })
                    });
                    
                    const data = await response.json();
                    
                    if (data.error) {
                        errorElement.textContent = data.error;
                        errorElement.classList.remove('hidden');
                        responseElement.textContent = '';
                    } else {
                        responseElement.textContent = data.response;
                    }
                } catch (error) {
                    errorElement.textContent = 'Error: ' + error.message;
                    errorElement.classList.remove('hidden');
                    responseElement.textContent = '';
                }
            });
        });
    </script>
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

# Verify OpenAI package installation
if [ ! -d "$APP_DIR/node_modules/openai" ]; then
    print_error "OpenAI package was not installed correctly"
    print_status "Trying to install OpenAI package specifically..."
    npm install openai@4.24.1 || {
        print_error "Failed to install OpenAI package"
        cleanup
        exit 1
    }
    print_success "OpenAI package installed"
fi

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

# Make app.js executable
chmod +x $APP_DIR/app.js || {
    print_error "Failed to make app.js executable"
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

# Final check to ensure the application is running
print_status "Checking if the application is running..."
sleep 5  # Give the application time to start

# Ensure curl is installed for the health check
if ! command_exists curl; then
    print_status "Installing curl for health check..."
    apt-get install -y curl || {
        print_error "Failed to install curl"
        print_status "Skipping health check"
    }
fi

if command_exists curl && curl -s http://localhost:3000/health | grep -q "ok"; then
    print_success "Application is running correctly!"
else
    print_error "Application may not be running correctly"
    print_status "Check the logs with: pm2 logs jira-chatgpt"
    print_status "You can restart the application with: pm2 restart jira-chatgpt"
fi

print_success "Installation completed successfully!"
echo
echo -e "${GREEN}Next steps:${NC}"
echo "1. Edit $APP_DIR/.env and set your OpenAI API key (if not already done)"
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
    if [ -z "$api_key" ]; then
        print_error "API key cannot be empty"
        print_status "You can set it later by editing $APP_DIR/.env"
    else
        sed -i "s/your-openai-api-key/$api_key/" $APP_DIR/.env
        print_success "API key has been set"
        
        # Restart the application to apply the new API key
        print_status "Restarting the application to apply the new API key..."
        pm2 restart jira-chatgpt || {
            print_error "Failed to restart the application"
            print_status "You may need to restart it manually: pm2 restart jira-chatgpt"
        }
    fi
else
    print_status "You can set the API key later by editing $APP_DIR/.env"
    print_status "After setting the API key, restart the application: pm2 restart jira-chatgpt"
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

# Create README.md
cat > $APP_DIR/README.md << EOL
# Jira ChatGPT Integration

This application integrates ChatGPT with Jira Cloud, allowing users to process text using OpenAI's GPT models.

## Features

- **Explain**: Get detailed explanations of technical concepts
- **Summarize**: Create concise summaries of text
- **Translate**: Translate text to different languages
- **Custom Questions**: Ask custom questions about selected text

## Technical Details

- Built with Node.js and Express
- Uses OpenAI's GPT-3.5 Turbo model
- Deployed with PM2 for process management
- Secured with Nginx as a reverse proxy

## Configuration

The application uses environment variables for configuration:

- \`PORT\`: The port the server runs on (default: 3000)
- \`HOST\`: The hostname for the server
- \`OPENAI_API_KEY\`: Your OpenAI API key

## API Endpoints

### POST /api/chatgpt

Process text with ChatGPT.

**Request Body:**

\`\`\`json
{
  "text": "Text to process",
  "action": "explain|summarize|translate|custom",
  "language": "English", // Only required for translate action
  "customPrompt": "Your question" // Only required for custom action
}
\`\`\`

**Response:**

\`\`\`json
{
  "success": true,
  "response": "ChatGPT response",
  "tokenUsage": 123
}
\`\`\`

### GET /health

Check if the server is running.

**Response:**

\`\`\`json
{
  "status": "ok"
}
\`\`\`

## Testing

Visit http://your-server-address/ to access the test interface.

## Maintenance

The application is managed by PM2. Use the following commands for maintenance:

- \`pm2 status\`: Check the status of the application
- \`pm2 logs jira-chatgpt\`: View application logs
- \`pm2 restart jira-chatgpt\`: Restart the application
- \`pm2 stop jira-chatgpt\`: Stop the application
- \`pm2 start jira-chatgpt\`: Start the application

## Support

For support, please contact the administrator.
EOL