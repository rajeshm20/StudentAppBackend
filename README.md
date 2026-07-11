# StudentAppBackend - Vapor swift server with REST & GRAPHQL APIs

💧 A project built with the Vapor swift server framework.

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


After
```bash
docker pull ghcr.io/rajeshm20/studentappbackend:latest
```
pulling the docker image and successfully running that includes StudentAppBackend app and mysql, try below endpoints using curl
with http

SignUp
```
curl -k -X POST  https://localhost:8080/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"name":"SasvathRN", "email": "sasvathrn@rnss.com", "password":"password123"}'
```

Login
```
curl -k -X POST https://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "rajesh@example.com",
    "password": "password123"
  }'
```

with https
Signup
```bash
 curl https://localhost:8080/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"name":"SasvathRN", "email": "sasvathrn@rnss.com", "password":"password123"}'
```
Login
```bash
curl https://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"sasvathrn@rnss.com","password":"password123"}'
```

## GraphQL

This project now exposes GraphQL at `POST /graphql` alongside the existing REST auth APIs.

Available operations in the first schema:

- `students`: fetch all students
- `student(id: UUID!)`: fetch one student
- `signup(input: StudentGraphQLCreateInput!)`: create a student
- `login(input: StudentGraphQLLoginInput!)`: authenticate and receive a JWT

GraphiQL playground is available at `GET /graphiql`.

Signup mutation:
```bash
curl -X POST https://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation Signup($input: StudentGraphQLCreateInput!) { signup(input: $input) { id name email } }",
    "variables": {
      "input": {
        "name": "Graph User",
        "email": "graphql@example.com",
        "password": "password123"
      }
    }
  }'
```

Login mutation:
```bash
curl -X POST https://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation Login($input: StudentGraphQLLoginInput!) { login(input: $input) { token user { id name email } } }",
    "variables": {
      "input": {
        "email": "graphql@example.com",
        "password": "password123"
      }
    }
  }'
```

Students query:
```bash
curl -X POST https://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{ students { id name email phoneNumber dob } }"
  }'
```
query All studends Data:
curl -X POST https://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{"query": "{ students { id name email } }"}'

Response:
{"data":{"students":[{"name":"Nisha R K","email":"nishark@rnss.com","id":"0722684C-2EE2-4659-9968-559EFB9D831D"},{"name":"Sasvath R N","email":"sasavathrn@iitm.com","id":"09C99B17-C79F-46E2-823A-36BC36E0EC3F"},{"name":"Rajesh Mani","email":"rajeshm@graphql.com","id":"1AA4ADC1-8DBF-4D98-B00D-20EBDFD2E61E"},{"name":"HarithS","email":"harith@rnss.com","id":"231E8EE8-CA7B-400E-ADD9-6A35A38E3509"},{"name":"Rajesh","email":"rajesh@example.com","id":"309CBFDD-8B61-4D0C-A559-01A512DDC0BE"},{"name":"Graph User","email":"graphql@example.com","id":"33A6F8BD-2BB3-4C30-996A-DBDD95D39B6B"},{"name":"Saraswathy Mani","email":"saraswathy@rnss.com","id":"72C3D42B-BF45-4894-BD91-CCA5BAB526C6"},{"name":"Rajesh M","email":"rajeshmani@graphql.com","id":"7E254A89-2936-43CC-8860-A3F501F3BED1"},{"name":"SasvathRN","email":"sasvathrn@rnss.com","id":"964638F5-9B71-4A20-B638-05D859A910F6"},{"name":"Graph User","email":"graphql@graphql.com","id":"B1A1F06B-65B1-40AE-9FA0-4C3EBAED920E"},{"name":"Karthick Mani","email":"karthickmani@graphql.com","id":"B471EDCA-5904-4CE2-94A3-B86B7848184B"},{"name":"ShashanthRN","email":"shashanthrn@rnss.com","id":"D7B43550-17A2-4BFD-B87C-D924DF23ED9A"}]}}

Update student detail query:
curl -X POST https://localhost:8080/graphql \
  -H "Content-Type: application/json" \
  -d '{                                           
    "query": "mutation UpdateDob($input: StudentGraphQLUpdateInput!) { updateStudent(input: $input) { id name dob } }",
    "variables": {
      "input": {
        "id": "964638F5-9B71-4A20-B638-05D859A910F6",
        "dob": 286820400
      }
    }
  }'
  
Response:
{"data":{"updateStudent":{"id":"964638F5-9B71-4A20-B638-05D859A910F6","name":"SasvathRN","dob":286820400}}}%    

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
 mysql -u root -p -h 127.0.0.1 -P 3306
```
The -u flag specifies the user (root), and the -p flag prompts for the password.

Verify the connection: If successful, you'll see the MySQL prompt, where you can start executing SQL commands. To exit, type exit; and press Enter.

To Enable https
You need to re-generate the cert with CN=localhost:

    1. Generate a self-signed cert with CN=localhost.
    ```
    openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem -out cert.pem -days 365 \
    -subj "/CN=localhost"
    ```
  Then rebuild the .p12:
    ```
  openssl pkcs12 -export -out localhost.p12 \
  -inkey key.pem -in cert.pem \
  -name "Vapor Localhost Cert"
      ```
  
    2.    Import it into macOS Keychain:
    
        Open Keychain Access
    •    Drag cert.pem in
    •    Double-click → expand Trust → set “Always Trust”
    
    3.    Restart your Vapor app so it reloads certs
  
    4.    Test again after https enabled.
    
    curl https://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"rajesh@example.com","password":"password123"}'

    Now it should work without -k.
    
    
🚀 For Docker / Deployment

    •    If you’re deploying inside Docker on a real server, you shouldn’t use self-signed certs.
    •    Instead use Let’s Encrypt (certbot) or a trusted CA, so clients don’t need -k or special setup.
    •    You can also put Nginx or Caddy in front of your Vapor app to handle HTTPS automatically.
    
    
