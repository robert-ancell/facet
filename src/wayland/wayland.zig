//! Wayland wire protocol, protocol interface definitions, and client library.

pub const wire = @import("wire.zig");
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");

test {
    _ = wire;
    _ = protocol;
    _ = client;
}
