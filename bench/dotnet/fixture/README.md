# AgentBench ticket service

Build: `dotnet build AgentBench.slnx`. Run the API: `dotnet run --project src/AgentBench.Api`.
`GET /api/tickets?page=1&pageSize=20` lists tickets; `/health` reports readiness.
TicketService owns filtering and paging. The API is intentionally small; changes must keep the public API working.
The Docker build context is the solution root: `docker build -f src/AgentBench.Api/Dockerfile .`.
