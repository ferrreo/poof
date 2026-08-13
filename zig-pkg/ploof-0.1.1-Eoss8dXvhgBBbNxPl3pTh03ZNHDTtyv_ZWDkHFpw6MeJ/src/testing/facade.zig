const ploof = @import("ploof");

pub const version = ploof.version;
pub const Options = ploof.__testingOptions();
pub const Request = ploof.__testingRequest();
pub const Header = Request.Header;
pub const ClientError = ploof.__testingClientError();
pub const Response = ploof.__testingResponse();

pub fn Client(comptime App: type) type {
    return ploof.__testingClient(App);
}

pub fn ConfiguredClient(comptime App: type, comptime options: Options) type {
    return ploof.__testingConfiguredClient(App, options);
}
