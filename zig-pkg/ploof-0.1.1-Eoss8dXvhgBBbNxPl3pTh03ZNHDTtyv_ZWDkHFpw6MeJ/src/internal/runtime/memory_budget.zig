const std = @import("std");

pub const Error = error{
    BackendNotLive,
    DecoderStackMissing,
    DecoderStackWithoutThreads,
    MemoryBudgetOverflow,
    WorkerCountZero,
};

pub const vm_page_bytes: u64 = std.heap.page_size_min;

pub const PerWorker = struct {
    worker_value_bytes: u64,
    storage_value_bytes: u64,
    backend_value_bytes: u64,
    storage_slab_bytes: u64,
    /// Included in storage_value_bytes; named for route-capacity review.
    route_search_workspace_bytes: u64 = 0,
    external_provided_buffer_bytes: u64,
    decoder_thread_count: u16 = 0,
    /// Requested stack sizes, not observable mapping lengths.
    decoder_requested_stack_bytes: u64 = 0,
    /// Guard, TLS, `std.Thread.Instance`, and mapping rounding remain unknown.
    decoder_thread_vm_overhead_unknown: bool = false,
    provided_buffer_descriptor_mapping_bytes: u64,
    provided_buffer_descriptor_mapping_vm_bytes: u64,
    io_uring_sq_cq_mapping_bytes: u64,
    io_uring_sq_cq_mapping_vm_bytes: u64,
    io_uring_sqe_mapping_bytes: u64,
    io_uring_sqe_mapping_vm_bytes: u64,
    caller_owned_bytes: u64,
    framework_mapping_bytes: u64,
    framework_mapping_vm_bytes: u64,
    /// Caller-owned bytes, exact mmap slice lengths, and requested decoder stacks.
    requested_total_bytes: u64,
    /// Exact known non-thread VM bytes; excludes all decoder thread mappings.
    total_bytes: u64,
};

pub const CallerOwned = struct {
    worker_value_bytes: u64,
    storage_value_bytes: u64,
    backend_value_bytes: u64,
    storage_slab_bytes: u64,
    /// Included in storage_value_bytes; named for route-capacity review.
    route_search_workspace_bytes: u64 = 0,
    external_provided_buffer_bytes: u64,
    decoder_thread_count: u16 = 0,
    /// Requested stack sizes, not observable mapping lengths.
    decoder_requested_stack_bytes: u64 = 0,
    /// Guard, TLS, `std.Thread.Instance`, and mapping rounding remain unknown.
    decoder_thread_vm_overhead_unknown: bool = false,
    /// Exact caller-owned bytes; requested thread stacks are reported separately.
    total_bytes: u64,
};

pub const Report = struct {
    worker_count: u16,
    per_worker: PerWorker,
    process_decoder_thread_count: u64 = 0,
    process_decoder_requested_stack_bytes: u64 = 0,
    /// Included in process_total_bytes through each Storage value.
    process_route_search_workspace_bytes: u64 = 0,
    /// Checked exact non-thread VM bytes; excludes all decoder thread mappings.
    process_total_bytes: u64,
};

/// Reports fixed caller-owned memory without initializing or allocating a backend.
pub fn callerOwned(
    comptime Worker: type,
    comptime Storage: type,
    comptime Backend: type,
) Error!CallerOwned {
    const worker_value_bytes: u64 = @sizeOf(Worker);
    const storage_value_bytes: u64 = @sizeOf(Storage);
    const backend_value_bytes: u64 = @sizeOf(Backend);
    const storage_slab_bytes: u64 = Storage.required_bytes;
    const route_search_workspace_bytes: u64 = if (@hasDecl(
        Storage,
        "route_search_workspace_bytes",
    )) Storage.route_search_workspace_bytes else 0;
    const external_buffer_bytes: u64 = Backend.external_provided_buffer_bytes;
    const decoder_thread_count: u16 = Storage.gzip_decoder_thread_count;
    const decoder_requested_stack_bytes: u64 =
        Storage.gzip_decoder_requested_stack_bytes;
    return .{
        .worker_value_bytes = worker_value_bytes,
        .storage_value_bytes = storage_value_bytes,
        .backend_value_bytes = backend_value_bytes,
        .storage_slab_bytes = storage_slab_bytes,
        .route_search_workspace_bytes = route_search_workspace_bytes,
        .external_provided_buffer_bytes = external_buffer_bytes,
        .decoder_thread_count = decoder_thread_count,
        .decoder_requested_stack_bytes = decoder_requested_stack_bytes,
        .decoder_thread_vm_overhead_unknown = decoder_thread_count != 0,
        .total_bytes = try sum(&.{
            worker_value_bytes,
            storage_value_bytes,
            backend_value_bytes,
            storage_slab_bytes,
            external_buffer_bytes,
        }),
    };
}

/// Reports every fixed worker-local region after the backend has mapped its ring.
pub fn report(
    comptime Worker: type,
    comptime Storage: type,
    comptime Backend: type,
    backend: *const Backend,
    worker_count: u16,
) Error!Report {
    if (worker_count == 0) return error.WorkerCountZero;
    const mappings = backend.memoryMappings() orelse return error.BackendNotLive;
    const fixed = try callerOwned(Worker, Storage, Backend);
    return checkedReport(.{
        .worker_value_bytes = fixed.worker_value_bytes,
        .storage_value_bytes = fixed.storage_value_bytes,
        .backend_value_bytes = fixed.backend_value_bytes,
        .storage_slab_bytes = fixed.storage_slab_bytes,
        .route_search_workspace_bytes = fixed.route_search_workspace_bytes,
        .external_provided_buffer_bytes = fixed.external_provided_buffer_bytes,
        .decoder_thread_count = fixed.decoder_thread_count,
        .decoder_requested_stack_bytes = fixed.decoder_requested_stack_bytes,
        .provided_buffer_descriptor_mapping_bytes = @intCast(
            mappings.provided_buffer_descriptors,
        ),
        .io_uring_sq_cq_mapping_bytes = @intCast(mappings.sq_cq),
        .io_uring_sqe_mapping_bytes = @intCast(mappings.sqes),
    }, worker_count);
}

const Components = struct {
    worker_value_bytes: u64,
    storage_value_bytes: u64,
    backend_value_bytes: u64,
    storage_slab_bytes: u64,
    route_search_workspace_bytes: u64 = 0,
    external_provided_buffer_bytes: u64,
    decoder_thread_count: u16,
    decoder_requested_stack_bytes: u64,
    provided_buffer_descriptor_mapping_bytes: u64,
    io_uring_sq_cq_mapping_bytes: u64,
    io_uring_sqe_mapping_bytes: u64,
};

fn checkedReport(components: Components, worker_count: u16) Error!Report {
    if (worker_count == 0) return error.WorkerCountZero;
    try validateDecoderStack(components);
    const per_worker = try checkedPerWorker(components);
    const process_decoder_requested_stack_bytes = std.math.mul(
        u64,
        components.decoder_requested_stack_bytes,
        worker_count,
    ) catch return error.MemoryBudgetOverflow;
    const process_total_bytes = std.math.mul(
        u64,
        per_worker.total_bytes,
        worker_count,
    ) catch return error.MemoryBudgetOverflow;
    const process_route_search_workspace_bytes = std.math.mul(
        u64,
        components.route_search_workspace_bytes,
        worker_count,
    ) catch return error.MemoryBudgetOverflow;
    return .{
        .worker_count = worker_count,
        .per_worker = per_worker,
        .process_decoder_thread_count = @as(u64, components.decoder_thread_count) *
            worker_count,
        .process_decoder_requested_stack_bytes = process_decoder_requested_stack_bytes,
        .process_route_search_workspace_bytes = process_route_search_workspace_bytes,
        .process_total_bytes = process_total_bytes,
    };
}

fn checkedPerWorker(components: Components) Error!PerWorker {
    const caller_owned_bytes = try sum(&.{
        components.worker_value_bytes,
        components.storage_value_bytes,
        components.backend_value_bytes,
        components.storage_slab_bytes,
        components.external_provided_buffer_bytes,
    });
    const mappings = try mappingTotals(components);
    const requested_total_bytes = try sum(&.{
        caller_owned_bytes,
        mappings.bytes,
        components.decoder_requested_stack_bytes,
    });
    const descriptor_mapping_bytes =
        components.provided_buffer_descriptor_mapping_bytes;
    return .{
        .worker_value_bytes = components.worker_value_bytes,
        .storage_value_bytes = components.storage_value_bytes,
        .backend_value_bytes = components.backend_value_bytes,
        .storage_slab_bytes = components.storage_slab_bytes,
        .route_search_workspace_bytes = components.route_search_workspace_bytes,
        .external_provided_buffer_bytes = components.external_provided_buffer_bytes,
        .decoder_thread_count = components.decoder_thread_count,
        .decoder_requested_stack_bytes = components.decoder_requested_stack_bytes,
        .decoder_thread_vm_overhead_unknown = components.decoder_thread_count != 0,
        .provided_buffer_descriptor_mapping_bytes = descriptor_mapping_bytes,
        .provided_buffer_descriptor_mapping_vm_bytes = mappings.descriptor_vm,
        .io_uring_sq_cq_mapping_bytes = components.io_uring_sq_cq_mapping_bytes,
        .io_uring_sq_cq_mapping_vm_bytes = mappings.sq_cq_vm,
        .io_uring_sqe_mapping_bytes = components.io_uring_sqe_mapping_bytes,
        .io_uring_sqe_mapping_vm_bytes = mappings.sqe_vm,
        .caller_owned_bytes = caller_owned_bytes,
        .framework_mapping_bytes = mappings.bytes,
        .framework_mapping_vm_bytes = mappings.vm_bytes,
        .requested_total_bytes = requested_total_bytes,
        .total_bytes = try sum(&.{ caller_owned_bytes, mappings.vm_bytes }),
    };
}

const MappingTotals = struct {
    bytes: u64,
    vm_bytes: u64,
    descriptor_vm: u64,
    sq_cq_vm: u64,
    sqe_vm: u64,
};

fn mappingTotals(components: Components) Error!MappingTotals {
    const descriptor_vm = try mappingVmBytes(
        components.provided_buffer_descriptor_mapping_bytes,
    );
    const sq_cq_vm = try mappingVmBytes(components.io_uring_sq_cq_mapping_bytes);
    const sqe_vm = try mappingVmBytes(components.io_uring_sqe_mapping_bytes);
    return .{
        .bytes = try sum(&.{
            components.provided_buffer_descriptor_mapping_bytes,
            components.io_uring_sq_cq_mapping_bytes,
            components.io_uring_sqe_mapping_bytes,
        }),
        .vm_bytes = try sum(&.{ descriptor_vm, sq_cq_vm, sqe_vm }),
        .descriptor_vm = descriptor_vm,
        .sq_cq_vm = sq_cq_vm,
        .sqe_vm = sqe_vm,
    };
}

fn validateDecoderStack(components: Components) Error!void {
    if (components.decoder_thread_count == 0 and
        components.decoder_requested_stack_bytes != 0)
    {
        return error.DecoderStackWithoutThreads;
    }
    if (components.decoder_thread_count != 0 and
        components.decoder_requested_stack_bytes == 0)
    {
        return error.DecoderStackMissing;
    }
}

fn mappingVmBytes(bytes: u64) Error!u64 {
    const remainder = bytes % vm_page_bytes;
    if (remainder == 0) return bytes;
    return std.math.add(
        u64,
        bytes,
        vm_page_bytes - remainder,
    ) catch return error.MemoryBudgetOverflow;
}

fn sum(values: []const u64) Error!u64 {
    var total: u64 = 0;
    for (values) |value| {
        total = std.math.add(u64, total, value) catch return error.MemoryBudgetOverflow;
    }
    return total;
}

test "memory report preserves exact fields and checked totals" {
    const result = try checkedReport(.{
        .worker_value_bytes = 1,
        .storage_value_bytes = 2,
        .backend_value_bytes = 3,
        .storage_slab_bytes = 4,
        .route_search_workspace_bytes = 2,
        .external_provided_buffer_bytes = 5,
        .decoder_thread_count = 2,
        .decoder_requested_stack_bytes = 9,
        .provided_buffer_descriptor_mapping_bytes = 6,
        .io_uring_sq_cq_mapping_bytes = 7,
        .io_uring_sqe_mapping_bytes = 8,
    }, 3);
    try std.testing.expectEqual(@as(u64, 15), result.per_worker.caller_owned_bytes);
    try std.testing.expectEqual(@as(u64, 21), result.per_worker.framework_mapping_bytes);
    try std.testing.expectEqual(
        3 * vm_page_bytes,
        result.per_worker.framework_mapping_vm_bytes,
    );
    try std.testing.expectEqual(@as(u16, 2), result.per_worker.decoder_thread_count);
    try std.testing.expectEqual(@as(u64, 9), result.per_worker.decoder_requested_stack_bytes);
    try std.testing.expect(result.per_worker.decoder_thread_vm_overhead_unknown);
    try std.testing.expectEqual(@as(u64, 45), result.per_worker.requested_total_bytes);
    try std.testing.expectEqual(
        15 + 3 * vm_page_bytes,
        result.per_worker.total_bytes,
    );
    try std.testing.expectEqual(@as(u64, 6), result.process_decoder_thread_count);
    try std.testing.expectEqual(@as(u64, 27), result.process_decoder_requested_stack_bytes);
    try std.testing.expectEqual(@as(u64, 2), result.per_worker.route_search_workspace_bytes);
    try std.testing.expectEqual(
        @as(u64, 6),
        result.process_route_search_workspace_bytes,
    );
    try std.testing.expectEqual(
        3 * (15 + 3 * vm_page_bytes),
        result.process_total_bytes,
    );
}

test "memory report rejects zero workers and every overflow boundary" {
    const one = Components{
        .worker_value_bytes = 1,
        .storage_value_bytes = 0,
        .backend_value_bytes = 0,
        .storage_slab_bytes = 0,
        .external_provided_buffer_bytes = 0,
        .decoder_thread_count = 0,
        .decoder_requested_stack_bytes = 0,
        .provided_buffer_descriptor_mapping_bytes = 0,
        .io_uring_sq_cq_mapping_bytes = 0,
        .io_uring_sqe_mapping_bytes = 0,
    };
    try std.testing.expectError(error.WorkerCountZero, checkedReport(one, 0));

    var stack_without_threads = one;
    stack_without_threads.decoder_requested_stack_bytes = 1;
    try std.testing.expectError(
        error.DecoderStackWithoutThreads,
        checkedReport(stack_without_threads, 1),
    );

    var stack_missing = one;
    stack_missing.decoder_thread_count = 1;
    try std.testing.expectError(error.DecoderStackMissing, checkedReport(stack_missing, 1));

    var field_overflow = one;
    field_overflow.worker_value_bytes = std.math.maxInt(u64);
    field_overflow.storage_value_bytes = 1;
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(field_overflow, 1),
    );

    var group_overflow = one;
    group_overflow.worker_value_bytes = std.math.maxInt(u64);
    group_overflow.provided_buffer_descriptor_mapping_bytes = 1;
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(group_overflow, 1),
    );

    var stack_sum_overflow = one;
    stack_sum_overflow.worker_value_bytes = std.math.maxInt(u64);
    stack_sum_overflow.decoder_thread_count = 1;
    stack_sum_overflow.decoder_requested_stack_bytes = 1;
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(stack_sum_overflow, 1),
    );

    var mapping_round_overflow = one;
    mapping_round_overflow.worker_value_bytes = 0;
    mapping_round_overflow.provided_buffer_descriptor_mapping_bytes =
        std.math.maxInt(u64);
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(mapping_round_overflow, 1),
    );

    var process_overflow = one;
    process_overflow.worker_value_bytes = std.math.maxInt(u64);
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(process_overflow, 2),
    );

    var route_process_overflow = one;
    route_process_overflow.route_search_workspace_bytes = std.math.maxInt(u64);
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(route_process_overflow, 2),
    );

    var stack_process_overflow = one;
    stack_process_overflow.decoder_thread_count = 1;
    stack_process_overflow.decoder_requested_stack_bytes = std.math.maxInt(u64) / 2 + 1;
    try std.testing.expectError(
        error.MemoryBudgetOverflow,
        checkedReport(stack_process_overflow, 2),
    );
}
