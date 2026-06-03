var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.MapGet("/", () => "ok from dotnet");
app.Run();
