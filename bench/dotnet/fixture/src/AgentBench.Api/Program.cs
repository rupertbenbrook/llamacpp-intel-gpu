using AgentBench.Core;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<ITicketRepository, InMemoryTicketRepository>();
builder.Services.AddScoped<TicketService>();
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapGet("/api/tickets", async (
    int? page, int? pageSize, TicketService service, CancellationToken cancellationToken) =>
{
    var result = await service.ListAsync(page ?? 1, pageSize ?? 20, cancellationToken: cancellationToken);
    return Results.Ok(result);
});

app.Run();
