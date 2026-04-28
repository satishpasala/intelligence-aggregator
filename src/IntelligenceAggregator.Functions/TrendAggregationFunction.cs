using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntelligenceAggregator.Functions;

public sealed class TrendAggregationFunction
{
    private readonly ILogger<TrendAggregationFunction> _logger;

    public TrendAggregationFunction(ILogger<TrendAggregationFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(RunTrendAggregation))]
    public Task RunTrendAggregation([TimerTrigger("0 0 */2 * * *")] TimerInfo timerInfo, CancellationToken cancellationToken)
    {
        _logger.LogInformation("Trend aggregation started.");
        return Task.CompletedTask;
    }
}
