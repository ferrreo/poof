pub fn State(comptime enabled: bool, comptime Input: type) type {
    if (!enabled) return struct {};
    return struct {
        route_id: u16 = 0,
        input: Input = undefined,
        mapped_error: bool = false,
    };
}

pub fn Configured(
    comptime enabled: bool,
    comptime Workspace: type,
    comptime Deferred: type,
    comptime MetricsResult: type,
    comptime Prepared: type,
    comptime PrepareError: type,
    comptime resume_metrics: fn (
        *Workspace,
        u16,
        MetricsResult,
        []u8,
    ) ?PrepareError!Prepared,
) type {
    return struct {
        pub fn resumeMetrics(
            workspace: *Workspace,
            deferred: Deferred,
            result: MetricsResult,
            output: []u8,
        ) PrepareError!Prepared {
            if (comptime !enabled) unreachable;
            if (workspace.lifecycle != .awaiting_metrics or
                workspace.metrics.route_id != deferred.route_id)
            {
                return error.NoPendingMetrics;
            }
            return resume_metrics(workspace, deferred.route_id, result, output) orelse
                error.NoPendingMetrics;
        }
    };
}
