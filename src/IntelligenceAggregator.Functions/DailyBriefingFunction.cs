using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntelligenceAggregator.Functions;

public sealed class DailyBriefingFunction
{
    private readonly ILogger<DailyBriefingFunction> _logger;

    public DailyBriefingFunction(ILogger<DailyBriefingFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(RunDailyBriefing))]
    public Task RunDailyBriefing([TimerTrigger("0 0 7 * * *")] TimerInfo timerInfo, CancellationToken cancellationToken)
    {
        _logger.LogInformation("Daily briefing job started.");
        return Task.CompletedTask;
    }
}
