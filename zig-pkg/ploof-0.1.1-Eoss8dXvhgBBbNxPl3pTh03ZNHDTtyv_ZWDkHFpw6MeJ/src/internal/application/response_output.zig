const std = @import("std");
const application_context = @import("../../application/context.zig");
const response = @import("../../response.zig");
const response_gzip = @import("../../response/gzip.zig");
const application_chunk_output = @import("chunk_output.zig");
const application_response_gzip = @import("response_gzip.zig");
const application_response_chunks = @import("response_chunks.zig");
const application_serialization = @import("serialization.zig");
const gzip_encoder = @import("../runtime/gzip/encoder.zig");
const response_chunk_chain = @import("../response/chunk_chain.zig");
const response_framing = @import("../http1/response_framing.zig");
const response_transfer = @import("../http1/response_transfer.zig");

pub const Error = application_response_gzip.Error;

pub const CodingOutcome = enum(u8) {
    identity_disabled,
    application_content_encoding,
    skipped_ineligible,
    skipped_bodyless_status,
    skipped_bodyless,
    identity_below_threshold,
    identity_negotiated,
    identity_capacity_fallback,
    gzip,
    not_acceptable,
    capacity_unavailable,
    compression_failed,
};

pub const StreamTransmission = struct {
    framing: response_framing.Plan,
    trailers: response_transfer.TrailerPlan,
};

pub const Transmission = union(enum) {
    finite,
    stream: StreamTransmission,
};

pub const FiniteChain = struct {
    head: []const u8,
    body: response_chunk_chain.Chain,
};

pub const BorrowedStatic = struct {
    head: []const u8,
    body: []const u8,
};

pub const LiveStaticPath = union(enum) {
    directory: struct {
        relative_path: []const u8,
        trailing_slash: bool,
        index_name: ?[]const u8,
    },
    file: []const u8,
};

pub const LiveStaticIntent = struct {
    input: application_context.Input,
    route_id: u16,
    root_index: u16,
    path: LiveStaticPath,
};

pub const LiveStaticFile = struct {
    head: []const u8,
    offset: u64,
    length: u64,
    transfer_body: bool,
};

pub const Source = union(enum) {
    contiguous_wire: []const u8,
    finite_chain: FiniteChain,
    borrowed_static: BorrowedStatic,
    live_static: LiveStaticIntent,
    live_static_file: LiveStaticFile,
};

pub const Prepared = struct {
    source: Source,
    bytes: []const u8,
    status: response.Status,
    close_connection: bool,
    coding_outcome: CodingOutcome,
    transmission: Transmission = .finite,
};

pub const frameworkBytesRequired = application_response_gzip.frameworkBytesRequired;

pub fn Configured(
    comptime enabled: bool,
    comptime framework_limits: response.HeadLimits,
    comptime options: response_gzip.ResponseGzip,
) type {
    return struct {
        pub const Workspace = if (enabled) gzip_encoder.Workspace else struct {};
        pub const Binding = if (enabled) struct {
            workspace: ?*Workspace = null,

            pub fn bind(self: *@This(), workspace: *Workspace) void {
                std.debug.assert(self.workspace == null);
                self.workspace = workspace;
            }

            pub fn clear(self: *@This()) void {
                self.workspace = null;
            }

            pub fn get(self: *const @This()) ?*Workspace {
                return self.workspace;
            }
        } else struct {
            pub fn bind(_: *@This(), _: *Workspace) void {}

            pub fn clear(_: *@This()) void {}

            pub fn get(_: *const @This()) ?*Workspace {
                return null;
            }
        };
        pub const RequestBinding = if (enabled)
            application_response_gzip.RequestFields
        else
            struct {};

        pub fn bind(input: anytype, cors_storage: anytype) RequestBinding {
            if (comptime !enabled) return .{};
            return .{
                .method = input.method,
                .accept_encoding = input.accept_encoding,
                .accepts_response_trailers = input.accepts_response_trailers,
                .date = input.date,
                .connection_close = input.connection_close,
                .cors_fields = application_context.storedCorsFields(cors_storage),
            };
        }

        pub fn serialize(
            comptime selected_limits: response.HeadLimits,
            value: anytype,
            application_workspace: anytype,
            input: anytype,
            cors_storage: anytype,
            output: []u8,
            workspace: ?*Workspace,
            server_identity: anytype,
        ) Error!Prepared {
            const cors_fields = application_context.storedCorsFields(cors_storage);
            if (comptime typeHasField(
                @TypeOf(application_workspace.*),
                "response_head_bytes",
            )) {
                if (value.body.isExternal()) {
                    const prepared = try application_serialization.serialize(
                        selected_limits,
                        application_workspace,
                        input,
                        cors_fields,
                        output,
                        value,
                        server_identity,
                    );
                    return identityPrepared(prepared);
                }
            }
            if (comptime typeHasField(
                @TypeOf(application_workspace.*),
                "finite_output",
            )) {
                if (application_workspace.finite_output.get()) |bound| {
                    return serializeChunks(
                        selected_limits,
                        value,
                        application_workspace,
                        input,
                        cors_fields,
                        output,
                        workspace,
                        server_identity,
                        bound,
                    );
                }
            }
            const request = bind(input, cors_fields);
            if (comptime !enabled) {
                const prepared = try application_serialization.serialize(
                    selected_limits,
                    application_workspace,
                    input,
                    cors_fields,
                    output,
                    value,
                    server_identity,
                );
                return identityPrepared(prepared);
            }
            const prepared = try application_response_gzip.serialize(
                selected_limits,
                framework_limits,
                value,
                request,
                output,
                workspace,
                .{ .minimum_bytes = options.minimum_bytes, .level = options.level },
                server_identity,
            );
            return gzipPrepared(prepared);
        }

        pub fn serializeBorrowed(
            comptime selected_limits: response.HeadLimits,
            value: anytype,
            application_workspace: anytype,
            input: anytype,
            cors_storage: anytype,
            output: []u8,
            server_identity: anytype,
        ) Error!Prepared {
            const prepared = try application_serialization.serializeBorrowed(
                selected_limits,
                application_workspace,
                input,
                application_context.storedCorsFields(cors_storage),
                output,
                value,
                server_identity,
            );
            return .{
                .source = .{ .borrowed_static = .{
                    .head = prepared.head,
                    .body = prepared.body,
                } },
                .bytes = prepared.head,
                .status = prepared.status,
                .close_connection = prepared.close_connection,
                .coding_outcome = .identity_disabled,
            };
        }

        fn serializeChunks(
            comptime selected_limits: response.HeadLimits,
            value: anytype,
            application_workspace: anytype,
            input: anytype,
            cors_fields: anytype,
            output: []u8,
            workspace: ?*Workspace,
            server_identity: anytype,
            bound: *application_chunk_output.Bound,
        ) Error!Prepared {
            _ = application_workspace;
            const request = application_response_chunks.Request{
                .method = input.method,
                .accept_encoding = input.accept_encoding,
                .accepts_response_trailers = input.accepts_response_trailers,
                .date = input.date,
                .connection_close = input.connection_close,
                .cors_fields = cors_fields,
            };
            const gzip_workspace: ?*gzip_encoder.Workspace = if (comptime enabled)
                workspace
            else
                null;
            const prepared = switch (bound.failure) {
                .none => try application_response_chunks.serialize(
                    enabled,
                    selected_limits,
                    framework_limits,
                    options,
                    value,
                    request,
                    output,
                    bound.writer,
                    gzip_workspace,
                    server_identity,
                ),
                .rendering, .capacity => try application_response_chunks.writeFramework(
                    framework_limits,
                    request,
                    output,
                    server_identity,
                    if (bound.failure == .capacity)
                        .service_unavailable
                    else
                        .internal_server_error,
                    bound.failure == .capacity,
                    if (bound.failure == .capacity)
                        .capacity_unavailable
                    else
                        .compression_failed,
                ),
            };
            return chunkPrepared(prepared);
        }
    };
}

fn typeHasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, name),
        else => false,
    };
}

fn chunkPrepared(prepared: application_response_chunks.Prepared) Prepared {
    return .{
        .source = .{ .finite_chain = .{
            .head = prepared.head,
            .body = prepared.body,
        } },
        .bytes = "",
        .status = prepared.status,
        .close_connection = prepared.close_connection,
        .coding_outcome = @enumFromInt(@intFromEnum(prepared.coding_outcome)),
    };
}

fn identityPrepared(prepared: application_serialization.Prepared) Prepared {
    return .{
        .source = .{ .contiguous_wire = prepared.bytes },
        .bytes = prepared.bytes,
        .status = prepared.status,
        .close_connection = prepared.close_connection,
        .coding_outcome = .identity_disabled,
    };
}

fn gzipPrepared(prepared: application_response_gzip.Prepared) Prepared {
    return .{
        .source = .{ .contiguous_wire = prepared.bytes },
        .bytes = prepared.bytes,
        .status = prepared.status,
        .close_connection = prepared.close_connection,
        .coding_outcome = switch (prepared.coding_outcome) {
            .application_content_encoding => .application_content_encoding,
            .skipped_ineligible => .skipped_ineligible,
            .skipped_bodyless_status => .skipped_bodyless_status,
            .skipped_bodyless => .skipped_bodyless,
            .identity_below_threshold => .identity_below_threshold,
            .identity_negotiated => .identity_negotiated,
            .identity_capacity_fallback => .identity_capacity_fallback,
            .gzip => .gzip,
            .not_acceptable => .not_acceptable,
            .capacity_unavailable => .capacity_unavailable,
            .compression_failed => .compression_failed,
        },
    };
}
