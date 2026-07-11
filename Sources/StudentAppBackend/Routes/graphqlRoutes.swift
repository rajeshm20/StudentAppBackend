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
          <link rel="stylesheet" href="https://unpkg.com/graphiql/graphiql.min.css" />
        </head>
        <body style="margin: 0;">
          <div id="graphiql" style="height: 100vh;"></div>
          <script crossorigin src="https://unpkg.com/react/umd/react.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/react-dom/umd/react-dom.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/graphiql/graphiql.min.js"></script>
          <script>
            const fetcher = async (graphQLParams) => {
              const response = await fetch('\(endpoint)', {
                method: 'post',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(graphQLParams),
              });
              return response.json();
            };
            ReactDOM.render(
              React.createElement(GraphiQL, { fetcher }),
              document.getElementById('graphiql')
            );
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
