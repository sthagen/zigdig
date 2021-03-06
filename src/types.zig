// DNS QTYPE

const std = @import("std");
const err = @import("error.zig");
const DNSError = err.DNSError;

pub const DNSType = enum(u16) {
    A = 1,
    NS,
    MD,
    MF,
    CNAME = 5,
    SOA,
    MB,
    MG,
    MR,
    NULL,
    WKS,
    PTR,
    HINFO,
    MINFO,
    MX,
    TXT,

    AAAA = 28,
    //LOC,
    //SRV,

    // QTYPE only, but merging under DNSType
    // for nicer API

    // TODO: add them back, maybe?
    //AXFR = 252,
    //MAILB,
    //MAILA,
    //WILDCARD,
};

pub const DNSClass = enum(u16) {
    IN = 1,
    CS,
    CH,
    HS,
    WILDCARD = 255,
};

/// Convert from a DNSClass to a friendly string
pub fn classToStr(class: DNSClass) []const u8 {
    var as_str = switch (class) {
        .IN => "IN",
        .CS => "CS",
        .CH => "CH",
        .HS => "HS",
        else => "unknown",
    };

    return as_str[0..];
}

fn toUpper(str: []const u8, out: []u8) void {
    for (str) |c, i| {
        out[i] = std.ascii.toUpper(c);
    }
}

/// Convert a given string to an integer representing a DNSType.
pub fn strToType(str: []const u8) !u16 {
    var uppercased: [16]u8 = [_]u8{0} ** 16;
    toUpper(str, uppercased[0..]);

    var to_compare: [16]u8 = undefined;
    const type_info = @typeInfo(DNSType).Enum;

    inline for (type_info.fields) |field| {
        std.mem.copy(u8, to_compare[0..], field.name);

        // we have to secureZero here because a previous comparison
        // might have used those zero bytes for itself.
        std.mem.secureZero(u8, to_compare[field.name.len..]);

        if (std.mem.eql(u8, uppercased, to_compare)) {
            return field.value;
        }
    }

    return DNSError.UnknownDNSType;
}

/// Convert a DNSType u16 into a string representing it.
pub fn typeToStr(qtype: u16) []const u8 {
    const type_info = @typeInfo(DNSType).Enum;
    var as_dns_type = @intToEnum(DNSType, qtype);

    inline for (type_info.fields) |field| {
        if (field.value == qtype) {
            return field.name;
        }
    }

    return "<unknown>";
}
