const std = @import("std");
const json = @import("json");

test "valid json object" {
    try std.testing.expect(try json.valid(std.testing.allocator, "{\"a\":1}"));
}

test "valid json array" {
    try std.testing.expect(try json.valid(std.testing.allocator, "[1,true,null]"));
}

test "invalid json" {
    try std.testing.expect(!try json.valid(std.testing.allocator, "{invalid}"));
}

fn expectRecord(input: []const u8, key: []const u8, value: []const u8, typ: []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try json.decode(allocator, input);
    defer allocator.free(actual);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try appendB64(allocator, &expected, key);
    try expected.append(allocator, '\x1f');
    try appendB64(allocator, &expected, value);
    try expected.append(allocator, '\x1f');
    try expected.appendSlice(allocator, typ);
    try expected.append(allocator, '\x1e');

    try std.testing.expectEqualSlices(u8, expected.items, actual);
}

fn appendB64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = std.base64.standard.Encoder.encode(buf, bytes);
    try out.appendSlice(allocator, buf);
}

test "flattenValue emits base64 record with int type tag" {
    try expectRecord("{\"n\":1}", "n", "1", "int");
}

test "flattenValue emits float type for floating literal" {
    try expectRecord("{\"x\":1.5}", "x", "1.5", "float");
}

test "flattenValue emits string type for quoted value" {
    try expectRecord("{\"s\":\"hi\"}", "s", "hi", "string");
}

test "flattenValue emits bool and null type tags" {
    const allocator = std.testing.allocator;
    const actual = try json.decode(allocator, "{\"a\":true,\"b\":null}");
    defer allocator.free(actual);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try appendB64(allocator, &expected, "a");
    try expected.append(allocator, '\x1f');
    try appendB64(allocator, &expected, "true");
    try expected.append(allocator, '\x1f');
    try expected.appendSlice(allocator, "bool");
    try expected.append(allocator, '\x1e');
    try appendB64(allocator, &expected, "b");
    try expected.append(allocator, '\x1f');
    try appendB64(allocator, &expected, "");
    try expected.append(allocator, '\x1f');
    try expected.appendSlice(allocator, "null");
    try expected.append(allocator, '\x1e');

    try std.testing.expectEqualSlices(u8, expected.items, actual);
}

test "flattenValue roundtrips RS in value via base64" {
    try expectRecord("{\"k\":\"a\\u001eb\"}", "k", "a\x1eb", "string");
}

test "flattenValue roundtrips US in key via base64" {
    try expectRecord("{\"a\\u001fb\":\"v\"}", "a\x1fb", "v", "string");
}

test "flattenValue roundtrips ESC in value via base64" {
    try expectRecord("{\"k\":\"x\\u001by\"}", "k", "x\x1by", "string");
}

test "flattenValue keeps dot-path for nested object" {
    try expectRecord("{\"a\":{\"b\":1}}", "a.b", "1", "int");
}

test "flattenValue keeps dot-path for array index" {
    const allocator = std.testing.allocator;
    const actual = try json.decode(allocator, "{\"xs\":[10,20]}");
    defer allocator.free(actual);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try appendB64(allocator, &expected, "xs.0");
    try expected.append(allocator, '\x1f');
    try appendB64(allocator, &expected, "10");
    try expected.append(allocator, '\x1f');
    try expected.appendSlice(allocator, "int");
    try expected.append(allocator, '\x1e');
    try appendB64(allocator, &expected, "xs.1");
    try expected.append(allocator, '\x1f');
    try appendB64(allocator, &expected, "20");
    try expected.append(allocator, '\x1f');
    try expected.appendSlice(allocator, "int");
    try expected.append(allocator, '\x1e');

    try std.testing.expectEqualSlices(u8, expected.items, actual);
}
