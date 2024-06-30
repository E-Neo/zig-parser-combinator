const std = @import("std");

const Error = error.Fail;

fn Result(comptime T: type) type {
    return struct {
        head: T,
        tail: []const u8,
    };
}

pub fn Parser(comptime T: type) type {
    return struct {
        const R = T;
        parse: fn ([]const u8) anyerror!Result(R),
    };
}

pub fn string(comptime name: []const u8) Parser([]const u8) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result([]const u8) {
            if (!std.mem.startsWith(u8, input, name)) {
                return error.Fail;
            }
            return Result([]const u8){
                .head = input[0..name.len],
                .tail = input[name.len..],
            };
        }
    }.parse };
}

test "string" {
    const parse = string("abc").parse;
    try expectResult("abc", "d", parse("abcd"));
    try expectFail(parse("ab"));
}

fn parsersResults(comptime parsers: anytype) []const type {
    var results: []const type = &[_]type{};
    for (parsers) |parser| {
        results = results ++ [_]type{@TypeOf(parser).R};
    }
    return results;
}

fn SequenceResult(comptime parsers: anytype) type {
    return std.meta.Tuple(parsersResults(parsers));
}

pub fn sequence(comptime parsers: anytype) Parser(SequenceResult(parsers)) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(SequenceResult(parsers)) {
            var res: Result(SequenceResult(parsers)) = undefined;
            res.tail = input;
            comptime var i = 0;
            inline for (parsers) |parser| {
                if (parser.parse(res.tail)) |item| {
                    res.head[i] = item.head;
                    res.tail = item.tail;
                } else |err| {
                    return err;
                }
                i += 1;
            }
            return res;
        }
    }.parse };
}

test "sequence" {
    const parse = sequence(.{ string("ab"), string("c") }).parse;
    try expectResult(.{ "ab", "c" }, "d", parse("abcd"));
    try expectFail(parse("adc"));
    try expectFail(parse("ab"));
}

pub fn empty() Parser(void) {
    return .{ .parse = map(sequence(.{}), struct {
        fn f(_: anytype) !void {}
    }.f).parse };
}

test "empty" {
    const parse = empty().parse;
    try expectResult({}, "abc", parse("abc"));
}

pub fn choice(comptime parsers: anytype) Parser(@TypeOf(parsers[0]).R) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(@TypeOf(parsers[0]).R) {
            inline for (parsers) |parser| {
                if (parser.parse(input)) |res| {
                    return res;
                } else |err| switch (err) {
                    error.Fail => {},
                    else => return err,
                }
            }
            return error.Fail;
        }
    }.parse };
}

test "choice" {
    const parse = choice(.{ string("a"), string("b") }).parse;
    try expectResult("a", "c", parse("ac"));
    try expectResult("b", "c", parse("bc"));
    try expectFail(parse("cd"));
}

pub fn optional(comptime parser: anytype) Parser(?@TypeOf(parser).R) {
    return .{ .parse = choice(.{
        map(parser, struct {
            fn f(x: @TypeOf(parser).R) !?@TypeOf(parser).R {
                return x;
            }
        }.f),
        map(empty(), struct {
            fn f(_: void) !?@TypeOf(parser).R {
                return null;
            }
        }.f),
    }).parse };
}

test "optional" {
    const parse = optional(string("a")).parse;
    try expectResult("a", "b", parse("ab"));
    try expectResult(null, "b", parse("b"));
    try expectResult(null, "", parse(""));
}

fn ReturnType(comptime f: anytype) type {
    return switch (@typeInfo(@TypeOf(f))) {
        .Fn => |x| x.return_type.?,
        else => @compileError(@src().fn_name ++ ": " ++ @typeName(@TypeOf(f))),
    };
}

fn ReturnPayloadType(comptime f: anytype) type {
    return switch (@typeInfo(ReturnType(f))) {
        .ErrorUnion => |x| x.payload,
        else => @compileError(@src().fn_name ++ ": " ++ @typeName(@TypeOf(f))),
    };
}

pub fn foldZeroOrMore(
    comptime parser: anytype,
    comptime f: anytype,
    comptime init: fn () ReturnType(f),
) Parser(ReturnPayloadType(init)) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(ReturnPayloadType(init)) {
            var head = try init();
            var tail = input;
            while (true) {
                if (parser.parse(tail)) |res| {
                    head = try f(head, res.head);
                    tail = res.tail;
                } else |err| switch (err) {
                    error.Fail => break,
                    else => return err,
                }
            }
            return Result(ReturnPayloadType((init))){
                .head = head,
                .tail = tail,
            };
        }
    }.parse };
}

test "foldZeroOrMore" {
    const count = struct {
        fn f(acc: usize, x: []const u8) !usize {
            return acc + x.len;
        }
    }.f;
    const zero = struct {
        fn f() !usize {
            return 0;
        }
    }.f;
    const parse = foldZeroOrMore(string("ab"), count, zero).parse;
    try expectResult(6, "cd", parse("abababcd"));
    try expectResult(0, "cd", parse("cd"));
}

test "foldZeroOrMore with allocator" {
    const ArrayList = std.ArrayList([]const u8);
    const append = struct {
        fn f(lst: *ArrayList, item: []const u8) !*ArrayList {
            try lst.append(item);
            return lst;
        }
    }.f;
    const init = struct {
        var lst: ArrayList = undefined;
        fn f() !*ArrayList {
            lst = ArrayList.init(std.testing.allocator);
            return &lst;
        }
    }.f;
    const parse = foldZeroOrMore(string("ab"), append, init).parse;
    const res1 = try parse("ababcd");
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "ab", "ab" }),
        res1.head.items,
    );
    res1.head.deinit();
    const res2 = try parse("cd");
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{}),
        res2.head.items,
    );
    res2.head.deinit();
}

fn SomeOrMore(comptime foldParser: anytype) type {
    return struct {
        fn someOrMore(
            comptime allocator: std.mem.Allocator,
            comptime parser: anytype,
        ) Parser([]const @TypeOf(parser).R) {
            return .{ .parse = struct {
                const ArrayList = std.ArrayList(@TypeOf(parser).R);
                const append = struct {
                    fn f(lst: *ArrayList, item: @TypeOf(parser).R) !*ArrayList {
                        try lst.append(item);
                        return lst;
                    }
                }.f;
                const init = struct {
                    var lst: ArrayList = undefined;
                    fn f() !*ArrayList {
                        lst = ArrayList.init(allocator);
                        return &lst;
                    }
                }.f;
                const toSlice = struct {
                    fn f(lst: *ArrayList) ![]const @TypeOf(parser).R {
                        return lst.toOwnedSlice();
                    }
                }.f;
                const parse = map(
                    foldParser(parser, append, init),
                    toSlice,
                ).parse;
            }.parse };
        }
    };
}

pub const zeroOrMore = SomeOrMore(foldZeroOrMore).someOrMore;

test "zeroOrMore" {
    const parse = zeroOrMore(std.testing.allocator, string("ab")).parse;
    const res1 = try parse("ababcd");
    defer std.testing.allocator.free(res1.head);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "ab", "ab" }),
        res1.head,
    );
    const res2 = try parse("cd");
    defer std.testing.allocator.free(res2.head);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{}),
        res2.head,
    );
}

pub fn foldOneOrMore(
    comptime parser: anytype,
    comptime f: anytype,
    comptime init: fn () ReturnType(f),
) Parser(ReturnPayloadType(init)) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(ReturnPayloadType(init)) {
            const firstRes = try parser.parse(input);
            var head = try f(try init(), firstRes.head);
            var tail = firstRes.tail;
            while (true) {
                if (parser.parse(tail)) |res| {
                    head = try f(head, res.head);
                    tail = res.tail;
                } else |err| switch (err) {
                    error.Fail => break,
                    else => return err,
                }
            }
            return Result(ReturnPayloadType(init)){
                .head = head,
                .tail = tail,
            };
        }
    }.parse };
}

test "foldOneOrMore" {
    const count = struct {
        fn f(acc: usize, x: []const u8) !usize {
            return acc + x.len;
        }
    }.f;
    const zero = struct {
        fn f() !usize {
            return 0;
        }
    }.f;
    const parse = foldOneOrMore(string("ab"), count, zero).parse;
    try expectResult(4, "cd", parse("ababcd"));
}

pub const oneOrMore = SomeOrMore(foldOneOrMore).someOrMore;

test "oneOrMore" {
    const parse = oneOrMore(std.testing.allocator, string("ab")).parse;
    const res1 = try parse("ababcd");
    defer std.testing.allocator.free(res1.head);
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "ab", "ab" }),
        res1.head,
    );
    try expectFail(parse("cd"));
}

pub fn map(
    comptime parser: anytype,
    comptime f: anytype,
) Parser(ReturnPayloadType(f)) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(ReturnPayloadType(f)) {
            if (parser.parse(input)) |res| {
                return Result(ReturnPayloadType(f)){
                    .head = try f(res.head),
                    .tail = res.tail,
                };
            } else |err| {
                return err;
            }
        }
    }.parse };
}

test "map" {
    const f = struct {
        fn f(s: []const u8) !usize {
            return s.len;
        }
    }.f;
    const parse = map(string("abc"), f).parse;
    try expectResult(3, "d", parse("abcd"));
    try expectFail(parse("ab"));
}

pub fn notFollowedBy(comptime parser: anytype) Parser(void) {
    return .{ .parse = struct {
        fn parse(input: []const u8) anyerror!Result(void) {
            if (parser.parse(input)) |_| {
                return error.Fail;
            } else |_| {
                return Result(void){
                    .head = {},
                    .tail = input,
                };
            }
        }
    }.parse };
}

test "notFollowedBy" {
    const parse = notFollowedBy(string("ab")).parse;
    try expectResult({}, "cd", parse("cd"));
    try expectFail(parse("abcd"));
}

pub fn followedBy(comptime parser: anytype) Parser(void) {
    return notFollowedBy(notFollowedBy(parser));
}

test "FollowedBy" {
    const parse = followedBy(string("ab")).parse;
    try expectResult({}, "abcd", parse("abcd"));
    try expectFail(parse("cd"));
}

fn expectResult(head: anytype, tail: []const u8, actual: anytype) !void {
    const res = try actual;
    try std.testing.expectEqualDeep(@TypeOf(res){
        .head = head,
        .tail = tail,
    }, res);
}

fn expectFail(actual: anytype) !void {
    try std.testing.expectEqual(error.Fail, actual);
}
