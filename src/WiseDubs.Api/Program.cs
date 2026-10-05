using Npgsql;

var password = Environment.GetEnvironmentVariable("DB_PASSWORD");
if (string.IsNullOrWhiteSpace(password) || password == "CHANGE_ME")
{
    Console.Error.WriteLine("Configuration unavailable: set DB_PASSWORD locally.");
    return 1;
}

var connection = new NpgsqlConnectionStringBuilder
{
    Host = "db",
    Port = 5432,
    Database = "wisedubs",
    Username = "wisedubs",
    Password = password,
    Timeout = 2,
    CommandTimeout = 2,
    CancellationTimeout = -1,
    MaxPoolSize = 10,
    IncludeErrorDetail = false,
    LogParameters = false,
    GssEncryptionMode = GssEncryptionMode.Disable
};

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(options =>
{
    options.SingleLine = true;
    options.UseUtcTimestamp = true;
    options.TimestampFormat = "yyyy-MM-ddTHH:mm:ssZ ";
});
builder.Logging.AddFilter("Microsoft", LogLevel.None);
builder.Logging.AddFilter("Npgsql", LogLevel.None);
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(connection.ConnectionString));

var app = builder.Build();
app.MapGet("/health", async (HttpContext context, NpgsqlDataSource dataSource) =>
{
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
    deadline.CancelAfter(TimeSpan.FromSeconds(3));
    try
    {
        if (!await CheckDatabaseAsync(dataSource, deadline.Token).WaitAsync(deadline.Token))
        {
            throw new InvalidOperationException();
        }

        app.Logger.LogInformation("operation=health result=ready request_id={RequestId}", context.TraceIdentifier);
        context.Response.Headers.CacheControl = "no-store";
        return Results.Json(new { status = "ready" });
    }
    catch (Exception)
    {
        app.Logger.LogWarning("operation=health result=unavailable request_id={RequestId}", context.TraceIdentifier);
        context.Response.Headers.CacheControl = "no-store";
        return Results.Json(new { status = "unavailable" }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.Logger.LogInformation("operation=start result=ready_to_listen");
await app.RunAsync();
return 0;

static async Task<bool> CheckDatabaseAsync(NpgsqlDataSource source, CancellationToken cancellationToken)
{
    try
    {
        await using var command = source.CreateCommand("SELECT 1");
        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is int value && value == 1;
    }
    catch (Exception)
    {
        return false;
    }
}
