using AgentBench.Core;

var challenge = args.SingleOrDefault() ?? throw new ArgumentException("Provide challenge name");
static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

var data = new Ticket[]
{
    new(1, "One", "open"), new(2, "Two", "closed"), new(3, "Three", "open"),
    new(4, "Four", "closed"), new(5, "Five", "open")
};
var repo = new RecordingRepository(data);
var service = new TicketService(repo);

switch (challenge)
{
    case "pagination":
        var first = await service.ListAsync(1, 2);
        Check(first.TotalCount == 5 && first.Items.Select(t => t.Id).SequenceEqual([1, 2]), "Page 1 must have IDs 1,2 and total 5");
        Check((await service.ListAsync(2, 2)).Items.Select(t => t.Id).SequenceEqual([3, 4]), "Page 2 must have IDs 3,4");
        Check((await service.ListAsync(3, 2)).Items.Select(t => t.Id).SequenceEqual([5]), "Page 3 must have ID 5");
        Check((await service.ListAsync(4, 2)).Items.Count == 0, "Out-of-range page must be empty");
        Check((await service.ListAsync(1, 100)).Items.Count == 5, "Large allowed page size must work");
        await ExpectThrows(() => service.ListAsync(0, 2));
        await ExpectThrows(() => service.ListAsync(1, 0));
        await ExpectThrows(() => service.ListAsync(1, 101));
        break;
    case "cancellation":
        using (var cts = new CancellationTokenSource())
        {
            await service.ListAsync(1, 2, cancellationToken: cts.Token);
            Check(repo.LastToken == cts.Token, "Pass the caller's token to repository");
            cts.Cancel();
            await ExpectThrows(() => service.ListAsync(1, 2, cancellationToken: cts.Token));
        }
        break;
    case "filter":
        var open = await service.ListAsync(1, 2, "open");
        Check(open.TotalCount == 3 && open.Items.Select(t => t.Id).SequenceEqual([1, 3]), "Filter before paging/counting");
        Check((await service.ListAsync(2, 2, "open")).Items.Select(t => t.Id).SequenceEqual([5]), "Filtered page 2");
        Check((await service.ListAsync(1, 10, "OPEN")).TotalCount == 3, "Case-insensitive status");
        Check((await service.ListAsync(1, 10, "missing")).TotalCount == 0, "Unmatched status");
        Check((await service.ListAsync(1, 10)).TotalCount == 5, "No filter preserves all tickets");
        break;
    default: throw new ArgumentException($"Unknown challenge: {challenge}");
}
Console.WriteLine($"PASS: {challenge}");

static async Task ExpectThrows(Func<Task> action)
{
    try { await action(); }
    catch (ArgumentOutOfRangeException) { return; }
    catch (OperationCanceledException) { return; }
    throw new Exception("Expected exception was not raised");
}

sealed class RecordingRepository(IReadOnlyList<Ticket> data) : ITicketRepository
{
    public CancellationToken LastToken { get; private set; }
    public Task<IReadOnlyList<Ticket>> GetAllAsync(CancellationToken token)
    {
        LastToken = token;
        token.ThrowIfCancellationRequested();
        return Task.FromResult(data);
    }
}
