@preconcurrency import Graphiti
@preconcurrency import GraphQL
import Vapor

func registerGraphQLRoutes(_ app: Application) throws {
    let api = try StudentGraphQLAPI()

    app.post("graphql") { req async throws -> Response in
        let graphQLRequest = try req.content.decode(GraphQLRequestBody.self).graphQLRequest()
        let result = try await api.execute(
            request: graphQLRequest,
            context: req,
            on: req.application.eventLoopGroup
        )

        let response = Response(status: .ok)
        response.headers.contentType = .json
        response.body = .init(data: try JSONEncoder().encode(result))
        return response
    }

    app.get("graphiql") { _ in
        GraphiQLPage.html(endpoint: "/graphql")
    }
}

enum GraphiQLPage {
    static func html(endpoint: String) -> Response {
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              <title>Student API GraphiQL</title>
              <link rel="stylesheet" href="https://unpkg.com/graphiql@3/graphiql.min.css" />
              <style>
                html, body {
                  margin: 0;
                  height: 100%;
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                }
                #header {
                  display: flex;
                  align-items: center;
                  justify-content: space-between;
                  padding: 10px 16px;
                  background: #1a1a2e;
                  color: #fff;
                  box-sizing: border-box;
                }
                #header h1 {
                  font-size: 15px;
                  margin: 0;
                  font-weight: 600;
                }
                #header .endpoint {
                  font-size: 12px;
                  opacity: 0.7;
                }
                #header nav {
                  display: flex;
                  gap: 8px;
                }
                #header nav button {
                  background: transparent;
                  border: 1px solid rgba(255,255,255,0.3);
                  color: #fff;
                  padding: 5px 12px;
                  border-radius: 6px;
                  font-size: 12px;
                  cursor: pointer;
                }
                #header nav button.active {
                  background: #4f5df0;
                  border-color: #4f5df0;
                }
                #graphiql {
                  height: calc(100vh - 44px);
                }
                #docs {
                  height: calc(100vh - 44px);
                  overflow-y: auto;
                  box-sizing: border-box;
                  padding: 24px 32px 60px;
                  display: none;
                  background: #fafafa;
                  color: #1a1a2e;
                }
                #docs.visible {
                  display: block;
                }
                #docs h2 {
                  font-size: 20px;
                  margin: 0 0 6px;
                }
                #docs .lede {
                  color: #555;
                  margin: 0 0 20px;
                }
                #docs h3 {
                  font-size: 15px;
                  margin: 28px 0 10px;
                  padding-bottom: 6px;
                  border-bottom: 1px solid #e0e0e0;
                }
                #docs code.inline {
                  background: #eef0fb;
                  color: #3a3fa0;
                  padding: 2px 6px;
                  border-radius: 4px;
                  font-size: 13px;
                }
                #docs ul {
                  margin: 0 0 8px;
                  padding-left: 20px;
                }
                #docs li {
                  margin-bottom: 6px;
                  font-size: 13.5px;
                  line-height: 1.5;
                }
                #docs .card {
                  background: #fff;
                  border: 1px solid #e5e5e5;
                  border-radius: 8px;
                  padding: 16px 18px;
                  margin-bottom: 18px;
                }
                #docs .card h4 {
                  margin: 0 0 10px;
                  font-size: 13px;
                  text-transform: uppercase;
                  letter-spacing: 0.04em;
                  color: #4f5df0;
                }
                #docs pre {
                  background: #1a1a2e;
                  color: #e6e6f0;
                  padding: 14px 16px;
                  border-radius: 6px;
                  overflow-x: auto;
                  font-size: 12.5px;
                  line-height: 1.5;
                  margin: 0 0 4px;
                }
                #docs .label {
                  font-size: 11px;
                  text-transform: uppercase;
                  letter-spacing: 0.05em;
                  color: #888;
                  margin: 12px 0 6px;
                }
              </style>
            </head>
            <body>
              <div id="header">
                <h1>Student API · GraphiQL</h1>
                <nav>
                  <button id="tab-playground" class="active" onclick="showTab('playground')">Playground</button>
                  <button id="tab-docs" onclick="showTab('docs')">Docs</button>
                </nav>
                <span class="endpoint">\(endpoint)</span>
              </div>

              <div id="graphiql"></div>

              <div id="docs">
                <h2>GraphQL</h2>
                <p class="lede">This project now exposes GraphQL at <code class="inline">POST /graphql</code> alongside the existing REST auth APIs.</p>

                <h3>Available operations</h3>
                <ul>
                  <li><code class="inline">students</code> — fetch all students</li>
                  <li><code class="inline">student(id: UUID!)</code> — fetch one student</li>
                  <li><code class="inline">signup(input: StudentGraphQLCreateInput!)</code> — create a student</li>
                  <li><code class="inline">login(input: StudentGraphQLLoginInput!)</code> — authenticate and receive a JWT</li>
                </ul>
                <p style="font-size: 13.5px; color: #555;">GraphiQL playground is available at <code class="inline">GET /graphiql</code>.</p>

                <h3>Examples</h3>

                <div class="card">
                  <h4>Signup mutation</h4>
            <pre><code>curl -X POST http://localhost:8080/graphql \\
            -H "Content-Type: application/json" \\
              -d '{
                "query": "mutation Signup($input: StudentGraphQLCreateInput!) { signup(input: $input) { id name email } }",
                "variables": {
                  "input": {
                    "name": "Graph User",
                    "email": "graphql@example.com",
                    "password": "password123"
                  }
                }
              }'</code></pre>
                </div>

                <div class="card">
                  <h4>Login mutation</h4>
                  <pre><code>curl -X POST http://localhost:8080/graphql \\\\
              -H "Content-Type: application/json" \\\\
              -d '{
                "query": "mutation Login($input: StudentGraphQLLoginInput!) { login(input: $input) { token user { id name email } } }",
                "variables": {
                  "input": {
                    "email": "graphql@example.com",
                    "password": "password123"
                  }
                }
              }'</code></pre>
                </div>

                <div class="card">
                  <h4>Students query</h4>
                  <pre><code>curl -X POST http://localhost:8080/graphql \\\\
              -H "Content-Type: application/json" \\\\
              -d '{
                "query": "{ students { id name email phoneNumber dob } }"
              }'</code></pre>

                  <div class="label">All students (short form)</div>
                  <pre><code>curl -X POST http://localhost:8080/graphql \\\\
              -H "Content-Type: application/json" \\\\
              -d '{"query": "{ students { id name email } }"}'</code></pre>

                  <div class="label">Response</div>
                  <pre><code>{"data":{"students":[{"name":"Nisha R K","email":"nishark@rnss.com","id":"0722684C-2EE2-4659-9968-559EFB9D831D"},{"name":"Sasvath R N","email":"sasavathrn@iitm.com","id":"09C99B17-C79F-46E2-823A-36BC36E0EC3F"}, ...]}}</code></pre>
                </div>

                <div class="card">
                  <h4>Update student mutation</h4>
                  <pre><code>curl -X POST http://localhost:8080/graphql \\\\
              -H "Content-Type: application/json" \\\\
              -d '{
                "query": "mutation UpdateDob($input: StudentGraphQLUpdateInput!) { updateStudent(input: $input) { id name dob } }",
                "variables": {
                  "input": {
                    "id": "964638F5-9B71-4A20-B638-05D859A910F6",
                    "dob": 286820400
                  }
                }
              }'</code></pre>

                  <div class="label">Response</div>
                  <pre><code>{"data":{"updateStudent":{"id":"964638F5-9B71-4A20-B638-05D859A910F6","name":"SasvathRN","dob":286820400}}}</code></pre>
                </div>
              </div>

             <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
             <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
             <script crossorigin src="https://unpkg.com/graphiql@3.0.6/graphiql.min.js"></script>
             <script>
               try {
                 if (typeof React === 'undefined') throw new Error('React failed to load from CDN');
                 if (typeof ReactDOM === 'undefined') throw new Error('ReactDOM failed to load from CDN');
                 if (typeof GraphiQL === 'undefined') throw new Error('GraphiQL failed to load from CDN');

                 const fetcher = GraphiQL.createFetcher({ url: '\(endpoint)' });

                 const defaultQuery = `# Welcome to the Student API
             #
             # Try running a query, e.g.:
             #
             # { students { id name email } }
             `;

                 const root = ReactDOM.createRoot(document.getElementById('graphiql'));
                 root.render(React.createElement(GraphiQL, { fetcher, defaultQuery }));
               } catch (err) {
                 document.getElementById('graphiql').innerHTML =
                   '<div style="padding:24px;font-family:monospace;color:#c0392b;">' +
                   'GraphiQL failed to load: ' + err.message +
                   '<br><br>Check the browser console / network tab for blocked requests (CDN, CSP, ad blocker).' +
                   '</div>';
                 console.error(err);
               }

               function showTab(tab) {
                 const graphiqlEl = document.getElementById('graphiql');
                 const docsEl = document.getElementById('docs');
                 const tabPlayground = document.getElementById('tab-playground');
                 const tabDocs = document.getElementById('tab-docs');

                 if (tab === 'docs') {
                   graphiqlEl.style.display = 'none';
                   docsEl.classList.add('visible');
                   tabDocs.classList.add('active');
                   tabPlayground.classList.remove('active');
                 } else {
                   graphiqlEl.style.display = 'block';
                   docsEl.classList.remove('visible');
                   tabPlayground.classList.add('active');
                   tabDocs.classList.remove('active');
                 }
               }
             </script>
            </body>
            </html>
            """

            let response = Response(status: .ok)
            response.headers.contentType = .html
            response.body = .init(string: html)
            return response
        }
}
