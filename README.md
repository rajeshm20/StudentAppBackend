# StudentAppBackend

After installing docker image and successfully running StudentAppBackend app and mysql, try below endpoints using curl

Signup
```bash
 curl -X POST http://localhost:8080/auth/signup \                     
  -H "Content-Type: application/json" \
  -d '{
    "name": "Student Name",
    "email": "student@example.com",
    "password": "password123"
  }'
```

Login
```bash
curl -X POST http://localhost:8080/auth/login \                     
  -H "Content-Type: application/json" \
  -d '{
    "email": "student@example.com",
    "password": "password123"
  }'
```

💧 A project built with the Vapor web framework.

## Getting Started

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)



## Installing and configuring MySQL on a Mac using Homebrew is a straightforward process. Here's a step-by-step guide:

1. Install MySQL


Update Homebrew: First, make sure Homebrew is up to date by running the following command in your terminal:

```bash
brew update
```
Install MySQL: Next, install MySQL using the brew install command:

```bash
brew install mysql
```
This will download and install the latest stable version of MySQL.

2. Configure MySQL

After the installation is complete, you'll need to start and secure your MySQL server.

Start the MySQL Service: You can start the MySQL server as a background service. There are a couple of ways to do this:

Start it immediately and have it launch at startup:

```bash
brew services start mysql
```
Start it manually each time you want to use it:

```bash
mysql.server start
```
You can check the status of the service at any time with brew services list.

Secure the Installation: It's crucial to run the security script to set a root password, remove anonymous users, and disable remote root login. Run the following command:

```bash
mysql_secure_installation
```
You'll be prompted to follow a series of steps:

Validate Password Component: You can choose to enable or disable this. It enforces strong password policies.

Set the root password: This is a critical step. Choose a strong password.

Remove anonymous users: Type Y to remove them.

Disallow root login remotely: Type Y to prevent remote access for the root user.

Remove test database: Type Y to remove the default 'test' database.

Reload privilege tables: Type Y to apply all the changes.

3. Connect to MySQL

Once MySQL is installed and configured, you can connect to it from your terminal.

Connect to the MySQL server: Use the following command and enter the root password you set during the security configuration.

```bash
mysql -u root -p
```
The -u flag specifies the user (root), and the -p flag prompts for the password.

Verify the connection: If successful, you'll see the MySQL prompt, where you can start executing SQL commands. To exit, type exit; and press Enter.
