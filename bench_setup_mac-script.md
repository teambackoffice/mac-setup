#!/bin/bash
 
# Frappe Bench Automatic Installation Script for macOS
# This script automates the complete setup of Frappe Bench on macOS
# It's idempotent - can be run multiple times safely
 
echo "======================================"
echo "Frappe Bench Auto-Installer for macOS"
echo "======================================"
echo ""
 
# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}
 
# Function to print status messages
print_status() {
    echo ""
    echo ">>> $1"
    echo ""
}
 
# Function to print success messages
print_success() {
    echo "✓ $1"
}
 
# Function to print skip messages
print_skip() {
    echo "⊙ $1 (already installed/configured, skipping)"
}
 
# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This script is designed for macOS only."
    exit 1
fi
 
# Install Xcode Command Line Tools
print_status "Step 1: Checking Xcode Command Line Tools..."
if xcode-select -p &>/dev/null; then
    print_skip "Xcode Command Line Tools"
else
    xcode-select --install
    echo "⚠ Please complete the Xcode installation in the popup window, then re-run this script."
    exit 0
fi
 
# Install Homebrew
print_status "Step 2: Checking Homebrew..."
if command_exists brew; then
    print_skip "Homebrew"
else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add Homebrew to PATH for Apple Silicon Macs
    if [[ $(uname -m) == "arm64" ]]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    print_success "Homebrew installed"
fi
 
# Ensure Homebrew is in PATH
if [[ $(uname -m) == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
 
# Configure zsh with proper paths
print_status "Step 3: Configuring zsh environment..."
if grep -q "# Frappe Bench Configuration" ~/.zshrc 2>/dev/null; then
    print_skip "zsh configuration"
else
    cat >> ~/.zshrc << 'EOF'
 
# Frappe Bench Configuration
export PATH="/opt/homebrew/bin:$PATH"
export PATH="/opt/homebrew/lib:$PATH"
export PATH="/opt/homebrew/opt/node@18/bin:$PATH"
EOF
    print_success "zsh configured"
fi
 
source ~/.zshrc 2>/dev/null || true
 
# Install required packages
print_status "Step 4: Installing required packages..."
PACKAGES=("python@3.10" "git" "redis" "mariadb@10.6" "node@18" "yarn")
for package in "${PACKAGES[@]}"; do
    if brew list "$package" &>/dev/null; then
        print_skip "$package"
    else
        echo "Installing $package..."
        brew install "$package"
        print_success "$package installed"
    fi
done
 
print_status "Step 5: Linking packages..."
brew link --force --overwrite python@3.10 2>/dev/null || true
brew link --force --overwrite mariadb@10.6 2>/dev/null || true
brew link --force --overwrite node@18 2>/dev/null || true
print_success "Packages linked"
 
# Configure MariaDB
print_status "Step 6: Configuring MariaDB..."
if [ -f /opt/homebrew/etc/my.cnf ] && grep -q "character-set-server = utf8mb4" /opt/homebrew/etc/my.cnf; then
    print_skip "MariaDB configuration"
else
    cat > /opt/homebrew/etc/my.cnf << 'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
bind-address = 127.0.0.1
 
[mysql]
default-character-set = utf8mb4
EOF
    print_success "MariaDB configured"
fi
 
# Start MariaDB
print_status "Step 7: Starting MariaDB service..."
if brew services list | grep "mariadb@10.6" | grep -q "started"; then
    print_skip "MariaDB service (already running)"
    brew services restart mariadb@10.6 >/dev/null 2>&1
else
    brew services start mariadb@10.6
    print_success "MariaDB service started"
fi
sleep 5  # Wait for MariaDB to start
 
# Configure MariaDB root password
print_status "Step 8: Configuring MariaDB root password..."
echo "⚠ We need to set or verify the MariaDB root password."
echo ""
echo "Attempting to connect to MariaDB..."
 
# Try connecting without password
if mysql -u root -e "SELECT 1" &>/dev/null 2>&1; then
    echo "✓ Connected without password. Setting a new password..."
    echo ""
    echo "Please enter a NEW password for MariaDB root user:"
    read -s MYSQL_ROOT_PASSWORD
    echo ""
    
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    
    if [ $? -eq 0 ]; then
        print_success "MariaDB root password set successfully"
        echo "IMPORTANT: Save this password - you'll need it when creating sites!"
    else
        echo "✗ Failed to set password"
        exit 1
    fi
else
    echo "⚠ MariaDB root already has a password set."
    echo ""
    echo "If you know the password, the script will continue."
    echo "If you DON'T know it, press Ctrl+C now and reset it manually with:"
    echo ""
    echo "  mysql -u root -p"
    echo "  (or if that fails: brew uninstall mariadb@10.6 && rm -rf /opt/homebrew/var/mysql && brew install mariadb@10.6)"
    echo ""
    echo "Do you want to continue with the existing password? (y/N):"
    read -r CONTINUE
    
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        echo "Script stopped. Please reset your MariaDB password and re-run."
        exit 0
    fi
    
    print_success "Continuing with existing MariaDB password"
    echo "⚠ Remember: You'll need this password when creating sites with 'bench new-site'"
fi
 
# Install pyenv and Python 3.10
print_status "Step 9: Installing pyenv and Python 3.10..."
if command_exists pyenv; then
    print_skip "pyenv"
else
    brew install pyenv
    
    # Add pyenv to zsh
    if ! grep -q "# Pyenv Configuration" ~/.zshrc 2>/dev/null; then
        cat >> ~/.zshrc << 'EOF'
 
# Pyenv Configuration
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
EOF
    fi
    print_success "pyenv installed"
fi
 
# Initialize pyenv in current shell
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)" 2>/dev/null || true
eval "$(pyenv init -)" 2>/dev/null || true
 
# Install Python 3.10.15 if not already installed
if pyenv versions 2>/dev/null | grep -q "3.10"; then
    print_skip "Python 3.10"
else
    echo "Installing Python 3.10.15 (this may take a few minutes)..."
    pyenv install 3.10.15
    print_success "Python 3.10.15 installed"
fi
 
# Set Python 3.10 as global
pyenv global 3.10.15
 
# Verify Python version
echo "Current Python version: $(python --version)"
 
# Start Redis
print_status "Step 10: Starting Redis service..."
if brew services list | grep "redis" | grep -q "started"; then
    print_skip "Redis service"
else
    brew services start redis
    print_success "Redis service started"
fi
 
# Install Frappe Bench for Python 3.10
print_status "Step 11: Installing Frappe Bench for Python 3.10..."
 
# Always reinstall frappe-bench for the current Python version
echo "Ensuring frappe-bench is installed for Python 3.10.15..."
pip3 install --upgrade pip
pip3 install --force-reinstall frappe-bench
 
# Verify bench installation
if command_exists bench; then
    print_success "Frappe Bench installed ($(bench --version))"
else
    echo "✗ Error: Frappe Bench installation failed"
    echo "Trying alternative installation method..."
    python -m pip install frappe-bench
    
    if command_exists bench; then
        print_success "Frappe Bench installed via alternative method"
    else
        echo "✗ Error: Could not install Frappe Bench"
        echo "Please try manually: pip3 install frappe-bench"
        exit 1
    fi
fi
 
# Initialize Frappe Bench
print_status "Step 12: Initializing Frappe Bench..."
if [ -d ~/frappe-bench ]; then
    print_skip "Frappe Bench initialization (directory exists)"
    cd ~/frappe-bench
else
    cd ~
    
    # Ensure pyenv is active and get the correct Python path
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init --path)" 2>/dev/null || true
    eval "$(pyenv init -)" 2>/dev/null || true
    
    # Get the exact Python 3.10 path from pyenv
    PYTHON_PATH=$(pyenv which python)
    
    echo "Using Python at: $PYTHON_PATH"
    python --version
    echo ""
    echo "Initializing bench (this may take several minutes)..."
    echo "Please be patient while dependencies are downloaded and installed..."
    echo ""
    
    # Explicitly specify the Python version to avoid using system Python
    if ! bench init frappe-bench --frappe-branch version-15 --python "$PYTHON_PATH"; then
        echo ""
        echo "✗ Error: Bench initialization failed!"
        echo ""
        echo "Common issues and solutions:"
        echo "1. Internet connection - Check your network"
        echo "2. Python version - Verify: python --version (should be 3.10.15)"
        echo "3. Bench command - Try: which bench"
        echo "4. Reinstall bench - Try: pip3 install --force-reinstall frappe-bench"
        echo ""
        echo "If bench init was rolled back, you can safely re-run this script."
        exit 1
    fi
    
    print_success "Frappe Bench initialized"
    cd ~/frappe-bench
fi
 
# Verify we're in the correct directory
if [ ! -d ~/frappe-bench ]; then
    echo ""
    echo "✗ Error: frappe-bench directory does not exist!"
    echo "The bench initialization may have failed. Please check the errors above."
    exit 1
fi
 
cd ~/frappe-bench
 
# Final instructions
print_status "Installation completed successfully!"
echo ""
echo "======================================"
echo "Installation Summary"
echo "======================================"
echo "✓ Frappe Bench location: ~/frappe-bench"
echo "✓ Python version: $(python --version)"
echo "✓ Bench version: $(bench --version)"
echo "✓ All dependencies installed"
echo "✓ Services running: MariaDB, Redis"
echo ""
echo "======================================"
echo "Next Steps - Create Your Site"
echo "======================================"
echo ""
echo "1. Navigate to bench directory:"
echo "   cd ~/frappe-bench"
echo ""
echo "2. Create a new site:"
echo "   bench new-site mysite.local"
echo "   (You'll be prompted for MariaDB root password and admin password)"
echo ""
echo "3. Add to /etc/hosts file:"
echo "   sudo nano /etc/hosts"
echo "   Add this line: 127.0.0.1 mysite.local"
echo "   Save and exit (Ctrl+X, Y, Enter)"
echo ""
echo "4. Start the development server:"
echo "   bench start"
echo ""
echo "5. Access your site in browser:"
echo "   http://mysite.local:8000"
echo "   Login: Administrator / [your admin password]"
echo ""
echo "======================================"
echo "Useful Commands"
echo "======================================"
echo "• bench new-site sitename.local          - Create new site"
echo "• bench start                            - Start development server"
echo "• bench --site sitename.local migrate    - Run migrations"
echo "• bench get-app appname                  - Install Frappe apps"
echo "• bench --site sitename.local install-app appname - Add app to site"
echo "• bench --site sitename.local add-to-hosts - Auto-add to /etc/hosts"
echo ""
echo "======================================"
echo "Troubleshooting"
echo "======================================"
echo "If MariaDB password issues:"
echo "  mysql -u root -p"
echo "  (or reinstall: brew uninstall mariadb@10.6 && rm -rf /opt/homebrew/var/mysql)"
echo ""
echo "For more info: https://frappeframework.com/docs"
echo "======================================"
 
