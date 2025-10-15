# mac-setup
setting up mac updated --version

## Install Xcode Command Line Tools
```
xcode-select --install
```
# Install Homebrew
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
# Configure Homebrew and Node.js on zsh
# Open or create the ~/.zshrc file instead of ~/.bash_profile

```
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
echo 'export PATH="/opt/homebrew/lib:$PATH"' >> ~/.zshrc
echo 'export PATH="/opt/homebrew/nodejs/bin:$PATH"' >> ~/.zshrc
```
# Source the ~/.zshrc to apply changes
```
source ~/.zshrc
```
# Check if PATH is updated correctly
```
echo $PATH
```
# Install Required Packages
```
brew install python@3.10 git redis mariadb@10.6 node@18 yarn
brew link --force python@3.10
brew link --force mariadb@10.6
brew link --force node@18
```
# Configure MariaDB
# Edit the MariaDB configuration file
```
nano /opt/homebrew/etc/my.cnf
```
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
bind-address = 127.0.0.1

[mysql]
default-character-set = utf8mb4

# Restart MariaDB to apply changes
```
brew services restart mariadb@10.6
```
# Install Python using pyenv (adjusting to a version compatible with Frappe)
```
brew install pyenv
pyenv install 3.9.6
pyenv global 3.9.6
```
# Install Redis and Yarn
```
brew install redis yarn
brew services start redis
```
# Install Frappe Bench
```
sudo -H pip3 install frappe-bench
```
# Initialize Frappe Bench
```
bench init frappe-bench --frappe-branch version-15
```

```

# Check Python version
python --version
 
# Verify installed pyenv versions
pyenv versions
 
# Edit shell configuration to load pyenv properly
nano ~/.zshrc
 
# Reload the shell configuration
source ~/.zshrc
 
# Confirm python command works after pyenv setup
python --version
 
# Initialize a new Frappe bench with version-15
bench init frappe-bench --frappe-branch version-15
 
# Attempt to start MariaDB (failed initially)
brew services start mariadb
 
# Install MariaDB via Homebrew
brew install mariadb
 
# Start the newly installed MariaDB service
brew services start mariadb

# load 
source ~/.zshrc
 
 
# Attempt to log in to MySQL (results in TLS/SSL error on newer MariaDB)
mysql -u root
 
# Switch to MariaDB 10.6 which is more stable for Frappe
brew services restart mariadb@10.6
 
# Retry MySQL login
mysql -u root
 
# Try sudo in case root access is required
sudo mysql -u root
 
# ✅ Inside MariaDB shell: Set root password and apply it
ALTER USER 'root'@'localhost' IDENTIFIED BY 'your_password';
FLUSH PRIVILEGES;
exit;
 
# Navigate into the bench directory
cd frappe-bench
 
# Create a new Frappe site
bench new-site demo.local

```
