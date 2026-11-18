namespace AgentBench.Core;

public sealed record Ticket(int Id, string Title, string Status);
public sealed record TicketPage(IReadOnlyList<Ticket> Items, int TotalCount, int Page, int PageSize);

public interface ITicketRepository
{
    Task<IReadOnlyList<Ticket>> GetAllAsync(CancellationToken cancellationToken);
}

public sealed class TicketService(ITicketRepository repository)
{
    public async Task<TicketPage> ListAsync(
        int page, int pageSize, string? status = null, CancellationToken cancellationToken = default)
    {
        if (page < 1) throw new ArgumentOutOfRangeException(nameof(page));
        if (pageSize < 1 || pageSize > 100) throw new ArgumentOutOfRangeException(nameof(pageSize));

        var all = await repository.GetAllAsync(CancellationToken.None); // cancellation challenge
        var filtered = all; // filter challenge: apply optional status here before counting/paging
        var items = filtered.Skip(page * pageSize).Take(pageSize).ToArray(); // pagination challenge
        return new TicketPage(items, filtered.Count, page, pageSize);
    }
}

public sealed class InMemoryTicketRepository : ITicketRepository
{
    private static readonly IReadOnlyList<Ticket> Tickets = new[]
    {
        new Ticket(1, "First", "open"), new Ticket(2, "Second", "closed"),
        new Ticket(3, "Third", "open"), new Ticket(4, "Fourth", "closed"),
        new Ticket(5, "Fifth", "open")
    };

    public Task<IReadOnlyList<Ticket>> GetAllAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Tickets);
    }
}
