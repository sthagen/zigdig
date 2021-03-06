// DNS RDATA understanding (parsing etc)
const std = @import("std");
const io = std.io;

const types = @import("types.zig");
const packet = @import("packet.zig");
const err = @import("error.zig");

const DNSError = err.DNSError;
const InError = io.SliceInStream.Error;
const OutError = io.SliceOutStream.Error;
const DNSType = types.DNSType;

pub const SOAData = struct {
    mname: packet.DNSName,
    rname: packet.DNSName,
    serial: u32,
    refresh: u32,
    retry: u32,
    expire: u32,
    minimum: u32,
};

pub const MXData = struct {
    preference: u16,
    exchange: packet.DNSName,
};

/// DNS RDATA representation to a "native-r" type for nicer usage.
pub const DNSRData = union(types.DNSType) {
    A: std.net.IpAddress,
    AAAA: std.net.IpAddress,

    NS: packet.DNSName,
    MD: packet.DNSName,
    MF: packet.DNSName,
    CNAME: packet.DNSName,
    SOA: SOAData,

    MB: packet.DNSName,
    MG: packet.DNSName,
    MR: packet.DNSName,

    // ????
    NULL: void,

    // TODO WKS bit map
    WKS: struct {
        addr: u32,
        proto: u8,
        // how to define bit map? align(8)?
    },
    PTR: packet.DNSName,
    HINFO: struct {
        cpu: []const u8,
        os: []const u8,
    },
    MINFO: struct {
        rmailbx: packet.DNSName,
        emailbx: packet.DNSName,
    },
    MX: MXData,
    TXT: [][]const u8,
};

/// Parse a given OpaqueDNSRData into a DNSRData. Requires the original
/// DNSPacket for allocator purposes and the original DNSResource for
/// TYPE detection.
pub fn parseRData(
    pkt_const: packet.DNSPacket,
    resource: packet.DNSResource,
    opaque: packet.OpaqueDNSRData,
) !DNSRData {
    var pkt = pkt_const;

    var opaque_val = opaque.value;
    var in = io.SliceInStream.init(opaque_val);
    var in_stream = &in.stream;
    var deserializer = packet.DNSDeserializer.init(in_stream);

    var rdata = switch (resource.rr_type) {
        .A => blk: {
            var ip4addr: [4]u8 = undefined;
            for (ip4addr) |_, i| {
                ip4addr[i] = try deserializer.deserialize(u8);
            }

            break :blk DNSRData{
                .A = std.net.IpAddress.initIp4(ip4addr, 0),
            };
        },
        .AAAA => blk: {
            var ip6_addr: [16]u8 = undefined;

            for (ip6_addr) |byte, i| {
                ip6_addr[i] = try deserializer.deserialize(u8);
            }

            break :blk DNSRData{
                .AAAA = std.net.IpAddress.initIp6(ip6_addr, 0, 0, 0),
            };
        },

        .NS => DNSRData{ .NS = try pkt.deserializeName(&deserializer) },
        .CNAME => DNSRData{ .CNAME = try pkt.deserializeName(&deserializer) },
        .PTR => DNSRData{ .PTR = try pkt.deserializeName(&deserializer) },
        .MX => blk: {
            break :blk DNSRData{
                .MX = MXData{
                    .preference = try deserializer.deserialize(u16),
                    .exchange = try pkt.deserializeName(&deserializer),
                },
            };
        },
        .MD => DNSRData{ .MD = try pkt.deserializeName(&deserializer) },
        .MF => DNSRData{ .MF = try pkt.deserializeName(&deserializer) },

        .SOA => blk: {
            var mname = try pkt.deserializeName(&deserializer);
            var rname = try pkt.deserializeName(&deserializer);
            var serial = try deserializer.deserialize(u32);
            var refresh = try deserializer.deserialize(u32);
            var retry = try deserializer.deserialize(u32);
            var expire = try deserializer.deserialize(u32);
            var minimum = try deserializer.deserialize(u32);

            break :blk DNSRData{
                .SOA = SOAData{
                    .mname = mname,
                    .rname = rname,
                    .serial = serial,
                    .refresh = refresh,
                    .retry = retry,
                    .expire = expire,
                    .minimum = minimum,
                },
            };
        },

        else => blk: {
            std.debug.warn("invalid rdata type: {}\n", resource.rr_type);
            return DNSError.RDATANotSupported;
        },
    };

    return rdata;
}

/// Serialize a DNSName
fn serialName(serializer: var, name: packet.DNSName) !void {
    try serializer.serialize(name.labels.len);
    for (name.labels) |label| {
        try serializer.serialize(label);
    }
}

/// Serialize a given DNSRData into OpaqueDNSRData.
pub fn serializeRData(
    pkt: *packet.DNSPacket,
    rdata: DNSRData,
) !packet.OpaqueDNSRData {
    // TODO a nice idea would be to maybe implement a fixed buffer allocator
    // or a way for the serializer's underlying stream
    // to allocate memory on-demand?
    var buf = try allocator.alloc(u8, 1024);

    var out = io.SliceOutStream.init(buf);
    var out_stream = &out.stream;
    var serializer = std.io.Serializer(
        .Big,
        .Bit,
        std.io.OutError,
    ).init(out_stream);

    switch (rdata) {
        .NS => try serialName(serializer, rdata.NS),
        .MD => try serialName(serializer, rdata.MD),
        .MF => try serialName(serializer, rdata.MF),
        .MB => try serialName(serializer, rdata.MB),
        .MG => try serialName(serializer, rdata.MG),
        .MR => try serialName(serializer, rdata.MR),
        .CNAME => try serialName(serializer, rdata.CNAME),

        .SOA => |soa_data| blk: {
            try serialName(serializer, soa_data.mname);
            try serialName(serializer, soa_data.rname);

            try serializer.serialize(soa_data.serial);
            try serializer.serialize(soa_data.refresh);
            try serializer.serialize(soa_data.retry);
            try serializer.serialize(soa_data.expire);
            try serializer.serialize(soa_data.minimum);
        },

        .PTR => try serialName(serializer, rdata.PTR),

        .MX => |mxdata| blk: {
            try serializer.serialize(mxdata.preference);
            try serialName(serializer, mxdata.exchange);
        },

        else => return DNSError.RDATANotSupported,
    }
}

fn printName(
    stream: *std.io.OutStream(OutError),
    name: packet.DNSName,
) !void {
    // This doesn't use the name since we can just write to the stream.
    for (name.labels) |label| {
        try stream.print("{}", label);
        try stream.print(".");
    }
}

// This maybe should be provided by the standard library in the future.
fn strspn(s1: []const u8, s2: []const u8) usize {
    var bytes: usize = 0;

    while (bytes < s1.len and bytes + s2.len < s1.len) {
        if (std.mem.compare(
            u8,
            s1[bytes .. bytes + s2.len],
            s2,
        ) == std.mem.Compare.Equal) {
            bytes += s2.len;
        } else {
            break;
        }
    }

    return bytes;
}

test "strspn" {
    var val = "abcabc"[0..];
    std.testing.expectEqual(usize(6), strspn(val, "abc"));
    std.testing.expectEqual(usize(2), strspn(val, "ab"));
    std.testing.expectEqual(usize(6), strspn(":0:0:0:681b:bcb3:", ":0"));
}

/// Prettify a given DNSRData union variable. Returns a string with e.g
/// a string representation of an ipv4 address, or the human-readable version
/// of a DNSName.
pub fn prettyRData(allocator: *std.mem.Allocator, rdata: DNSRData) ![]const u8 {
    var minibuf = try allocator.alloc(u8, 256);

    var out = io.SliceOutStream.init(minibuf);
    var stream = &out.stream;

    switch (rdata) {
        .A, .AAAA => |addr| {
            try stream.print("{}", addr);
        },

        .CNAME => try printName(stream, rdata.CNAME),
        .NS => try printName(stream, rdata.NS),
        .PTR => try printName(stream, rdata.PTR),

        .MD => try printName(stream, rdata.MD),
        .MF => try printName(stream, rdata.MF),

        .SOA => |soa| blk: {
            try printName(stream, soa.mname);
            try stream.write(" ");
            try printName(stream, soa.rname);
            try stream.write(" ");

            try stream.print(
                "{} {} {} {} {}",
                soa.serial,
                soa.refresh,
                soa.retry,
                soa.expire,
                soa.minimum,
            );
            break :blk;
        },

        .MX => |mxdata| blk: {
            try stream.print("{} ", mxdata.preference);
            try printName(stream, mxdata.exchange);
        },

        else => try stream.write("unsupported rdata"),
    }

    return minibuf[0..];
}
